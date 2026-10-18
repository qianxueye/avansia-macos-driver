import Foundation
import Darwin

struct SetupError: Error, CustomStringConvertible {
    let description: String
    let recoveryIncomplete: Bool
    init(_ value: String, recoveryIncomplete: Bool = false) { description = value; self.recoveryIncomplete = recoveryIncomplete }
}

let files = FileManager.default
#if SETUP_TESTS
let home = setupTestHome
#else
let home = files.homeDirectoryForCurrentUser
#endif
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
#if SETUP_TESTS
    return try setupTestRun(executable, arguments, checked)
#else
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    var environment = ProcessInfo.processInfo.environment
    environment["LC_ALL"] = "C"
    environment["LANG"] = "C"
    process.environment = environment
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
#endif
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

func requireNoCard() throws {
    guard !files.fileExists(atPath: base.appendingPathComponent("spool/active-job.ipp").path),
          !files.fileExists(atPath: base.appendingPathComponent("state/inflight.json").path) else {
        throw SetupError("Resolve the active, stopped or uncertain card before changing the driver")
    }
}

func ownedQueue(_ information: String) -> Bool {
    information.trimmingCharacters(in: .whitespacesAndNewlines) == "device for \(queue): \(uri)"
}

func setupLock() throws -> Int32 {
#if SETUP_TESTS
    return try setupTestLock()
#else
    var error = [CChar](repeating: 0, count: 1024)
    let descriptor = avansia_lock(&error, error.count)
    guard descriptor >= 0 else { throw SetupError(String(cString: error)) }
    return descriptor
#endif
}

func verifyPort() throws {
#if SETUP_TESTS
    try setupTestPort()
#else
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
#endif
}

func stageRuntime(_ source: URL) throws -> URL {
    for path in ["AvansiaJob", "AvansiaCore", "AvansiaService", "CardRaster", "bin/ippeveprinter"] {
        let binary = source.appendingPathComponent("runtime/" + path)
        guard files.isExecutableFile(atPath: binary.path) else { throw SetupError("Missing native executable: " + path) }
        try run("/usr/bin/codesign", ["--verify", "--strict", binary.path])
    }
    try folder(base)
    let staging = base.appendingPathComponent("runtime.new-" + UUID().uuidString)
    try files.copyItem(at: source.appendingPathComponent("runtime"), to: staging)
    do {
#if SETUP_TESTS
        try setupTestAssets(staging)
#else
        try RuntimeAssets.prepare(runtime: staging, previous: runtime,
                                  iconBuilder: source.appendingPathComponent("BuildIcons"))
#endif
        return staging
    } catch {
        try? files.removeItem(at: staging)
        throw error
    }
}

func queuePPD() -> URL {
#if SETUP_TESTS
    return home.appendingPathComponent("queue.ppd")
#else
    return URL(fileURLWithPath: "/etc/cups/ppd/\(queue).ppd")
#endif
}

func augmentedPPD(_ source: String, icon: URL) throws -> String {
    guard !icon.path.contains("\n"), !icon.path.contains("\r"), !icon.path.contains("\"") else {
        throw SetupError("The runtime icon path cannot be represented in a PPD")
    }
    var lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        .filter { !$0.hasPrefix("*APPrinterIconPath:") }
        .map(String.init)
    let direct = "*cupsFilter2: \"application/pdf application/pdf 0 -\""
    if !lines.contains(direct) { lines.append(direct) }
    lines.append("*APPrinterIconPath: \"\(icon.path)\"")
    return lines.joined(separator: "\n") + "\n"
}

