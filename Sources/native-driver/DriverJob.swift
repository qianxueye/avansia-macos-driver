import Foundation
import Darwin

func driverError(_ message: String) -> NSError {
    NSError(domain: "AvansiaDriver", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func log(_ message: String) { FileHandle.standardError.write(Data((message + "\n").utf8)) }
let driverBase = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AvansiaDriver")
let runtimeRoot = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.resolvingSymlinksInPath().deletingLastPathComponent()

func runNative(_ executable: URL, _ arguments: [String], lock: Int32 = -1, timeout: Int32 = 0) throws -> [String: Any] {
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("avansia-command-" + UUID().uuidString)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: temporary) }
    let output = temporary.appendingPathComponent("stdout")
    let errors = temporary.appendingPathComponent("stderr")
    let pointers = ([executable.path] + arguments).map { strdup($0) } + [nil]
    defer { pointers.forEach { free($0) } }
    let status = pointers.withUnsafeBufferPointer {
        avansia_run(executable.path, $0.baseAddress, lock, output.path, errors.path, timeout)
    }
    let data = (try? Data(contentsOf: output)) ?? Data()
    guard status == 0 else {
        let detail = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        throw driverError((json?["error"] as? String) ?? (detail.isEmpty ? "Native command failed (status \(status))" : detail))
    }
    guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw driverError("Invalid native command response") }
    return result
}
func markerLevels(_ status: [String: Any]) -> (Int, Int) {
    let progress = (status["ribbon"] as? [String: Any])?["progress"] as? String ?? ""
    let match = progress.range(of: "^[0-9]{1,3}\\s*%$", options: .regularExpression)
    let ribbon = match == nil ? -1 : Int(progress.replacingOccurrences(of: "%", with: "").trimmingCharacters(in: .whitespaces)) ?? -1
    let film = status["film_remaining_percent"] as? Int ?? -1
    return ((0...100).contains(ribbon) ? ribbon : -1, (0...100).contains(film) ? film : -1)
}
struct PrintOptions {
    let copies: Int
    let sides: String
    let scaling: String
    let ranges: String
    let handling: String
    init(_ environment: [String: String]) throws {
        guard let copies = Int(environment["IPP_COPIES"] ?? environment["IPP_COPIES_DEFAULT"] ?? "1"), (1...100).contains(copies) else { throw driverError("Copies must be between 1 and 100") }
        self.copies = copies
        sides = environment["IPP_SIDES"] ?? environment["IPP_SIDES_DEFAULT"] ?? "two-sided-long-edge"
        guard ["one-sided", "two-sided-long-edge", "two-sided-short-edge"].contains(sides) else { throw driverError("Unsupported two-sided printing mode") }
        let requested = environment["IPP_PRINT_SCALING"] ?? environment["IPP_PRINT_SCALING_DEFAULT"] ?? "none"
        guard ["fill", "fit", "none", "auto", "auto-fit"].contains(requested) else { throw driverError("Unsupported print scaling mode") }
        scaling = requested == "auto" ? "fill" : requested == "auto-fit" ? "fit" : requested
        guard environment["IPP_NUMBER_UP", default: "1"] == "1" else { throw driverError("Only one card design per page is supported") }
        guard ["color", "auto"].contains(environment["IPP_PRINT_COLOR_MODE", default: "color"]) else { throw driverError("Select Color printing; the driver separates black into the K panel") }
        if let media = environment["IPP_MEDIA"], media != "iso_id-1_53.98x85.6mm" { throw driverError("Select the CR80 53.98 x 85.60 mm card size") }
        if let collection = environment["IPP_MEDIA_COL"], !collection.isEmpty {
            let regex = try NSRegularExpression(pattern: "[xy]-dimension=([0-9]+)")
            let dimensions = regex.matches(in: collection, range: NSRange(collection.startIndex..., in: collection)).compactMap { match -> Int? in
                guard let range = Range(match.range(at: 1), in: collection) else { return nil }
                return Int(collection[range])
            }
            guard dimensions.sorted() == [5398, 8560] else { throw driverError("The requested card dimensions are not CR80") }
        }
        handling = environment["IPP_MULTIPLE_DOCUMENT_HANDLING", default: "separate-documents-collated-copies"]
        guard ["separate-documents-collated-copies", "separate-documents-uncollated-copies"].contains(handling) else { throw driverError("Unsupported copy collation mode") }
        ranges = environment["IPP_PAGE_RANGES", default: ""]
    }
    var json: [String: Any] { ["copies": copies, "sides": sides, "scaling": scaling, "ranges": ranges, "handling": handling] }
}
func selectedPages(_ count: Int, _ ranges: String) throws -> [Int] {
    guard (1...100).contains(count) else { throw driverError("PDF must contain between 1 and 100 pages") }
    if ranges.isEmpty { return Array(0..<count) }
    var selected = Set<Int>()
    for value in ranges.split(separator: ",", omittingEmptySubsequences: false) {
        guard value.range(of: "^[0-9]+(-[0-9]+)?$", options: .regularExpression) != nil else { throw driverError("Invalid page range") }
        let bounds = value.split(separator: "-")
        guard let start = Int(bounds[0]), let end = Int(bounds.last!), 1 <= start, start <= end, end <= count else { throw driverError("Page range is outside the document") }
        selected.formUnion((start - 1)..<end)
    }
    return selected.sorted()
}
struct Card {
    let job: String
    let front: Int
    let back: Int?
    var faces: Int { back == nil ? 1 : 2 }
    var json: [String: Any] { ["job": job, "front_page": front, "back_page": back as Any? ?? NSNull(), "faces": faces] }
}
struct PrintPlan {
    let options: PrintOptions
    let ribbon: String
    let cards: [Card]
    let order: [Card]
    let rendering: [String: Any]
    var impressions: Int { order.reduce(0) { $0 + $1.faces } }
    var json: [String: Any] { ["options": options.json, "ribbon": ribbon, "cards": cards.map(\.json), "print_order": order.map(\.json), "card_count": order.count, "impressions": impressions, "rendering": rendering] }
}
func prepareDocument(_ source: URL, _ destination: URL, _ options: PrintOptions, _ ribbon: String,
                     colorProfile: URL? = nil,
                     run: (String, [String]) throws -> [String: Any]) throws -> PrintPlan {
    let values = try source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
    guard values.isRegularFile == true, let size = values.fileSize, 0 < size, size <= 256 * 1024 * 1024 else { throw driverError("The PDF must be nonempty and no larger than 256 MiB") }
    guard ["YMCK", "YMCKK"].contains(ribbon) else { throw driverError("The installed ribbon is unsupported") }
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    var profileSnapshot: String?
    if let colorProfile {
        let file = try FileHandle(forReadingFrom: colorProfile)
        defer { try? file.close() }
        let data = try file.read(upToCount: 65537) ?? Data()
        guard !data.isEmpty, data.count <= 65536 else { throw driverError("The color profile must be nonempty and no larger than 64 KiB") }
        let snapshot = destination.appendingPathComponent("color-profile.json")
        try data.write(to: snapshot, options: .atomic)
        _ = try ColorCorrectionProfile.load(snapshot.path)
        profileSnapshot = snapshot.path
    }
    let mode = options.scaling == "none" ? "borderless" : options.scaling
    let manifest = try run("CardRaster", [source.path, destination.appendingPathComponent("pages").path, mode])
    guard let count = manifest["page_count"] as? Int, let pages = manifest["pages"] as? [[String: Any]], pages.count == count,
          manifest["dpi"] as? Int == 600 else { throw driverError("Invalid raster manifest") }
    let selected = try selectedPages(count, options.ranges)
    var blackPaths: [Int: String] = [:]
    for page in selected {
        guard let path = pages[page]["black_bmp"] as? String, !path.isEmpty,
              FileManager.default.isReadableFile(atPath: path),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, let size = values.fileSize, size > 0 else {
            throw driverError("Missing or unreadable black mask for page \(page + 1)")
        }
        blackPaths[page] = path
    }
    var cards: [Card] = []
    let step = options.sides == "one-sided" ? 1 : 2
    for index in stride(from: 0, to: selected.count, by: step) {
        let front = selected[index]
        let back = step == 2 && index + 1 < selected.count ? selected[index + 1] : nil
        guard let frontBMP = pages[front]["bmp"] as? String else { throw driverError("Missing front bitmap") }
        let job = destination.appendingPathComponent(String(format: "card-%04d.prn", cards.count + 1)).path
        var arguments = ["prepare", frontBMP, job, "--ribbon", ribbon, "--front-black", blackPaths[front]!]
        if let back {
            guard let backBMP = pages[back]["bmp"] as? String else { throw driverError("Missing back bitmap") }
            arguments += ["--back", backBMP, "--back-black", blackPaths[back]!]
        }
        // The supported CR80 media is portrait; long-edge binding needs a rotated back raster.
        if back != nil && options.sides == "two-sided-long-edge" { arguments.append("--rotate-back") }
        if let profileSnapshot { arguments += ["--color-profile", profileSnapshot] }
        _ = try run("AvansiaCore", arguments)
        cards.append(Card(job: job, front: front + 1, back: back.map { $0 + 1 }))
    }
    let order = options.handling == "separate-documents-uncollated-copies"
        ? cards.flatMap { Array(repeating: $0, count: options.copies) }
        : (0..<options.copies).flatMap { _ in cards }
    let plan = PrintPlan(options: options, ribbon: ribbon, cards: cards, order: order, rendering: manifest)
    try JSONSerialization.data(withJSONObject: plan.json, options: [.prettyPrinted, .sortedKeys]).write(to: destination.appendingPathComponent("plan.json"), options: .atomic)
    return plan
}
struct JobCancelled: Error {}
func cancellationCheck(_ uri: String) throws {
    if avansia_interrupted() != 0 { throw JobCancelled() }
    var error = [CChar](repeating: 0, count: 1024)
    let result = avansia_job_cancelled(uri, &error, error.count)
    if result < 0 { throw driverError(String(cString: error)) }
    if result > 0 { throw JobCancelled() }
}
func acquireJobLock(check: () throws -> Void,
                    attempt: () -> (Int32, String) = {
                        var error = [CChar](repeating: 0, count: 1024)
                        let result = avansia_lock(&error, error.count)
                        return (result, String(cString: error))
                    },
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    pause: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }) throws -> Int32 {
    let deadline = now() + 25
    var waiting = false
    while true {
        if waiting && now() >= deadline { throw driverError("The printer stayed busy for 25 seconds; no card was submitted") }
        try check()
        if waiting && now() >= deadline { throw driverError("The printer stayed busy for 25 seconds; no card was submitted") }
        let (descriptor, message) = attempt()
        if descriptor >= 0 { return descriptor }
        guard descriptor == AVANSIA_LOCK_BUSY else { throw driverError(message) }
        if !waiting { log("INFO: Waiting for the printer device lock") }
        waiting = true
        let remaining = deadline - now()
        guard remaining > 0 else { throw driverError("The printer stayed busy for 25 seconds; no card was submitted") }
        pause(min(0.25, remaining))
    }
}
func executePlan(_ plan: PrintPlan, check: () throws -> Void, printCard: (Card) throws -> Bool) throws {
    var completed = 0
    log("ATTR: job-impressions=\(plan.impressions)")
    for (index, card) in plan.order.enumerated() {
        try check()
        log("INFO: Printing card \(index + 1) of \(plan.order.count)")
        if try !printCard(card) { throw JobCancelled() }
        completed += card.faces
        log("ATTR: job-impressions-completed=\(completed)")
    }
    log("INFO: Printer reported completion of \(plan.order.count) cards; inspect physical output")
}
func preflight(_ args: [String]) throws {
    guard args.count >= 4 else { throw driverError("Usage: AvansiaJob preflight SOURCE DEST [--sides MODE] [--scaling MODE] [--copies N] [--ribbon TYPE] [--ranges RANGES] [--handling MODE] [--color-profile PATH]") }
    var environment: [String: String] = [:]
    var ribbon = "YMCK"
    var colorProfile: URL?
    let keys = ["--sides": "IPP_SIDES", "--scaling": "IPP_PRINT_SCALING", "--copies": "IPP_COPIES", "--ranges": "IPP_PAGE_RANGES", "--handling": "IPP_MULTIPLE_DOCUMENT_HANDLING"]
    var index = 4
    while index < args.count {
        guard index + 1 < args.count else { throw driverError("Missing preflight option value") }
        if args[index] == "--ribbon" { ribbon = args[index + 1] }
        else if args[index] == "--color-profile" { colorProfile = URL(fileURLWithPath: args[index + 1]).standardizedFileURL }
        else if let key = keys[args[index]] { environment[key] = args[index + 1] }
        else { throw driverError("Unknown preflight option") }
        index += 2
    }
    let plan = try prepareDocument(URL(fileURLWithPath: args[2]).standardizedFileURL, URL(fileURLWithPath: args[3]).standardizedFileURL, PrintOptions(environment), ribbon, colorProfile: colorProfile) { name, arguments in
        try runNative(runtimeRoot.appendingPathComponent(name), arguments)
    }
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: plan.json, options: [.sortedKeys]))
    FileHandle.standardOutput.write(Data([10]))
}
func runJob() throws {
    let args = CommandLine.arguments
    if args.count > 1 && args[1] == "preflight" { try preflight(args); return }
    let env = ProcessInfo.processInfo.environment
    guard args.count == 2, let uri = env["IPP_JOB_URI"] else { throw driverError("This command must be started by the Avansia IPP service") }
    guard env["CONTENT_TYPE"] == "application/pdf" else { throw driverError("Only PDF print documents are supported") }
    let options = try PrintOptions(env)
    let lock = try acquireJobLock(check: { try cancellationCheck(uri) })
    defer { close(lock) }
    guard !FileManager.default.fileExists(atPath: driverBase.appendingPathComponent("state/inflight.json").path) else { throw driverError("A previous card has an uncertain outcome; inspect it before submitting another job") }
    let status = try runNative(runtimeRoot.appendingPathComponent("AvansiaCore"), ["ribbon", "--lock-fd", "198"], lock: lock)
    guard let ribbon = status["detected_ribbon"] as? String, ["YMCK", "YMCKK"].contains(ribbon) else { throw driverError("The installed ribbon is unsupported") }
    let levels = markerLevels(status)
    log("ATTR: marker-levels=\(levels.0),\(levels.1)")
    let folder = driverBase.appendingPathComponent("job-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    let profile = driverBase.appendingPathComponent("color-profile.json")
    let plan = try prepareDocument(URL(fileURLWithPath: args[1]).standardizedFileURL, folder, options, ribbon,
                                   colorProfile: FileManager.default.fileExists(atPath: profile.path) ? profile : nil) { name, arguments in
        try runNative(runtimeRoot.appendingPathComponent(name), arguments)
    }
    try executePlan(plan, check: { try cancellationCheck(uri) }) { card in
        let result = try runNative(runtimeRoot.appendingPathComponent("AvansiaCore"), ["print", card.job, "--confirm-one-card", "--lock-fd", "198", "--job-uri", uri], lock: lock)
        if result["canceled"] as? Bool == true && result["submitted"] as? Bool == false { return false }
        guard result["submitted"] as? Bool == true, result["device_reported_complete"] as? Bool == true else {
            throw driverError("The native core did not confirm card completion; do not resubmit automatically")
        }
        return true
    }
}
#if !DRIVER_TESTS && !DRIVER_SERVICE
@main struct AvansiaJob {
    static func main() {
        umask(0o077)
        avansia_install_signals()
        do { try runJob() }
        catch is JobCancelled { log("INFO: Canceled; no next card will start") }
        catch { log("ERROR: " + error.localizedDescription.replacingOccurrences(of: "\n", with: " ")); exit(1) }
    }
}
#endif
