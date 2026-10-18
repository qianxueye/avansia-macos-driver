import Foundation

let safetyCount = 2048 * 1300
func safetyFrame(_ bytes: [UInt8]) -> Record { Record([28, 80] + be32(bytes.count) + bytes) }
func safetyPlane(_ pixels: [UInt8]) -> Record { safetyFrame([27, 74] + [UInt8](repeating: 0, count: 24) + pixels) }
func safetyEqual(_ lhs: Record, _ rhs: Record) -> Bool { lhs.checkpoint == rhs.checkpoint && lhs.bytes == rhs.bytes }
func safetyCheck(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
    try require(try value(), "Test failed: " + message)
}
func safetyReject(_ expected: String, _ action: () throws -> Void) throws {
    do { try action() } catch {
        try safetyCheck(String(describing: error).contains(expected), "Expected \(expected), got \(error)")
        return
    }
    throw Failure("Test failed: Expected rejection: " + expected)
}
func safetyJob(_ masks: [[UInt8]], color: Bool = true, seed: Int = 0) -> [Record] {
    var records = [Record("HEADER_BEGIN"), Record("HEADER_END"), Record("DOC_BEGIN")]
    if masks.count == 2 { records.append(Record("DUPLEX")) }
    records += [Record("CARD_BEGIN"), safetyFrame([27, 64, 49, 46])]
    for face in masks.indices {
        records.append(Record("FACE_BEGIN"))
        if color {
            records.append(safetyFrame(colorPreparation))
            for channel in 0..<3 {
                records.append(safetyPlane((0..<safetyCount).map { UInt8(($0 + face * 71 + channel * 37 + seed) % 251 + 1) }))
            }
        }
        records += [safetyFrame(blackPreparation), safetyPlane(masks[face])]
        if face == 0 && masks.count == 2 { records += [safetyFrame([27, 84]), safetyFrame([27, 62])] }
        records.append(Record("FACE_END"))
    }
    return records + [safetyFrame([27, 62]), Record("CARD_END"), Record("DOC_END")]
}
func safetyColors(_ records: [Record]) -> [[Int]] {
    records.indices.filter { payload(records[$0]) == colorPreparation }.map { [$0 + 1, $0 + 2, $0 + 3] }
}

