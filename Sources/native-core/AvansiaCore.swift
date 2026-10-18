import Foundation
import Darwin
import MachO

struct Failure: Error, CustomStringConvertible { let description: String; init(_ text: String) { description = text } }
func require(_ condition: Bool, _ text: String) throws { if !condition { throw Failure(text) } }
func be32(_ value: Int) -> [UInt8] { (0..<4).reversed().map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
func integer(_ bytes: ArraySlice<UInt8>) -> Int { bytes.reduce(0) { ($0 << 8) | Int($1) } }
func hex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "%02x", $0) }.joined() }
func emit(_ object: [String: Any]) { let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]); print(String(data: data, encoding: .utf8)!) }
let root: URL = {
    var count: UInt32 = 0
    _ = _NSGetExecutablePath(nil,&count)
    var path = [CChar](repeating:0,count:Int(count))
    _ = _NSGetExecutablePath(&path,&count)
    return URL(fileURLWithPath:String(cString:path)).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()
}()
func library(_ relative: String) throws -> UnsafeMutableRawPointer {
    let path = root.appendingPathComponent(relative).path
    guard let handle = dlopen(path, RTLD_NOW | RTLD_LOCAL) else { throw Failure("Cannot load \(path): \(String(cString: dlerror()))") }
    return handle
}
func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String, _: T.Type) throws -> T {
    guard let address = dlsym(handle, name) else { throw Failure("Missing library symbol \(name)") }
    return unsafeBitCast(address, to: T.self)
}
struct Record { let checkpoint: String?; let bytes: [UInt8]; init(_ checkpoint: String) { self.checkpoint = checkpoint; bytes = [] }; init(_ bytes: [UInt8]) { checkpoint = nil; self.bytes = bytes } }
func readJob(_ path: String) throws -> [Record] {
    let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath: path)))
    var offset = 0, records: [Record] = []
    let checkpoints: Set<String> = ["HEADER_BEGIN", "HEADER_END", "DOC_BEGIN", "DOC_END", "DUPLEX", "CARD_BEGIN", "CARD_END", "FACE_BEGIN", "FACE_END"]
    while offset < data.count {
        try require(offset + 2 <= data.count && data[offset + 1] == 44, "Unsupported PRN record")
        let kind = data[offset]; offset += 2
        if kind == 68 {
            let start = offset
            while offset < data.count && data[offset] != 10 && offset - start < 128 { offset += 1 }
            try require(offset < data.count && data[offset] == 10 && offset - start < 128, "Invalid PRN checkpoint")
            let name = String(bytes: data[start..<offset], encoding: .ascii) ?? ""
            try require(checkpoints.contains(name), "Unsupported PRN checkpoint")
            records.append(Record(name)); offset += 1
        } else if kind == 66 {
            let start = offset
            while offset < data.count && data[offset] >= 48 && data[offset] <= 57 && offset - start < 10 { offset += 1 }
            try require(offset > start && offset < data.count && data[offset] == 44 && offset - start <= 9, "Invalid PRN binary length")
            let size = Int(String(bytes: data[start..<offset], encoding: .ascii)!)!; offset += 1
            try require(size >= 6 && size <= 32 * 1024 * 1024, "PRN binary length is out of range")
            try require(offset + size < data.count && data[offset + size] == 10, "PRN binary block is truncated")
            var block = Array(data[offset..<offset + size]); offset += size + 1
            if block.count >= 4 && block[0...1] == [68, 98] && block[3] == 44 { block.removeFirst(4) }
            try require(block.count >= 6 && block[0...1] == [28, 80] && block.count == 6 + integer(block[2..<6]), "Invalid Avansia print frame")
            let payload = Array(block.dropFirst(6))
            try require([[27,64,49,46], [27,62], [27,84]].contains(payload) || [[27,73], [27,74], [27,67]].contains(where: { payload.starts(with: $0) }), "The job contains a command outside the card print allowlist")
            records.append(Record(block))
        } else { throw Failure("Unsupported PRN record") }
    }
    var position = 0
    func take(_ checkpoint: String? = nil, _ expected: [UInt8]? = nil) throws -> [UInt8] {
        try require(position < records.count, "The card task structure is incomplete or out of order")
        let record = records[position]
        try require(record.checkpoint == checkpoint, "The card task contains an unexpected command or checkpoint")
        let payload = Array(record.bytes.dropFirst(6))
        if let expected { try require(payload == expected, "The card task contains an unexpected command") }
        position += 1; return payload
    }
    for checkpoint in ["HEADER_BEGIN", "HEADER_END", "DOC_BEGIN"] { _ = try take(checkpoint) }
    let duplex = position < records.count && records[position].checkpoint == "DUPLEX"
    if duplex { _ = try take("DUPLEX") }
    _ = try take("CARD_BEGIN"); _ = try take(nil, [27,64,49,46])
    for face in 0..<(duplex ? 2 : 1) {
        _ = try take("FACE_BEGIN")
        for (preparation, planes) in [("\u{1b}I0,0,2048,1300,7987200.", 3), ("\u{1b}C0,0,2048,1300,2662400.", 1)] {
            let bytes = Array(preparation.utf8)
            if position < records.count && records[position].checkpoint == nil && Array(records[position].bytes.dropFirst(6)) == bytes {
                _ = try take(nil, bytes)
                for _ in 0..<planes {
                    let plane = try take()
                    try require(plane.count == 2662426 && plane.starts(with: [27,74] + [UInt8](repeating: 0, count: 24)), "A card plane is not a complete 600 dpi raster")
                }
            }
        }
        if duplex && face == 0 { _ = try take(nil, [27,84]); _ = try take(nil, [27,62]) }
        _ = try take("FACE_END")
    }
    _ = try take(nil, [27,62]); _ = try take("CARD_END"); _ = try take("DOC_END")
    try require(position == records.count, "Only one card with one or two complete faces is supported")
    return records
}

