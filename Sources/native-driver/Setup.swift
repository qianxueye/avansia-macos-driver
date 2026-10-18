import Foundation
import Darwin

struct SetupError: Error, CustomStringConvertible {
    let description: String
    init(_ value: String) { description = value }
}

let files = FileManager.default
let home = files.homeDirectoryForCurrentUser
let base = home.appendingPathComponent("Library/Application Support/AvansiaDriver")
let runtime = base.appendingPathComponent("runtime")
let agent = home.appendingPathComponent("Library/LaunchAgents/local.avansia.ipp.plist")
let logs = home.appendingPathComponent("Library/Logs/AvansiaDriver")
let queue = "Evolis_Avansia"
let uri = "ipp://localhost:18631/ipp/print"
let domain = "gui/\(getuid())"
let service = domain + "/local.avansia.ipp"

@discardableResult
func run(_ executable: String, _ arguments: [String], checked: Bool = true) throws -> (Int32, String) {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)
    if checked && process.terminationStatus != 0 {
        throw SetupError("\(executable) failed (\(process.terminationStatus)): \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
    return (process.terminationStatus, text)
}

func folder(_ url: URL) throws {
    try files.createDirectory(at: url, withIntermediateDirectories: true,
                             attributes: [.posixPermissions: 0o700])
    try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
}

func pendingJobs() throws -> String {
    try run("/usr/bin/lpstat", ["-W", "not-completed", "-o", queue]).1
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

func install(_ source: URL) throws {
    for path in ["AvansiaJob", "AvansiaCore", "AvansiaService", "CardRaster", "bin/ippeveprinter"] {
        let binary = source.appendingPathComponent("runtime/" + path)
        guard files.isExecutableFile(atPath: binary.path) else { throw SetupError("Missing native executable: " + path) }
        try run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
    }
    let existing = try run("/usr/bin/lpstat", ["-v", queue], checked: false)
    if existing.0 == 0 {
        throw SetupError("An Evolis_Avansia queue already exists. This installer does not replace a live installation; uninstall it after all jobs finish first.")
    }
    guard !files.fileExists(atPath: base.appendingPathComponent("spool/active-job.ipp").path),
          !files.fileExists(atPath: base.appendingPathComponent("state/inflight.json").path) else {
        throw SetupError("Resolve the stopped or uncertain card before changing the driver")
    }
    let loaded = try run("/bin/launchctl", ["print", service], checked: false).0 == 0
    guard !loaded && !files.fileExists(atPath: agent.path) else {
        throw SetupError("An Avansia login service already exists. Finish all jobs and uninstall it before reinstalling.")
    }
    var lockError = [CChar](repeating: 0, count: 1024)
    var lock = avansia_lock(&lockError, lockError.count)
    guard lock >= 0 else { throw SetupError(String(cString: lockError)) }
    defer { if lock >= 0 { close(lock) } }
    guard !files.fileExists(atPath: base.appendingPathComponent("spool/active-job.ipp").path),
          !files.fileExists(atPath: base.appendingPathComponent("state/inflight.json").path) else {
        throw SetupError("A card became active; finish or recover it before installation")
    }
    if !loaded {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SetupError("Cannot inspect local service port") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(18631).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { throw SetupError("Port 18631 is already occupied") }
    }
    try folder(base)
    let stamp = String(UInt64(Date().timeIntervalSince1970 * 1_000_000))
    let staging = base.appendingPathComponent("runtime.new-" + stamp)
    try files.copyItem(at: source.appendingPathComponent("runtime"), to: staging)
    if files.fileExists(atPath: runtime.path) {
        try files.moveItem(at: runtime, to: base.appendingPathComponent("runtime.backup-" + stamp))
    }
    try files.moveItem(at: staging, to: runtime)
    close(lock)
    lock = -1
    try folder(logs)
    try files.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
    let configuration: [String: Any] = [
        "Label": "local.avansia.ipp",
        "ProgramArguments": [runtime.appendingPathComponent("AvansiaService").path],
        "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
        "ExitTimeOut": 240, "Umask": 63,
        "StandardOutPath": logs.appendingPathComponent("service.log").path,
        "StandardErrorPath": logs.appendingPathComponent("service.log").path
    ]
    try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0).write(to: agent, options: .atomic)
    try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
    try run("/bin/launchctl", ["bootstrap", domain, agent.path])
    var ready = false
    for _ in 0..<100 {
        let probe = try run("/usr/bin/ipptool", ["-T", "2", "-t", uri,
                        "/usr/share/cups/ipptool/get-printer-attributes.test"], checked: false)
        if probe.0 == 0 { ready = true; break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard ready else { throw SetupError("The native service did not start; inspect ~/Library/Logs/AvansiaDriver/service.log") }
    try run("/usr/sbin/lpadmin", ["-p", queue, "-v", uri, "-m", "everywhere", "-D", "Evolis Avansia",
            "-L", "USB - CR80 cards", "-o", "printer-is-shared=false", "-o", "printer-error-policy=abort-job", "-E"])
    let choices = try run("/usr/bin/lpoptions", ["-p", queue, "-l"]).1
    guard let mediaLine = choices.split(separator: "\n").first(where: { $0.hasPrefix("PageSize/") }),
          let colon = mediaLine.firstIndex(of: ":"),
          let rawMedia = mediaLine[mediaLine.index(after: colon)...].split(separator: " ")
            .first(where: { $0.contains("Borderless") && $0.contains("53.98x85.6") }) else {
        throw SetupError("The CR80 borderless paper size was not generated")
    }
    let media = rawMedia.hasPrefix("*") ? String(rawMedia.dropFirst()) : String(rawMedia)
    try run("/usr/sbin/lpadmin", ["-p", queue, "-o", "PageSize=" + media,
        "-o", "Duplex=DuplexNoTumble",
        "-o", "cupsPrintQuality=High", "-o", "print-quality-default=5",
        "-o", "print-scaling-default=none", "-o", "orientation-requested-default=3"])
    print("Installed native Evolis Avansia printer. CR80 borderless, 600 dpi, duplex, actual size.")
    print("Runtime: " + runtime.path)
}

func uninstall() throws {
    let existing = try run("/usr/bin/lpstat", ["-v", queue], checked: false)
    var restoreAcceptance = false
    if existing.0 == 0 {
        guard existing.1.contains(uri) else { throw SetupError("Refusing to remove another printer") }
        let information = try run("/usr/bin/ipptool", ["-tv", "ipp://localhost:631/printers/" + queue,
                                   "/usr/share/cups/ipptool/get-printer-attributes.test"]).1
        restoreAcceptance = information.contains("printer-is-accepting-jobs (boolean) = true")
        try run("/usr/sbin/cupsreject", ["-r", "Avansia uninstall in progress", queue])
    }
    defer {
        if restoreAcceptance { _ = try? run("/usr/sbin/cupsaccept", [queue]) }
    }
    var lockError = [CChar](repeating: 0, count: 1024)
    let lock = avansia_lock(&lockError, lockError.count)
    guard lock >= 0 else { throw SetupError(String(cString: lockError)) }
    defer { close(lock) }
    if existing.0 == 0 {
        guard try pendingJobs().isEmpty else { throw SetupError("Finish or cancel Avansia jobs first") }
    }
    guard !files.fileExists(atPath: base.appendingPathComponent("spool/active-job.ipp").path),
          !files.fileExists(atPath: base.appendingPathComponent("state/inflight.json").path) else {
        throw SetupError("Resolve the active or uncertain card before uninstalling")
    }
    if existing.0 == 0 {
        try run("/usr/sbin/lpadmin", ["-x", queue])
        restoreAcceptance = false
    }
    if try run("/bin/launchctl", ["print", service], checked: false).0 == 0 {
        try run("/bin/launchctl", ["bootout", service])
    }
    if files.fileExists(atPath: agent.path) { try files.removeItem(at: agent) }
    print("Removed Avansia printer and login service; runtime and recovery records retained at " + base.path)
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count >= 2 else { throw SetupError("Usage: AvansiaSetup install [package-folder] | uninstall | status | cancel-stopped REMOTE-ID | acknowledge --confirm-card-inspected") }
    switch arguments[1] {
    case "install":
        let source = arguments.count > 2 ? URL(fileURLWithPath: arguments[2])
            : URL(fileURLWithPath: arguments[0]).standardizedFileURL.deletingLastPathComponent()
        try install(source)
    case "uninstall": try uninstall()
    case "status":
        if files.fileExists(atPath: base.appendingPathComponent("spool/active-job.ipp").path) {
            print(try run("/usr/bin/ipptool", ["-tv", uri, "/usr/share/cups/ipptool/get-jobs.test"], checked: false).1)
        }
        print(try run(runtime.appendingPathComponent("AvansiaCore").path, ["ribbon"], checked: false).1, terminator: "")
    case "cancel-stopped":
        guard arguments.count == 3, let identifier = Int(arguments[2]), identifier > 0 else { throw SetupError("Specify the stopped remote job ID") }
        guard try pendingJobs().isEmpty else { throw SetupError("Cancel local Avansia jobs in macOS first, then cancel the stopped remote job") }
        let jobURI = uri + "/\(identifier)"
        let state = try run("/usr/bin/ipptool", ["-tv", jobURI, "/usr/share/cups/ipptool/get-job-attributes.test"]).1
        guard state.contains("job-state (enum) = processing-stopped") else { throw SetupError("The specified remote job is not stopped") }
        try run("/usr/bin/ipptool", ["-tv", jobURI, runtime.appendingPathComponent("cancel-stopped.test").path])
        print("Remote job canceled. No job was resubmitted; physical card acknowledgement remains separate.")
    case "acknowledge":
        guard arguments.count == 3 && arguments[2] == "--confirm-card-inspected" else { throw SetupError("Inspect the physical card first, then use --confirm-card-inspected") }
        guard try pendingJobs().isEmpty,
              !files.fileExists(atPath: base.appendingPathComponent("spool/active-job.ipp").path) else { throw SetupError("Cancel local and stopped remote Avansia jobs before acknowledgement") }
        print(try run(runtime.appendingPathComponent("AvansiaCore").path,
                      ["acknowledge", "--confirm-card-inspected"]).1, terminator: "")
    default: throw SetupError("Unknown command")
    }
} catch {
    fputs("Avansia setup: \(error)\n", stderr)
    exit(1)
}