func install(_ source: URL, prepared: URL? = nil) throws {
    guard try run("/usr/bin/lpstat", ["-v", queue], checked: false).0 != 0 else {
        throw SetupError("An Evolis_Avansia queue already exists; use upgrade after jobs finish")
    }
    try requireNoCard()
    guard try run("/bin/launchctl", ["print", service], checked: false).0 != 0,
          !files.fileExists(atPath: agent.path) else { throw SetupError("An Avansia login service already exists") }
    let staging = try prepared ?? stageRuntime(source)
    defer { try? files.removeItem(at: staging) }
    var lock = try setupLock()
    defer { if lock >= 0 { close(lock) } }
    try requireNoCard()
    guard try run("/usr/bin/lpstat", ["-v", queue], checked: false).0 != 0,
          try run("/bin/launchctl", ["print", service], checked: false).0 != 0,
          !files.fileExists(atPath: agent.path) else { throw SetupError("Another installation became active") }
    try verifyPort()
    try folder(logs)
    try files.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
    let backup = base.appendingPathComponent("runtime.backup-" + UUID().uuidString)
    var archived = false, placed = false, wroteAgent = false, bootstrapAttempted = false, queueAttempted = false
    let configuration: [String: Any] = [
        "Label": "local.avansia.ipp",
        "ProgramArguments": [runtime.appendingPathComponent("AvansiaService").path],
        "RunAtLoad": true, "KeepAlive": true, "ThrottleInterval": 10,
        "ExitTimeOut": 240, "Umask": 63,
        "StandardOutPath": logs.appendingPathComponent("service.log").path,
        "StandardErrorPath": logs.appendingPathComponent("service.log").path
    ]
    let agentData = try PropertyListSerialization.data(fromPropertyList: configuration, format: .xml, options: 0)
    do {
    if files.fileExists(atPath: runtime.path) { try files.moveItem(at: runtime, to: backup); archived = true }
    try files.moveItem(at: staging, to: runtime); placed = true
    try agentData.write(to: agent, options: .atomic); wroteAgent = true
    try files.setAttributes([.posixPermissions: 0o644], ofItemAtPath: agent.path)
    bootstrapAttempted = true
    try run("/bin/launchctl", ["bootstrap", domain, agent.path])
    var ready = false
    for _ in 0..<30 {
        let probe = try run("/usr/bin/ipptool", ["-T", "2", "-t", uri,
                        "/usr/share/cups/ipptool/get-printer-attributes.test"], checked: false)
        if probe.0 == 0 { ready = true; break }
        Thread.sleep(forTimeInterval: 0.2)
    }
    guard ready else { throw SetupError("The native service did not start; inspect ~/Library/Logs/AvansiaDriver/service.log") }
    queueAttempted = true
    try run("/usr/sbin/lpadmin", ["-p", queue, "-v", uri, "-m", "everywhere", "-D", "Evolis Avansia",
            "-L", "USB - CR80 cards", "-o", "printer-is-shared=false", "-o", "printer-error-policy=abort-job"])
    try run("/usr/sbin/cupsreject", ["-r", "Avansia installation in progress", queue])
    let ppd = try String(contentsOf: queuePPD(), encoding: .utf8)
    let temporaryPPD = base.appendingPathComponent(".install-" + UUID().uuidString + ".ppd")
    defer { try? files.removeItem(at: temporaryPPD) }
    try augmentedPPD(ppd, icon: runtime.appendingPathComponent("Assets/Avansia.icns"))
        .write(to: temporaryPPD, atomically: true, encoding: .utf8)
    try run("/usr/sbin/lpadmin", ["-p", queue, "-P", temporaryPPD.path])
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
    close(lock); lock = -1
    try run("/usr/sbin/cupsenable", [queue])
    try run("/usr/sbin/cupsaccept", [queue])
    print("Installed native Evolis Avansia printer. CR80 borderless, 600 dpi, duplex, actual size.")
    print("Runtime: " + runtime.path)
    } catch {
        do {
            if lock < 0 { lock = try setupLock() }
            try requireNoCard()
            if queueAttempted, try run("/usr/bin/lpstat", ["-v", queue], checked: false).0 == 0 {
                guard try pendingJobs().isEmpty else { throw SetupError("A queue job became pending") }
            }
        } catch {
            throw SetupError("Installation did not finish, but active work prevents rollback. Runtime and backup are retained at \(base.path). Inspect jobs before changing the installation. \(error)", recoveryIncomplete: true)
        }
        var rollbackErrors: [String] = []
        func recover(_ action: () throws -> Void) { do { try action() } catch { rollbackErrors.append(String(describing: error)) } }
        if queueAttempted {
            recover {
                let current = try run("/usr/bin/lpstat", ["-v", queue], checked: false)
                if current.0 == 0 {
                    guard ownedQueue(current.1), try pendingJobs().isEmpty else { throw SetupError("Rollback retained a changed or nonempty queue") }
                    try requireNoCard()
                    try run("/usr/sbin/lpadmin", ["-x", queue])
                }
            }
        }
        var serviceStopped = true
        if bootstrapAttempted {
            serviceStopped = false
            recover {
                if try run("/bin/launchctl", ["print", service], checked: false).0 == 0 {
                    try run("/bin/launchctl", ["bootout", service])
                }
                guard try run("/bin/launchctl", ["print", service], checked: false).0 != 0 else {
                    throw SetupError("The attempted service is still loaded")
                }
                serviceStopped = true
            }
        }
        if serviceStopped {
            if wroteAgent { recover { if try Data(contentsOf: agent) == agentData { try files.removeItem(at: agent) } } }
            if placed { recover { try requireNoCard(); try files.removeItem(at: runtime) } }
            if archived { recover { try files.moveItem(at: backup, to: runtime) } }
        }
        throw SetupError("Installation failed: \(error). " + (rollbackErrors.isEmpty ? "Resources created by this attempt were rolled back." : "Rollback requires attention: " + rollbackErrors.joined(separator: "; ")), recoveryIncomplete: !rollbackErrors.isEmpty)
    }
}