func advanceKey(_ key: [UInt8]) -> [UInt8] {
    var words: [UInt32] = (0..<4).map { n in (0..<4).reduce(UInt32(0)) { $0 | (UInt32(key[n * 4 + $1]) << ($1 * 8)) } }
    let original = words
    for i in 0..<4 { words[i] = UInt32(bitPattern: Int32(bitPattern: original[i]) >> 1) }
    for i in 1..<4 { words[i] |= (original[i - 1] & 1) << 31 }
    if original[3] & 1 != 0 {
        for (i, mask) in [UInt32(0xa6e4c7cf),0x8ea4a3a7,0x98ab36a9,0xc6df5195].enumerated() { words[i] ^= mask }
        words[0] |= 0x80000000
    }
    return words.flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> ($0 * 8)) } }
}
func crypt(_ input: [UInt8], _ key: [UInt8], decrypt: Bool = false) throws -> [UInt8] {
    try require(key.count == 16 && (!decrypt || (!input.isEmpty && input.count % 16 == 0)), "Invalid RFID cipher input")
    var data = input
    if !decrypt { let padding = 16 - data.count % 16; data += [UInt8](repeating: UInt8(padding), count: padding) }
    var output = [UInt8](repeating: 0, count: data.count + 16), moved = 0
    let iv = [UInt8](repeating: 0, count: 16)
    let rc = CCCrypt(CCOperation(decrypt ? kCCDecrypt : kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), 0, key, key.count, iv, data, data.count, &output, output.count, &moved)
    try require(rc == kCCSuccess, "RFID cipher rejected the response: \(rc)")
    output = Array(output.prefix(moved))
    if decrypt {
        let padding = Int(output.last ?? 0)
        try require(padding >= 1 && padding <= 16 && output.suffix(padding).allSatisfy { $0 == UInt8(padding) }, "RFID response has invalid cipher padding")
        output.removeLast(padding)
    }
    return output
}