@main struct PrintSafetyTests {
    static func main() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("avansia-print-safety-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let prn = temporary.appendingPathComponent("synthetic.prn")
        func parsed(_ records: [Record]) throws -> [Record] {
            try encodeJob(records).write(to: prn)
            return try readJob(prn.path)
        }
        let empty = [UInt8](repeating: 0, count: safetyCount)
        var mask = empty
        for pixel in [0, 2047, 2048, 12000, safetyCount - 1] { mask[pixel] = 255 }
        let base = safetyJob([mask, Array(mask.reversed())])
        let valid = try parsed(base)
        try safetyCheck(valid.count == base.count && zip(valid, base).allSatisfy(safetyEqual), "Complete duplex single-card PRN round trips exactly")
        do {
            var forbidden = base
            forbidden[5] = safetyFrame([27, 90, 0])
            try safetyReject("allowlist") { _ = try parsed(forbidden) }
            try safetyReject("Only one card") { _ = try parsed(base + base) }
            var truncated = base
            let plane = safetyColors(base)[0][0]
            truncated[plane] = safetyPlane(Array(empty.dropLast()))
            try safetyReject("complete 600 dpi raster") { _ = try parsed(truncated) }
            var malformed = base
            var frame = base[plane].bytes
            frame[5] ^= 1
            malformed[plane] = Record(frame)
            try safetyReject("Invalid Avansia print frame") { _ = try parsed(malformed) }
            try Data("B,not-a-length,\n".utf8).write(to: prn)
            try safetyReject("binary length") { _ = try readJob(prn.path) }
            try Data("B,9999999999,\n".utf8).write(to: prn)
            try safetyReject("binary length") { _ = try readJob(prn.path) }
            var shortened = encodeJob(base)
            shortened.removeLast(20)
            try shortened.write(to: prn)
            try safetyReject("PRN") { _ = try readJob(prn.path) }
        }
        print("PASS: Strict single-card PRN grammar rejects forbidden commands, multiple cards, truncated planes and malformed frame/record lengths")
        do {
            let requested = safetyJob([Array(mask.reversed()), mask], seed: 101)
            let merged = try parsed(mergeExplicitBlack(base, requested))
            let expected = safetyJob([Array(mask.reversed()), mask])
            try safetyCheck(merged.count == expected.count && zip(merged, expected).allSatisfy(safetyEqual), "All base YMC bytes and controls survive; only requested K replaces old K")
            for colors in [true, false] {
                var nonbinary = mask
                nonbinary[3000] = 127
                try safetyReject("nonbinary explicit K") {
                    _ = try mergeExplicitBlack(safetyJob([mask], color: colors), safetyJob([nonbinary], color: colors))
                }
            }
            try safetyReject("card structure") { _ = try mergeExplicitBlack(base, safetyJob([mask])) }
        }
        print("PASS: Explicit K is binary with or without YMC; merge preserves complete manufacturer YMC, framing and duplex controls")

        var bitmap = [UInt8](repeating: 0, count: 54 + safetyCount * 3)
        // Bottom-up BGR storage matches the production raster coordinate conversion.
        func paint(_ x: Int, _ y: Int, _ rgb: [UInt8]) {
            let offset = 54 + ((1299 - y) * 2048 + x) * 3
            bitmap[offset] = rgb[2]; bitmap[offset + 1] = rgb[1]; bitmap[offset + 2] = rgb[0]
        }
        func le(_ offset: Int, _ value: Int, _ length: Int = 4) {
            for byte in 0..<length { bitmap[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
        }
        bitmap[0] = 66; bitmap[1] = 77
        le(2, bitmap.count); le(10, 54); le(14, 40); le(18, 2048); le(22, 1300); le(26, 1, 2); le(28, 24, 2)
        for pixel in 0..<safetyCount { let offset = 54 + pixel * 3; bitmap[offset] = 211; bitmap[offset + 1] = 210; bitmap[offset + 2] = 210 }
        var edgeMask = empty
        var expectedCandidates = Set<Int>()
        for y in 500...530 {
            for x in 600...604 { edgeMask[y * 2048 + x] = 255; paint(x, y, [24, 24, 24]) }
            for x in [599, 605] { paint(x, y, [117, 117, 118]); expectedCandidates.insert(y * 2048 + x) }
        }
        paint(599, 515, [31, 141, 249]); expectedCandidates.remove(515 * 2048 + 599)
        // Exact background and exact foreground are endpoints, not fractional antialiasing.
        paint(599, 516, [210, 210, 211]); expectedCandidates.remove(516 * 2048 + 599)
        paint(599, 517, [24, 24, 24]); expectedCandidates.remove(517 * 2048 + 599)
        // A colored flat background exercises fractional RGB interpolation, beyond gray edges.
        for y in 700...730 { for x in 790...815 { paint(x, y, [221, 122, 43]) } }
        for y in 705...725 {
            for x in 800...804 { edgeMask[y * 2048 + x] = 255; paint(x, y, [24, 24, 24]) }
            for x in [799, 805] { paint(x, y, [123, 73, 34]); expectedCandidates.insert(y * 2048 + x) }
        }
        for y in 800...830 { for x in 1190...1220 { paint(x, y, [UInt8(140 + x - 1190), 160, 170]) } }
        for y in 805...825 {
            for x in 1200...1204 { edgeMask[y * 2048 + x] = 255; paint(x, y, [24, 24, 24]) }
            paint(1199, y, [90, 92, 100])
        }
        for y in 100...110 {
            edgeMask[y * 2048 + 99] = 255; paint(99, y, [20, 20, 20])
            for (x, value) in [(100, 80), (101, 120), (102, 160), (103, 200), (104, 200), (105, 200)] { paint(x, y, [UInt8](repeating: UInt8(value), count: 3)) }
        }
        let image = temporary.appendingPathComponent("synthetic.bmp")
        try Data(bitmap).write(to: image)
        try validateBMP(image.path)
        let pairs = try kFringePairs(bitmap, edgeMask)
        let mapping = Dictionary(uniqueKeysWithValues: pairs)
        try safetyCheck(Set(mapping.keys) == expectedCandidates, "Exactly 101 one-pixel strict fractional gray/colored edges qualify; alpha endpoints, blue artwork, gradient and multi-step ramp never qualify")
        for (pixel, sample) in pairs {
            try safetyCheck(edgeMask[pixel] == 0 && edgeMask[sample] == 0, "Fringe and immutable background sample are outside K")
            try safetyCheck([-1, 1, -2048, 2048].contains { edgeMask[pixel + $0] == 255 }, "Each fringe pixel is directly adjacent to K")
            let delta = sample - pixel
            try safetyCheck([2, 3, 4, -2, -3, -4, 4096, 6144, 8192, -4096, -6144, -8192].contains(delta), "Background comes from the bounded axial path")
        }
        print("PASS: Exactly \(pairs.count) proven flat-background one-pixel fractional edges; alpha endpoints, blue artwork, gradient and multi-step ramp are excluded")
        do {
            let original = safetyJob([edgeMask, Array(edgeMask.reversed())])
            let changed = try removeKFringe(original, [image.path, image.path], true)
            let colors = safetyColors(original)
            let mutable = Set(colors.flatMap { $0 })
            for index in original.indices where !mutable.contains(index) {
                try safetyCheck(safetyEqual(original[index], changed[index]), "K planes, preparations, control bytes and checkpoints remain exact")
            }
            var changesByFace = [0, 0]
            for face in 0..<2 { for plane in colors[face] {
                try safetyCheck(original[plane].bytes.prefix(32) == changed[plane].bytes.prefix(32), "YMC frame and raster headers remain exact")
                for pixel in 0..<safetyCount {
                    let sourcePixel = face == 1 ? safetyCount - 1 - pixel : pixel
                    let sample = mapping[sourcePixel].map { face == 1 ? safetyCount - 1 - $0 : $0 } ?? pixel
                    let before = original[plane].bytes[32 + pixel]
                    let after = changed[plane].bytes[32 + pixel]
                    try safetyCheck(after == original[plane].bytes[32 + sample], "YMC samples immutable same-pass background with correct back180 coordinates")
                    if edgeMask[sourcePixel] != 0 { try safetyCheck(after == before, "Manufacturer covering under every K pixel is unchanged") }
                    if after != before { changesByFace[face] += 1; try safetyCheck(expectedCandidates.contains(sourcePixel), "Only proven K0 adjacent candidates may change") }
                }
            } }
            try safetyCheck(changesByFace.allSatisfy { $0 > 0 }, "Fringe test actually changes YMC raster bytes on both faces")
        }
        print("PASS: Exhaustive native-size duplex YMC comparison preserves all under-K covering, K/control/header bytes and immutable sampling; back180 coordinates are exact")
        do {
            let original = safetyJob([empty])
            let changed = try removeKFringe(original, [image.path], false)
            try safetyCheck(zip(original, changed).allSatisfy(safetyEqual), "Empty K is a byte-exact no-op")
        }
        print("PASS: Empty K leaves the complete card job byte-exact")
        print("PASS: SDK-independent print safety suite; synthetic 2048x1300 rasters only; no USB, CUPS queue, network or printing operations")
    }
}