func restoreQueueState(accepting: Bool, paused: Bool) throws {
    let current = try run("/usr/bin/lpstat", ["-v", queue], checked: false)
    guard current.0 == 0, ownedQueue(current.1) else {
        throw SetupError("The queue changed before its previous state could be restored")
    }
    try run("/usr/sbin/" + (paused ? "cupsdisable" : "cupsenable"), [queue])
    try run("/usr/sbin/" + (accepting ? "cupsaccept" : "cupsreject"), [queue])
    let information = try run("/usr/bin/ipptool", ["-tv", "ipp://localhost:631/printers/" + queue,
                               "/usr/share/cups/ipptool/get-printer-attributes.test"]).1
    let restoredPause = paused ? information.contains("printer-state (enum) = stopped")
        : information.contains("printer-state (enum) = idle") || information.contains("printer-state (enum) = processing")
    guard information.contains("printer-is-accepting-jobs (boolean) = \(accepting)"), restoredPause else {
        throw SetupError("The prior queue acceptance or paused state was not restored")
    }
}

func uninstall() throws {
    let existing = try run("/usr/bin/lpstat", ["-v", queue], checked: false)
    var accepted = false, paused = false, restoreState = false
    if existing.0 == 0 {
        guard ownedQueue(existing.1) else { throw SetupError("Refusing to remove another printer") }
        let information = try run("/usr/bin/ipptool", ["-tv", "ipp://localhost:631/printers/" + queue,
                                   "/usr/share/cups/ipptool/get-printer-attributes.test"]).1
        accepted = information.contains("printer-is-accepting-jobs (boolean) = true")
        paused = information.contains("printer-state (enum) = stopped")
    }
    do {
        if existing.0 == 0 {
            restoreState = true
            try run("/usr/sbin/cupsreject", ["-r", "Avansia uninstall in progress", queue])
        }
        let lock = try setupLock()
        defer { close(lock) }
        if existing.0 == 0 {
            guard try pendingJobs().isEmpty else { throw SetupError("Finish or cancel Avansia jobs first") }
        }
        try requireNoCard()
        if existing.0 == 0 {
            try run("/usr/sbin/lpadmin", ["-x", queue])
            restoreState = false
        }
        if try run("/bin/launchctl", ["print", service], checked: false).0 == 0 {
            try run("/bin/launchctl", ["bootout", service])
        }
        if files.fileExists(atPath: agent.path) { try files.removeItem(at: agent) }
    } catch {
        let originalError = error
        if restoreState {
            do { try restoreQueueState(accepting: accepted, paused: paused) }
            catch {
                throw SetupError("Uninstall failed: \(originalError). Queue recovery requires attention: \(error)", recoveryIncomplete: true)
            }
        }
        throw originalError
    }
    print("Removed Avansia printer and login service; runtime and recovery records retained at " + base.path)
}