final class USB {
    typealias Init = @convention(c) (UnsafeMutablePointer<UnsafeMutableRawPointer?>) -> Int32
    typealias Open = @convention(c) (UnsafeMutableRawPointer?, UInt16, UInt16) -> UnsafeMutableRawPointer?
    typealias Interface = @convention(c) (UnsafeMutableRawPointer?, Int32) -> Int32
    typealias Bulk = @convention(c) (UnsafeMutableRawPointer?, UInt8, UnsafeMutableRawPointer?, Int32, UnsafeMutablePointer<Int32>, UInt32) -> Int32
    typealias Control = @convention(c) (UnsafeMutableRawPointer?, UInt8, UInt8, UInt16, UInt16, UnsafeMutableRawPointer?, UInt16, UInt32) -> Int32
    typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Void
    let libraryHandle: UnsafeMutableRawPointer
    let claim: Interface, release: Interface, bulk: Bulk, control: Control, close: Close, exitUSB: Close
    var context: UnsafeMutableRawPointer?, handle: UnsafeMutableRawPointer?, buffer: [UInt8] = []
    var lock: Int32 = -1
    init() throws {
        libraryHandle = try library("native/lib/libusb-1.0.dylib")
        claim = try symbol(libraryHandle, "libusb_claim_interface", Interface.self)
        release = try symbol(libraryHandle, "libusb_release_interface", Interface.self)
        bulk = try symbol(libraryHandle, "libusb_bulk_transfer", Bulk.self)
        control = try symbol(libraryHandle, "libusb_control_transfer", Control.self)
        close = try symbol(libraryHandle, "libusb_close", Close.self)
        exitUSB = try symbol(libraryHandle, "libusb_exit", Close.self)
        let initialize = try symbol(libraryHandle, "libusb_init", Init.self)
        let openDevice = try symbol(libraryHandle, "libusb_open_device_with_vid_pid", Open.self)
        var lockError = [CChar](repeating: 0,count: 1024)
        if let inheritedLock {
            let expected = Darwin.open("/private/tmp/avansia-mac-\(getuid()).lock", O_RDONLY | O_NOFOLLOW)
            try require(expected >= 0,"Could not inspect inherited printer lock")
            defer { Darwin.close(expected) }
            var held = stat(), actual = stat()
            try require(fstat(inheritedLock,&held) == 0 && fstat(expected,&actual) == 0 && held.st_dev == actual.st_dev && held.st_ino == actual.st_ino && held.st_uid == getuid() && held.st_mode & 0o170000 == 0o100000 && held.st_mode & 0o077 == 0 && held.st_nlink == 1,"Invalid inherited printer lock")
            lock = dup(inheritedLock)
            try require(lock >= 0,"Could not duplicate inherited printer lock")
            if flock(lock,LOCK_EX | LOCK_NB) != 0 { Darwin.close(lock); lock = -1; throw Failure("Inherited printer lock is unavailable") }
        } else {
            lock = avansia_lock(&lockError,lockError.count)
            try require(lock >= 0,String(cString:lockError))
        }
        if initialize(&context) != 0 { Darwin.close(lock); lock = -1; throw Failure("Could not initialize libusb") }
        handle = openDevice(context, 0x09c2, 0x0022)
        if handle == nil { exitUSB(context); context = nil; Darwin.close(lock); lock = -1; throw Failure("Avansia was not found or could not be opened") }
    }
    deinit { if handle != nil { close(handle) }; if context != nil { exitUSB(context) }; if lock >= 0 { Darwin.close(lock) }; dlclose(libraryHandle) }
    func write(_ data: [UInt8], timeout: UInt32 = 5000) throws {
        let rc = claim(handle, 0); try require(rc == 0, "Avansia USB interface is unavailable: \(rc)")
        defer { _ = release(handle, 0) }
        var offset = 0
        while offset < data.count {
            var chunk = Array(data[offset..<min(data.count, offset + 65536)]), sent: Int32 = 0
            let count = chunk.count
            let rc = chunk.withUnsafeMutableBytes { bulk(handle, 1, $0.baseAddress, Int32(count), &sent, timeout) }
            try require(rc == 0 && sent == count, "USB write failed: \(rc); accepted \(sent)/\(count) bytes; do not retry a print automatically")
            offset += Int(sent)
        }
    }
    func read(_ size: Int, timeout: UInt32 = 5000) throws -> [UInt8] {
        while buffer.count < size {
            let rc = claim(handle, 0); try require(rc == 0, "Avansia USB interface is unavailable: \(rc)")
            do {
                defer { _ = release(handle, 0) }
                _ = control(handle, 0x21, 1, 0, 0, nil, 0, timeout)
                var raw = [UInt8](repeating: 0, count: 65536), received: Int32 = 0
                let rc = raw.withUnsafeMutableBytes { bulk(handle, 0x81, $0.baseAddress, 65536, &received, timeout) }
                try require((rc == 0 || rc == -7) && received > 0, "USB read failed: \(rc); received \(received) bytes")
                buffer += raw.prefix(Int(received))
            }
        }
        let result = Array(buffer.prefix(size)); buffer.removeFirst(size); return result
    }
    func query(_ command: UInt8, _ expected: Int) throws -> [UInt8] {
        try require(command == 89 || command == 84, "Unsupported printer query")
        try write([28,command] + be32(expected))
        let header = try read(6), size = integer(header[2..<6])
        try require(header[0...1] == [28, command] && size <= 4096, "Unexpected printer response: \(hex(header))")
        return try read(size)
    }
    func status() throws -> [String: Any] {
        let info = try query(89,52), state = try query(84,60)
        try require(info.count >= 51 && state.count >= 60, "Printer information response is incomplete")
        let flags = state[0]
        func ascii(_ range: Range<Int>) -> String { String(bytes: info[range], encoding: .ascii)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
        return ["model": "Evolis Avansia", "firmware": ascii(38..<42), "base_revision": ascii(34..<38), "serial": ascii(42..<50), "printer_id": info[50], "ribbon_type_code": info[2], "ribbon_panel_code": info[3], "ribbon_remaining_percent": state[42] <= 100 ? Int(state[42]) as Any : NSNull(), "film_remaining_percent": state[43] <= 100 ? Int(state[43]) as Any : NSNull(), "ready": flags & 0x11 == 0x11 && flags & 4 == 0, "printing": flags & 8 != 0, "error": flags & 4 != 0, "flags": String(format: "%02x", flags), "status_payload": hex(state)]
    }
    func send(_ command: UInt8, _ payload: [UInt8]) throws {
        try write([28,command] + be32(payload.count) + payload)
        let ack = try read(6)
        try require(ack[0...1] == [28,command], "Unexpected RFID transport acknowledgement: \(hex(ack))")
    }
    func exchange(_ opcode: UInt8, _ payload: [UInt8], timeout: Double = 2) throws -> [UInt8] {
        let size = payload.count + 3
        try send(67, [UInt8(size >> 8),UInt8(size & 255),opcode,UInt8(size & 255),UInt8(size >> 8)] + payload)
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            try write([28,68] + be32(1024))
            let header = try read(6, timeout: 250), count = integer(header[2..<6])
            try require(header[0...1] == [28,68] && count <= 1024, "Unexpected RFID transport response")
            let data = try read(count, timeout: 250)
            if data.count >= 2 {
                let available = Int(Int16(bitPattern: UInt16(data[0]) << 8 | UInt16(data[1])))
                try require(available >= 0, "RFID interface reported an error: \(available)")
                if available > 2 && data.count >= 5 {
                    let length = Int(data[3]) | Int(data[4]) << 8
                    try require(length >= 3 && length <= 1022, "Invalid RFID response length")
                    if available >= length && data.count >= length + 2 {
                        try require(data[2] == opcode, "RFID details query failed with response code \(data[2])")
                        return Array(data[5..<length + 2])
                    }
                }
            }
            usleep(10000)
        }
        throw Failure("RFID details read timed out")
    }
    func ribbonStatus() throws -> [String: Any] {
        let state = try status(), flags = Int(state["flags"] as! String, radix: 16)!
        try require(state["ready"] as? Bool == true && flags & 0x2a == 0, "The printer must be idle and Ready to read ribbon details")
        var details: [String: String] = [:], activeError: Error?
        do {
            try send(80, Array("\u{1b}E6,4.".utf8)); try send(67, [0,0,2,5]); usleep(60000)
            var challenge = [UInt8](repeating: 0, count: 20); arc4random_buf(&challenge, challenge.count)
            var key = advanceKey(Array(challenge.prefix(16)))
            try require(try exchange(1, challenge) == key, "RFID challenge response did not match")
            key = advanceKey(key)
            let authentication = try exchange(2, crypt(key,key)); key = advanceKey(key)
            try require(try crypt(authentication,key,decrypt: true) == key, "RFID authentication response did not match")
            for (field, query) in [("code","Rrt;ref"),("zone","Rrt;zone;s"),("label","Rrt;label"),("progress","Rrt;progress")] {
                let ciphertext = try exchange(3, crypt(Array(query.utf8) + [0],key), timeout: 15)
                var plaintext = try crypt(ciphertext,key,decrypt: true)
                while plaintext.last == 0 { plaintext.removeLast() }
                details[field] = plaintext.map { $0 < 128 ? String(UnicodeScalar($0)) : String(format: "\\x%02x", $0) }.joined()
            }
        } catch { activeError = error }
        do { try send(80, Array("\u{1b}E7,4.".utf8)) } catch { if let activeError { throw Failure("\(activeError); RFID session cleanup also failed: \(error)") }; throw error }
        if let activeError { throw activeError }
        var result = try status(); result["ribbon"] = details
        result["detected_ribbon"] = details["label"] == "Color YMCK RT" ? "YMCK" : details["label"] == "Color YMCKK RT" ? "YMCKK" as Any : NSNull()
        return result
    }
    func printCard(_ records: [Record]) throws -> [String: Any] {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AvansiaDriver/state")
        let marker = directory.appendingPathComponent("inflight.json")
        try require(!FileManager.default.fileExists(atPath: marker.path), "A previous card has an uncertain outcome; inspect the printer and acknowledge it before printing again")
        let initial = try ribbonStatus()
        try require(initial["ready"] as? Bool == true, "The printer is not ready; no card was submitted")
        try require(["YMCK", "YMCKK"].contains(initial["detected_ribbon"] as? String ?? ""), "The installed ribbon was not recognized; no card was submitted")
        var submitted = false
        for record in records {
            if record.checkpoint == nil {
                if !submitted {
                    if try checkCancellation() { return ["canceled":true,"submitted":false] }
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                    let fd = Darwin.open(marker.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
                    try require(fd >= 0, "Could not create uncertain-card marker")
                    let data = try JSONSerialization.data(withJSONObject: ["serial": initial["serial"]!, "started_at": Date().timeIntervalSince1970, "phase": "card-submission-started"])
                    let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, data.count) }
                    let synced = fsync(fd); Darwin.close(fd)
                    try require(written == data.count && synced == 0, "Could not persist uncertain-card marker")
                    let directoryFD = Darwin.open(directory.path, O_RDONLY)
                    try require(directoryFD >= 0, "Could not open state directory")
                    let directorySynced = fsync(directoryFD); Darwin.close(directoryFD)
                    try require(directorySynced == 0, "Could not persist state directory")
                    submitted = true
                }
                try write(record.bytes, timeout: 30000)
                let ack = try read(6, timeout: 30000)
                try require(ack[0...1] == [28,80], "Unexpected print response \(hex(ack)); inspect the printer before retrying")
            } else if record.checkpoint == "CARD_BEGIN" || record.checkpoint == "CARD_END" {
                let beginning = record.checkpoint == "CARD_BEGIN", deadline = ProcessInfo.processInfo.systemUptime + 180
                while true {
                    let state = try query(84, beginning ? 1 : 60)
                    try require(state.count >= (beginning ? 1 : 60), "Printer status response is incomplete; completion is unknown")
                    try require(state[0] & 4 == 0, "Printer reported an error; inspect its display before retrying")
                    if !beginning { try require(state[41] != 1 && state[41] != 2, "Printer requires manual card insertion or removal; inspect its display") }
                    if beginning ? state[0] & 0x10 != 0 : state[0] & 8 == 0 { break }
                    try require(ProcessInfo.processInfo.systemUptime < deadline, "Printer completion is unknown after 180 seconds; do not resubmit automatically")
                    usleep(beginning ? 100000 : 250000)
                }
            }
        }
        if submitted { try FileManager.default.removeItem(at: marker) }
        return ["submitted": submitted,"device_reported_complete":true,"physical_output_verified":false,"serial":initial["serial"]!]
    }
}

func validateBMP(_ path: String) throws {
    let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path)); defer { try? file.close() }
    let header = [UInt8](try file.read(upToCount: 54) ?? Data())
    func le(_ start: Int, _ count: Int) -> Int { integer(Array(header[start..<start + count].reversed())[...]) }
    try require(header.count == 54, "The SDK requires a 2048 x 1300, uncompressed, bottom-up, 24-bit BMP")
    try require(header[0...1] == [66,77] && le(10,4) == 54 && le(14,4) == 40 && le(18,4) == 2048 && le(22,4) == 1300 && le(26,2) == 1 && le(28,2) == 24 && le(30,4) == 0, "The SDK requires a 2048 x 1300, uncompressed, bottom-up, 24-bit BMP")
}
func validateBlackBMP(_ path: String) throws {
    let data = [UInt8](try Data(contentsOf: URL(fileURLWithPath:path)))
    func le(_ start: Int, _ count: Int) -> Int { integer(Array(data[start..<start + count].reversed())[...]) }
    let message = "The K mask requires a complete 2048 x 1300 bottom-up 1-bit BMP with black/white palette and 256-byte stride"
    try require(data.count == 62 + 256 * 1300,message)
    try require(data[0...1] == [66,77] && le(2,4) == data.count && le(10,4) == 62 && le(14,4) == 40 && le(18,4) == 2048 && le(22,4) == 1300 && le(26,2) == 1 && le(28,2) == 1 && le(30,4) == 0 && [0,256 * 1300].contains(le(34,4)) && [0,2].contains(le(46,4)) && Array(data[54..<62]) == [0,0,0,0,255,255,255,0],message)
}
let colorPreparation = Array("\u{1b}I0,0,2048,1300,7987200.".utf8)
let blackPreparation = Array("\u{1b}C0,0,2048,1300,2662400.".utf8)
func payload(_ record: Record) -> [UInt8] { Array(record.bytes.dropFirst(6)) }
func mergeExplicitBlack(_ base: [Record], _ explicit: [Record]) throws -> [Record] {
    func faceRanges(_ records: [Record]) -> [Range<Int>] {
        var start = 0, ranges: [Range<Int>] = []
        for (i,record) in records.enumerated() {
            if record.checkpoint == "FACE_BEGIN" { start = i + 1 }
            if record.checkpoint == "FACE_END" { ranges.append(start..<i) }
        }
        return ranges
    }
    func parts(_ records: [Record]) -> (color:[Record],black:[Record],controls:[Record]) {
        var position = 0, color: [Record] = [], black: [Record] = []
        if position < records.count && payload(records[position]) == colorPreparation {
            color = Array(records[position..<position + 4]); position += 4
        }
        if position < records.count && payload(records[position]) == blackPreparation {
            black = Array(records[position..<position + 2]); position += 2
        }
        return (color,black,Array(records.dropFirst(position)))
    }
    func skeleton(_ records: [Record]) -> [Record] {
        var result = records
        for range in faceRanges(records).reversed() {
            result.replaceSubrange(range,with:parts(Array(records[range])).controls)
        }
        return result
    }
    func same(_ lhs:[Record], _ rhs:[Record]) -> Bool {
        lhs.count == rhs.count && zip(lhs,rhs).allSatisfy { $0.checkpoint == $1.checkpoint && $0.bytes == $1.bytes }
    }
    let baseFaces = faceRanges(base), explicitFaces = faceRanges(explicit)
    try require(baseFaces.count == explicitFaces.count && same(skeleton(base),skeleton(explicit)),"SDK passes disagree on card structure or control sequence")
    var merged = base
    for i in baseFaces.indices.reversed() {
        let accepted = parts(Array(base[baseFaces[i]])), requested = parts(Array(explicit[explicitFaces[i]]))
        if !requested.black.isEmpty {
            try require(requested.black[1].bytes.dropFirst(32).allSatisfy { $0==0 || $0==255 },"The SDK returned a nonbinary explicit K plane")
        }
        merged.replaceSubrange(baseFaces[i],with:accepted.color + requested.black + accepted.controls)
    }
    return merged
}
func kFringePairs(_ bitmap:[UInt8],_ mask:[UInt8]) throws -> [(Int,Int)] {
    let width=2048, height=1300, count=width*height
    try require(bitmap.count==54+count*3 && mask.count==count,"Fringe analysis requires complete RGB and K rasters")
    let rgb=(0..<count).map { i -> UInt32 in
        let offset=54+((height-1-i/width)*width+i%width)*3
        return UInt32(bitmap[offset+2])<<16 | UInt32(bitmap[offset+1])<<8 | UInt32(bitmap[offset])
    }
    func channels(_ value:UInt32) -> [Int] { [Int(value>>16),Int((value>>8)&255),Int(value&255)] }
    var pairs:[(Int,Int)]=[]
    for y in 5..<height-5 { for x in 5..<width-5 {
        let pixel=y*width+x
        if mask[pixel] != 0 { continue }
        var background:Int?, conflict=false
        for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
            if mask[(y-dy)*width+x-dx]==0 { continue }
            var foreground:UInt32?
            for depth in 1...3 {
                let index=(y-dy*depth)*width+x-dx*depth
                if mask[index] != 0 && channels(rgb[index]).reduce(0,+)<=96 { foreground=rgb[index]; break }
            }
            guard let foreground else { continue }
            for distance in 2...4 {
                let sample=(y+dy*distance)*width+x+dx*distance, color=rgb[sample]
                var flat=true
                for yy in -1...1 { for xx in -1...1 {
                    let index=sample+yy*width+xx
                    if mask[index] != 0 || rgb[index] != color { flat=false }
                } }
                if !flat { continue }
                for step in 1..<distance {
                    let index=(y+dy*step)*width+x+dx*step
                    if mask[index] != 0 || rgb[index] != color { flat=false }
                }
                if !flat { continue }
                let bg=channels(color), fg=channels(foreground), current=channels(rgb[pixel])
                let delta=zip(fg,bg).map { Double($0-$1) }, offset=zip(current,bg).map { Double($0-$1) }
                let denominator=delta.reduce(0) { $0+$1*$1 }
                if denominator>0 {
                    let alpha=zip(delta,offset).reduce(0) { $0+$1.0*$1.1 }/denominator
                    if alpha>0 && alpha<1 && zip(offset,delta).allSatisfy({abs($0-alpha*$1)<=1}) {
                        if let previous=background, rgb[previous] != color { conflict=true } else { background=sample }
                    }
                }
                break
            }
        }
        if let background, !conflict { pairs.append((pixel,background)) }
    } }
    return pairs
}
func removeKFringe(_ records:[Record],_ sources:[String],_ rotateBack:Bool) throws -> [Record] {
    let count=2048*1300
    var result=records, face = -1, colorIndices:[Int]=[]
    for index in records.indices {
        let record=records[index]
        if record.checkpoint=="FACE_BEGIN" { face+=1; colorIndices=[] }
        if record.bytes.count==colorPreparation.count+6 && payload(record)==colorPreparation { colorIndices=[index+1,index+2,index+3] }
        if record.bytes.count != blackPreparation.count+6 || payload(record) != blackPreparation || colorIndices.isEmpty { continue }
        let rotate=face==1 && rotateBack
        let black=Array(records[index+1].bytes.dropFirst(32)), mask=rotate ? Array(black.reversed()) : black
        let bitmap=[UInt8](try Data(contentsOf:URL(fileURLWithPath:sources[face])))
        let pairs=try kFringePairs(bitmap,mask)
        var planes=colorIndices.map { records[$0].bytes }
        for (pixel,background) in pairs {
            let target=32+(rotate ? count-1-pixel : pixel), sample=32+(rotate ? count-1-background : background)
            for channel in 0..<3 { planes[channel][target]=records[colorIndices[channel]].bytes[sample] }
        }
        for channel in 0..<3 { result[colorIndices[channel]]=Record(planes[channel]) }
    }
    return result
}
func encodeJob(_ records: [Record]) -> Data {
    var data = Data()
    for record in records {
        if let checkpoint = record.checkpoint { data.append(contentsOf:Array("D,\(checkpoint)\n".utf8)) }
        else { data.append(contentsOf:Array("B,\(record.bytes.count),".utf8)); data.append(contentsOf:record.bytes); data.append(10) }
    }
    return data
}
func prepare(_ front: String, _ output: String, _ ribbon: String, _ back: String?, _ rotate: Bool, _ frontBlack: String? = nil, _ backBlack: String? = nil, _ colorProfile: String? = nil) throws -> [String: Any] {
    try require(["YMCK", "YMCKK"].contains(ribbon), "Unsupported ribbon")
    try require(colorProfile == nil || frontBlack != nil,"A color profile requires explicit K masks")
    try require(backBlack == nil || (back != nil && frontBlack != nil),"A back K mask requires front and back images and a front K mask")
    try require(frontBlack == nil || back == nil || backBlack != nil,"Explicit K mode requires a K mask for every face")
    try validateBMP(front); if let back { try validateBMP(back) }
    if let frontBlack { try validateBlackBMP(frontBlack) }; if let backBlack { try validateBlackBMP(backBlack) }
    let lib = try library("native/vendor/evolis/lib/macos/libevolis.dylib"); defer { dlclose(lib) }
    typealias Open = @convention(c) (UnsafePointer<CChar>, Int32) -> UnsafeMutableRawPointer?
    typealias Close = @convention(c) (UnsafeMutableRawPointer?) -> Void
    typealias Setting = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>) -> Bool
    typealias Forced = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
    typealias Image = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>) -> Int32
    typealias ToFile = @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>) -> Int32
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?
    let open = try symbol(lib,"evolis_open_with_mode",Open.self), close = try symbol(lib,"evolis_close",Close.self)
    let setting = try symbol(lib,"evolis_print_set_setting",Setting.self), forced = try symbol(lib,"evolis_print_set_forced_setting",Forced.self)
    let image = try symbol(lib,"evolis_print_set_imagep",Image.self), black = try symbol(lib,"evolis_print_set_blackp",Image.self)
    let toFile = try symbol(lib,"evolis_print_to_file",ToFile.self), version = try symbol(lib,"evolis_version",Version.self)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("avansia-prepare-" + UUID().uuidString)
    try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
    defer { try? FileManager.default.removeItem(at:temporary) }
    var sdkFront=front, sdkBack=back
    if let colorProfile {
        let profile=try ColorCorrectionProfile.load(colorProfile)
        let correctedFront=temporary.appendingPathComponent("front-color.bmp").path
        try profile.correctBMP(front,to:correctedFront,face:.front); sdkFront=correctedFront
        if let back {
            let correctedBack=temporary.appendingPathComponent("back-color.bmp").path
            try profile.correctBMP(back,to:correctedBack,face:.back); sdkBack=correctedBack
        }
    }
    func render(_ name:String, _ masks:Bool) throws -> [Record] {
        guard let context = open("socket://127.0.0.1:65534?type=avansia",1) else { throw Failure("Could not create Avansia offline SDK context") }
        defer { close(context) }
        try require(setting(context,52,"RC_" + ribbon + "_A"), "Could not configure the ribbon")
        forced(context,"FBlackManagement",masks ? "BMPBLACK" : "ALLBLACKPOINT")
        forced(context,"GSmoothing","NOSMOOTH"); forced(context,"IFBlackLevelValue","223"); forced(context,"IBBlackLevelValue","223")
        try require(image(context,0,URL(fileURLWithPath:sdkFront).standardizedFileURL.path) >= 0,"Could not load the card image")
        if masks { try require(black(context,0,URL(fileURLWithPath:frontBlack!).standardizedFileURL.path) >= 0,"Could not load the front K mask") }
        if let sdkBack {
            forced(context,"BBlackManagement",masks ? "BMPBLACK" : "ALLBLACKPOINT")
            forced(context,"GDuplexType","DUPLEX_CC"); forced(context,"BPageRotate180",rotate ? "ON" : "OFF")
            try require(image(context,1,URL(fileURLWithPath:sdkBack).standardizedFileURL.path) >= 0,"Could not load the back image")
            if masks { try require(black(context,1,URL(fileURLWithPath:backBlack!).standardizedFileURL.path) >= 0,"Could not load the back K mask") }
        }
        let file = temporary.appendingPathComponent(name)
        let rc = toFile(context,file.path); try require(rc >= 0,"Card rendering failed: \(rc)")
        return try readJob(file.path)
    }
    let base = try render("base.prn",false)
    let records: [Record]
    if frontBlack != nil {
        let merged=try mergeExplicitBlack(base,render("explicit.prn",true))
        // Color profiles do not move pixels. Classify original AA geometry,
        // then sample background YMC from this render's immutable SDK pass.
        records=try removeKFringe(merged,[front]+(back.map { [$0] } ?? []),rotate)
    } else { records = base }
    let staged = temporary.appendingPathComponent("merged.prn")
    let data = try frontBlack == nil ? Data(contentsOf:temporary.appendingPathComponent("base.prn")) : encodeJob(records)
    try data.write(to:staged)
    let validated = try readJob(staged.path)
    let job = URL(fileURLWithPath:output).standardizedFileURL
    try FileManager.default.createDirectory(at:job.deletingLastPathComponent(),withIntermediateDirectories:true)
    try data.write(to:job,options:.atomic)
    return ["job":job.path,"ribbon":ribbon,"cards":1,"sides":back == nil ? 1 : 2,"wire_blocks":validated.filter { $0.checkpoint == nil }.count,"bytes":data.count,"explicit_k":frontBlack != nil,"sdk_version":version().map { String(cString:$0) } ?? "unknown"]
}