func upgrade(_ source: URL) throws {
    let existing = try run("/usr/bin/lpstat", ["-v", queue], checked: false)
    if existing.0 != 0 { try install(source); return }
    guard ownedQueue(existing.1) else { throw SetupError("Refusing to update another printer") }
    try requireNoCard()
    guard try pendingJobs().isEmpty else { throw SetupError("Finish or cancel Avansia jobs before updating") }
    let staging = try stageRuntime(source)
    defer { try? files.removeItem(at: staging) }
    let oldRuntimeIdentity = try files.attributesOfItem(atPath: runtime.path)
    let oldPPD = try Data(contentsOf: queuePPD())
    let oldAgent = try? Data(contentsOf: agent)
    let oldLoaded = try run("/bin/launchctl", ["print", service], checked: false).0 == 0
    guard !oldLoaded || oldAgent != nil else { throw SetupError("The running service has no recovery plist; repair that installation before updating") }
    let information = try run("/usr/bin/ipptool", ["-tv", "ipp://localhost:631/printers/" + queue,
                               "/usr/share/cups/ipptool/get-printer-attributes.test"]).1
    let accepted = information.contains("printer-is-accepting-jobs (boolean) = true")
    let paused = information.contains("printer-state (enum) = stopped")
    do {
        try uninstall()
        try install(source, prepared: staging)
    } catch {
        let originalError = error
        do {
            let lock = try setupLock()
            defer { close(lock) }
            try requireNoCard()
            guard (originalError as? SetupError)?.recoveryIncomplete != true else {
                throw SetupError("The attempted installation could not roll back; automatic update recovery was deferred")
            }
            let restoredIdentity = try files.attributesOfItem(atPath: runtime.path)
            guard oldRuntimeIdentity[.systemNumber] as? NSNumber == restoredIdentity[.systemNumber] as? NSNumber,
                  oldRuntimeIdentity[.systemFileNumber] as? NSNumber == restoredIdentity[.systemFileNumber] as? NSNumber else {
                throw SetupError("The prior runtime was not restored; automatic update recovery was deferred")
            }
            let current = try run("/usr/bin/lpstat", ["-v", queue], checked: false)
            if current.0 == 0 {
                guard ownedQueue(current.1), try pendingJobs().isEmpty else {
                    throw SetupError("The current queue changed or has work; automatic update rollback was deferred")
                }
            }
            let currentLoaded = try run("/bin/launchctl", ["print", service], checked: false).0 == 0
            if currentLoaded {
                guard oldLoaded, let oldAgent, try Data(contentsOf: agent) == oldAgent else {
                    throw SetupError("The loaded service does not match the prior installation")
                }
            } else if let oldAgent {
                try oldAgent.write(to: agent, options: .atomic)
                if oldLoaded { try run("/bin/launchctl", ["bootstrap", domain, agent.path]) }
            }
            guard (try run("/bin/launchctl", ["print", service], checked: false).0 == 0) == oldLoaded,
                  (try? Data(contentsOf: agent)) == oldAgent else {
                throw SetupError("The prior service plist or loaded state was not restored")
            }
            if current.0 != 0 {
                let restored = base.appendingPathComponent(".restore-" + UUID().uuidString + ".ppd")
                defer { try? files.removeItem(at: restored) }
                try oldPPD.write(to: restored, options: .atomic)
                try run("/usr/sbin/lpadmin", ["-p", queue, "-v", uri, "-P", restored.path,
                                             "-D", "Evolis Avansia", "-L", "USB - CR80 cards",
                                             "-o", "printer-is-shared=false", "-o", "printer-error-policy=abort-job"])
            }
            try restoreQueueState(accepting: accepted, paused: paused)
        } catch {
            throw SetupError("Update failed: \(originalError). Recovery requires attention: \(error). Prior runtime archives remain at \(base.path)", recoveryIncomplete: true)
        }
        throw SetupError("Update failed; the prior installation was restored. \(originalError)")
    }
}

func setupMain(_ arguments: [String]) throws {
    guard arguments.count >= 2 else { throw SetupError("Usage: AvansiaSetup install|upgrade [package-folder] | import-sdk FILE | uninstall | status | cancel-stopped REMOTE-ID | acknowledge --confirm-card-inspected") }
    switch arguments[1] {
    case "install", "upgrade":
        guard arguments.count <= 3 else { throw SetupError("Specify at most one package folder") }
        let source = arguments.count > 2 ? URL(fileURLWithPath: arguments[2])
            : URL(fileURLWithPath: arguments[0]).standardizedFileURL.deletingLastPathComponent()
        if arguments[1] == "upgrade" { try upgrade(source) } else { try install(source) }
    case "import-sdk":
        guard arguments.count == 3 else { throw SetupError("Specify an official SDK 9.4.1 wheel or native macOS library") }
        let destination = home.appendingPathComponent("Library/Caches/AvansiaDriver/libevolis-9.4.1.dylib")
        try RuntimeAssets.importSDK(URL(fileURLWithPath: arguments[2]), to: destination)
        print("Verified and cached the official native SDK library. Install or update the driver to use it.")
    case "uninstall": try uninstall()
    case "status":
        if files.fileExists(atPath: base.appendingPathComponent("spool/active-job.ipp").path) {
            print(try run("/usr/bin/ipptool", ["-tv", uri, "/usr/share/cups/ipptool/get-jobs.test"], checked: false).1)
        }
        print(try run(runtime.appendingPathComponent("AvansiaCore").path, ["snapshot"], checked: false).1, terminator: "")
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
}

#if !SETUP_TESTS
@main struct AvansiaSetupEntry {
    static func main() {
        do { try setupMain(CommandLine.arguments) }
        catch {
            fputs("Avansia setup: \(error)\n", stderr)
            exit(1)
        }
    }
}
#endif