var inheritedLock: Int32? = nil
var jobURI: String? = nil
func checkCancellation() throws -> Bool {
    if avansia_interrupted() != 0 { return true }
    guard let jobURI else { return false }
    var error = [CChar](repeating: 0,count: 1024)
    let result = avansia_job_cancelled(jobURI,&error,error.count)
    try require(result >= 0, String(cString:error))
    return result == 1
}
func coreMain() throws -> [String: Any] {
    var args = Array(CommandLine.arguments.dropFirst())
    func option(_ name: String) throws -> String? {
        guard let index = args.firstIndex(of: name) else { return nil }
        try require(index + 1 < args.count,"Missing value for \(name)")
        let value = args[index + 1]; args.removeSubrange(index...index + 1); return value
    }
    if let fd = try option("--lock-fd") { guard let number = Int32(fd), number >= 0 else { throw Failure("Invalid lock descriptor") }; inheritedLock = number }
    jobURI = try option("--job-uri")
    try require(!args.isEmpty,"Usage: AvansiaCore status|ribbon|prepare FRONTBMP OUTPUTPRN --ribbon YMCK|YMCKK [--back BMP] [--rotate-back] [--front-black MASK --back-black MASK] [--color-profile JSON]|print PRN --confirm-one-card")
    let command = args.removeFirst()
    if command == "validate" {
        try require(args.count == 1,"Usage: validate PRN")
        let records = try readJob(args[0]); return ["valid":true,"wire_blocks":records.filter { $0.checkpoint == nil }.count]
    }
    if command == "self-test" { return try selfTest() }
    if command == "prepare" {
        let ribbon = try option("--ribbon"), back = try option("--back"), frontBlack = try option("--front-black"), backBlack = try option("--back-black"), colorProfile = try option("--color-profile")
        let rotate = args.contains("--rotate-back"); args.removeAll { $0 == "--rotate-back" }
        try require(args.count == 2 && ribbon != nil,"Usage: prepare FRONTBMP OUTPUTPRN --ribbon YMCK|YMCKK [--back BMP] [--rotate-back] [--front-black MASK --back-black MASK] [--color-profile JSON]")
        return try prepare(args[0],args[1],ribbon!,back,rotate,frontBlack,backBlack,colorProfile)
    }
    if command == "print" {
        try require(args.count == 2 && args[1] == "--confirm-one-card","Printing requires one PRN and --confirm-one-card")
        let records = try readJob(args[0])
        if try checkCancellation() { return ["canceled":true,"submitted":false] }
        return try USB().printCard(records)
    }
    if command == "acknowledge" {
        try require(args == ["--confirm-card-inspected"],"Acknowledgement requires --confirm-card-inspected")
        let printer = try USB(), state = try printer.status()
        try require(state["ready"] as? Bool == true && state["printing"] as? Bool == false && state["error"] as? Bool == false,"The printer must be Ready and idle before acknowledgement")
        let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AvansiaDriver/state")
        let marker = directory.appendingPathComponent("inflight.json")
        var archived: Any = NSNull()
        if FileManager.default.fileExists(atPath: marker.path) {
            let destination = directory.appendingPathComponent("acknowledged-\(Int(Date().timeIntervalSince1970 * 1000)).json")
            try FileManager.default.moveItem(at: marker,to:destination); archived = destination.path
        }
        return ["acknowledged":true,"archive":archived,"submitted":false]
    }
    try require(args.isEmpty && ["status","ribbon"].contains(command),"Unsupported command or arguments")
    let printer = try USB()
    return try command == "ribbon" ? printer.ribbonStatus() : printer.status()
}
func selfTest() throws -> [String: Any] {
    let key = Array(UInt8(0)...UInt8(15)), expected: [UInt8] = [128,0,129,1,130,2,131,3,132,4,133,5,134,6,135,7]
    try require(advanceKey(key) == expected,"Key advance fixture failed")
    try require(hex(advanceKey([UInt8](repeating:255,count:16))) == "30381bd9585c5b7156c954676aae2039","Signed key advance fixture failed")
    try require(try hex(crypt(Array("Rrt;label".utf8) + [0],key)) == "caabb464a7ba382a8130888428c6dd6b","AES reference fixture failed")
    for length in [0,1,15,16,17,1024] {
        let input = (0..<length).map { UInt8(truncatingIfNeeded:$0) }
        try require(try crypt(crypt(input,key),key,decrypt:true) == input,"AES roundtrip failed")
    }
    do { _ = try crypt([UInt8](repeating:0,count:16),key,decrypt:true); throw Failure("Invalid padding accepted") } catch let error as Failure { try require(error.description != "Invalid padding accepted",error.description) }
    return ["passed":true,"tests":10]
}
#if !CORE_TESTS
@main struct CoreEntry {
    static func main() {
        avansia_install_signals()
        do { emit(try coreMain()) } catch { emit(["error":String(describing:error)]); exit(1) }
    }
}
#endif
