import Foundation
import Darwin

let setupTestHome = FileManager.default.temporaryDirectory.appendingPathComponent("AvansiaSetupTests-" + UUID().uuidString)

struct MockSetup {
    var queueURI: String?
    var queryError = false
    var localizedQueueOutput = false
    var loaded = false
    var accepting = true
    var paused = false
    var pending = ""
    var failure: String?
    var failed = false
    var partialReject = false
    var replaceQueueOnRejectFailure = false
    var failAcceptanceRecovery = false
    var ignoreAcceptanceRecovery = false
    var ignorePauseRecovery = false
    var acceptanceCalls = 0
    var failAcceptanceAt = 0
    var rollbackBootoutFailure = false
    var replaceRuntimeOnRecovery = false
    var replacePlistOnRecovery = false
    var ignoreRecoveryBootstrap = false
    var lockCalls = 0
    var assetFailure = false
    var calls: [String] = []
    var installedPPD = ""
    var configuredDefaults: [String] = []
}
var mock = MockSetup()

func testWrite(_ text: String, _ url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try text.write(to: url, atomically: true, encoding: .utf8)
}

func setupTestRun(_ executable: String, _ args: [String], _ checked: Bool) throws -> (Int32, String) {
    let name = URL(fileURLWithPath: executable).lastPathComponent
    let operation: String
    switch name {
    case "lpadmin":
        operation = args.contains("-x") ? "delete-queue" : args.contains("everywhere") ? "create-queue" : args.contains("-P") ? "set-ppd" : "defaults"
    case "launchctl": operation = args[0]
    default: operation = name
    }
    mock.calls.append(operation)
    if operation == "defaults" { mock.configuredDefaults = args }
    // Creation can mutate CUPS successfully before the command reports failure.
    if operation == "create-queue" {
        mock.queueURI = uri
        mock.accepting = true
        mock.paused = false
        if mock.failure != "missing-ppd" { try testWrite("*PPD-Adobe: \"4.3\"\n*APPrinterIconPath: \"old-icon\"\n", queuePPD()) }
    }
    if operation == "cupsaccept" {
        mock.acceptanceCalls += 1
        if mock.failAcceptanceRecovery || mock.acceptanceCalls == mock.failAcceptanceAt {
            throw SetupError("Injected acceptance recovery failure")
        }
        if mock.ignoreAcceptanceRecovery { return (0, "") }
    }
    if operation == "cupsdisable" && mock.ignorePauseRecovery { return (0, "") }
    if operation == mock.failure && !mock.failed {
        mock.failed = true
        if operation == "bootstrap" { mock.loaded = true }
        if operation == "cupsreject" && mock.partialReject {
            mock.accepting = false
            if mock.replaceQueueOnRejectFailure { mock.queueURI = "ipp://replacement.invalid/ipp/print" }
        }
        if checked { throw SetupError("Injected " + operation + " failure") }
        return (1, "Injected " + operation + " failure")
    }
    if operation == "bootout" && mock.failed && mock.rollbackBootoutFailure {
        throw SetupError("Injected rollback bootout failure")
    }
    if operation == "bootstrap" && mock.failed && mock.ignoreRecoveryBootstrap { return (0, "") }
    switch name {
    case "codesign": return (0, "")
    case "lpstat":
        if args.first == "-W" { return (0, mock.pending) }
        return mock.queueURI.map { (Int32(0), mock.localizedQueueOutput ? "用于\(queue)的设备：\($0)\n" : "device for \(queue): \($0)\n") } ?? (1, "Unknown queue")
    case "launchctl":
        switch args[0] {
        case "print": return (mock.loaded ? 0 : 1, "")
        case "bootstrap": mock.loaded = true
        case "bootout": mock.loaded = false
        default: throw SetupError("Unexpected launchctl invocation")
        }
    case "ipptool":
        if args.contains("-tv") {
            return (0, "printer-is-accepting-jobs (boolean) = \(mock.accepting)\nprinter-state (enum) = \(mock.paused ? "stopped" : "idle")\n")
        }
        return (0, "Service ready")
    case "lpadmin":
        if operation == "delete-queue" {
            mock.queueURI = nil
            try? FileManager.default.removeItem(at: queuePPD())
        } else if let index = args.firstIndex(of: "-P") {
            let data = try Data(contentsOf: URL(fileURLWithPath: args[index + 1]))
            try data.write(to: queuePPD())
            mock.installedPPD = String(decoding: data, as: UTF8.self)
            if let index = args.firstIndex(of: "-v") { mock.queueURI = args[index + 1] }
        }
    case "lpoptions": return (0, "PageSize/Media Size: *A4 Custom.53.98x85.6mmBorderless\n")
    case "cupsreject": mock.accepting = false
    case "cupsaccept": mock.accepting = true
    case "cupsdisable": mock.paused = true
    case "cupsenable": mock.paused = false
    default: throw SetupError("Unexpected command: " + executable)
    }
    return (0, "")
}

func setupTestQueueURI() throws -> String? {
    mock.calls.append("queue-query")
    if mock.queryError { throw SetupError("Injected CUPS queue query failure") }
    return mock.queueURI
}

func setupTestLock() throws -> Int32 {
    mock.lockCalls += 1
    if mock.replaceRuntimeOnRecovery && mock.lockCalls == 3 {
        try FileManager.default.moveItem(at: runtime, to: base.appendingPathComponent("runtime.displaced"))
        try testWrite("unrelated-runtime", runtime.appendingPathComponent("version"))
    }
    if mock.replacePlistOnRecovery && mock.lockCalls == 3 {
        try testWrite("unrelated-service-plist", agent)
        mock.loaded = true
    }
    let descriptor = open("/dev/null", O_RDONLY)
    guard descriptor >= 0 else { throw SetupError("Cannot open test lock descriptor") }
    return descriptor
}
func setupTestPort() throws {}
func setupTestAssets(_ staging: URL) throws {
    mock.calls.append("assets")
    if mock.assetFailure { throw SetupError("Injected asset preparation failure") }
    try testWrite("prepared-icon", staging.appendingPathComponent("Assets/Avansia.icns"))
}

func expectSetup(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    guard try condition() else { throw SetupError("Test failed: " + message) }
}
func expectFailure(_ text: String, _ action: () throws -> Void) throws {
    do { try action() } catch {
        try expectSetup(String(describing: error).contains(text), "Expected '\(text)', got '\(error)'")
        return
    }
    throw SetupError("Test failed: Expected failure containing " + text)
}

let oldPPD = "*PPD-Adobe: \"4.3\"\n*DefaultPageSize: PreviousCR80\n"
let oldPlist = "previous-service-plist"
let profile = "{\"fixture\":\"existing-user-calibration\"}"
let source = setupTestHome.appendingPathComponent("package")

func resetSetup(oldRuntime: Bool = false, installed: Bool = false) throws {
    try? FileManager.default.removeItem(at: setupTestHome)
    mock = MockSetup()
    for path in ["AvansiaJob", "AvansiaCore", "AvansiaService", "CardRaster", "bin/ippeveprinter"] {
        let binary = source.appendingPathComponent("runtime/" + path)
        try testWrite("synthetic-executable", binary)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: binary.path)
    }
    try testWrite("new-runtime", source.appendingPathComponent("runtime/version"))
    try testWrite(profile, base.appendingPathComponent("color-profile.json"))
    if oldRuntime || installed { try testWrite("old-runtime", runtime.appendingPathComponent("version")) }
    if installed {
        mock.queueURI = uri
        mock.loaded = true
        try testWrite(oldPPD, queuePPD())
        try testWrite(oldPlist, agent)
    }
}
func assertProfile() throws {
    try expectSetup(try String(contentsOf: base.appendingPathComponent("color-profile.json"), encoding: .utf8) == profile, "Existing color profile remains byte-for-byte unchanged")
}
func assertOldRuntime() throws {
    try expectSetup(try String(contentsOf: runtime.appendingPathComponent("version"), encoding: .utf8) == "old-runtime", "Previous runtime restored")
    try assertProfile()
    let entries = try FileManager.default.contentsOfDirectory(atPath: base.path)
    try expectSetup(!entries.contains { $0.hasPrefix("runtime.new-") || $0.hasPrefix("runtime.backup-") || $0.hasPrefix(".install-") || $0.hasPrefix(".restore-") }, "No transaction staging or backup residue")
}
func assertInitialRollback() throws {
    try assertOldRuntime()
    try expectSetup(mock.queueURI == nil && !mock.loaded, "New queue and service removed")
    try expectSetup(!FileManager.default.fileExists(atPath: agent.path), "New login plist removed")
}
func assertPreviousInstallation(accepting: Bool, paused: Bool, loaded: Bool = true) throws {
    try assertOldRuntime()
    try expectSetup(mock.queueURI == uri && mock.loaded == loaded, "Previous queue and service restored")
    try expectSetup(mock.accepting == accepting && mock.paused == paused, "Previous queue acceptance and pause state restored")
    try expectSetup(try String(contentsOf: queuePPD(), encoding: .utf8) == oldPPD, "Previous PPD restored exactly")
    try expectSetup(try String(contentsOf: agent, encoding: .utf8) == oldPlist, "Previous service plist restored exactly")
}

@main struct SetupTests {
    static func main() throws {
        defer { try? FileManager.default.removeItem(at: setupTestHome) }
        var count = 0
        func test(_ name: String, _ body: () throws -> Void) throws {
            try body(); count += 1; print("PASS: " + name)
        }
        try test("Native ownership ignores localized human output and requires exact device URI") {
            try resetSetup(installed: true)
            mock.localizedQueueOutput = true; mock.failure = "defaults"
            let human = try setupTestRun("/usr/bin/lpstat", ["-v", queue], false).1
            try expectSetup(human.hasPrefix("用于"), "Fixture uses the actual Chinese macOS prefix")
            try expectSetup(ownedQueue(try queueDeviceURI()), "Native exact URI is owned regardless of human language")
            for candidate in [uri + "/", "ipp://127.0.0.1:18631/ipp/print", "ipp://other.invalid/ipp/print"] {
                try expectSetup(!ownedQueue(candidate), "Similar or foreign URI is never owned")
            }
            try expectFailure("prior installation was restored") { try upgrade(source) }
            try assertPreviousInstallation(accepting: true, paused: false)
        }
        try test("Native queue absence and errors remain distinct and precede mutation") {
            try resetSetup()
            try expectSetup(try queueDeviceURI() == nil, "Missing queue is explicit absence")
            mock.queryError = true
            for operation in ["install", "upgrade", "uninstall", "queue-info"] {
                try expectFailure("CUPS queue query failure") { try setupMain(["AvansiaSetup", operation, source.path].prefix(operation == "queue-info" || operation == "uninstall" ? 2 : 3).map { $0 }) }
            }
            try expectSetup(mock.calls.allSatisfy { $0 == "queue-query" }, "Unknown queue state never becomes absence or triggers commands")
        }
        try test("queue-info emits only machine JSON for found and missing queues") {
            try resetSetup()
            for device in [nil, uri, "ipp://other.invalid/ipp/print"] as [String?] {
                mock.queueURI = device
                let capture = setupTestHome.appendingPathComponent("stdout.json")
                _ = FileManager.default.createFile(atPath: capture.path, contents: nil)
                let output = try FileHandle(forWritingTo: capture)
                fflush(stdout)
                let original = dup(STDOUT_FILENO)
                guard original >= 0 && dup2(output.fileDescriptor, STDOUT_FILENO) >= 0 else { throw SetupError("Cannot capture queue-info stdout") }
                do { try setupMain(["AvansiaSetup", "queue-info"]) }
                catch { fflush(stdout); dup2(original, STDOUT_FILENO); close(original); throw error }
                fflush(stdout); dup2(original, STDOUT_FILENO); close(original); try output.close()
                let data = try Data(contentsOf: capture)
                let information = try JSONSerialization.jsonObject(with: data) as! [String: Any]
                try expectSetup(information.count == 2 && information["exists"] as? Bool == (device != nil), "JSON existence matches native query")
                if let device { try expectSetup(information["device_uri"] as? String == device, "JSON preserves exact device URI") }
                else { try expectSetup(information["device_uri"] is NSNull, "Missing queue uses JSON null") }
            }
            try expectFailure("no arguments") { try setupMain(["AvansiaSetup", "queue-info", "other-queue"]) }
            try expectSetup(mock.calls.allSatisfy { $0 == "queue-query" }, "queue-info invokes no mutations or human commands")
        }
        try test("Initial install configures native service, PPD and queue defaults") {
            try resetSetup()
            try install(source)
            try expectSetup(mock.queueURI == uri && mock.loaded && mock.accepting && !mock.paused, "Queue is enabled and accepting only after configuration")
            try expectSetup(try String(contentsOf: runtime.appendingPathComponent("version"), encoding: .utf8) == "new-runtime", "New runtime installed")
            try expectSetup(mock.installedPPD.contains("application/pdf application/pdf 0 -") && mock.installedPPD.contains(runtime.appendingPathComponent("Assets/Avansia.icns").path), "Installed PPD has direct PDF filter and runtime icon")
            try expectSetup(!mock.installedPPD.contains("old-icon"), "Stale icon path removed")
            let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: agent), format: nil) as! [String: Any]
            try expectSetup(plist["ProgramArguments"] as? [String] == [runtime.appendingPathComponent("AvansiaService").path], "Login service invokes installed native runtime")
            try expectSetup(mock.calls.firstIndex(of: "defaults")! < mock.calls.firstIndex(of: "cupsaccept")!, "Defaults precede queue acceptance")
            try expectSetup(mock.configuredDefaults == ["-p", queue, "-o", "PageSize=Custom.53.98x85.6mmBorderless", "-o", "Duplex=DuplexNoTumble", "-o", "cupsPrintQuality=High", "-o", "print-quality-default=5", "-o", "print-scaling-default=none", "-o", "orientation-requested-default=3"], "CR80, duplex, high quality, actual-size and portrait defaults are configured exactly")
            try assertProfile()
        }
        for blocked in ["spool/active-job.ipp", "state/inflight.json"] {
            try test("Initial install refuses " + blocked) {
                try resetSetup(oldRuntime: true)
                try testWrite("synthetic-card-state", base.appendingPathComponent(blocked))
                try expectFailure("card") { try install(source) }
                try assertInitialRollback()
                try expectSetup(!mock.calls.contains("assets") && !mock.calls.contains("bootstrap"), "Card-state refusal precedes staging and service creation")
            }
        }
        for injection in ["bootstrap", "missing-ppd", "set-ppd", "defaults", "create-queue", "cupsaccept"] {
            try test("Initial install rolls back after " + injection) {
                try resetSetup(oldRuntime: true)
                mock.failure = injection
                try expectFailure("Installation failed") { try install(source) }
                try assertInitialRollback()
                if injection == "create-queue" { try expectSetup(mock.failed && mock.calls.contains("delete-queue"), "Partial queue creation is removed despite command failure") }
            }
        }
        for accepting in [true, false] {
            for paused in [true, false] {
                try test("Failed upgrade restores PPD, service and queue state accepting=\(accepting) paused=\(paused)") {
                    try resetSetup(installed: true)
                    mock.accepting = accepting; mock.paused = paused; mock.failure = "defaults"
                    try expectFailure("prior installation was restored") { try upgrade(source) }
                    try assertPreviousInstallation(accepting: accepting, paused: paused)
                }
            }
        }
        for operation in ["uninstall", "upgrade"] {
            for accepting in [true, false] {
                for paused in [true, false] {
                    try test("Partial rejection failure restores intact queue: \(operation), accepting=\(accepting), paused=\(paused)") {
                        try resetSetup(installed: true)
                        mock.accepting = accepting; mock.paused = paused
                        mock.failure = "cupsreject"; mock.partialReject = true
                        try expectFailure(operation == "upgrade" ? "prior installation was restored" : "Injected cupsreject failure") {
                            if operation == "upgrade" { try upgrade(source) } else { try uninstall() }
                        }
                        try assertPreviousInstallation(accepting: accepting, paused: paused)
                        try expectSetup(!mock.calls.contains("delete-queue") && !mock.calls.contains("bootout"), "Partial rejection never tears down intact runtime or service")
                        try expectSetup(mock.calls.filter { $0 == (paused ? "cupsdisable" : "cupsenable") }.count == (operation == "upgrade" ? 2 : 1), "Intact queue paused state is restored in each recovery boundary")
                    }
                }
            }
        }
        for operation in ["uninstall", "upgrade"] {
            try test("Failed acceptance recovery reports incomplete: " + operation) {
                try resetSetup(installed: true)
                mock.failure = "cupsreject"; mock.partialReject = true; mock.failAcceptanceRecovery = true
                do {
                    if operation == "upgrade" { try upgrade(source) } else { try uninstall() }
                    throw SetupError("Test failed: acceptance recovery unexpectedly succeeded")
                } catch {
                    try expectSetup((error as? SetupError)?.recoveryIncomplete == true, "Acceptance failure propagates incomplete recovery")
                    try expectSetup(!String(describing: error).contains("prior installation was restored"), "Failed acceptance recovery never claims full restoration")
                }
                try expectSetup(mock.queueURI == uri && mock.loaded && !mock.accepting, "Intact queue and service retained for manual recovery")
                try expectSetup(try String(contentsOf: queuePPD(), encoding: .utf8) == oldPPD, "Intact PPD preserved on recovery failure")
                try assertOldRuntime()
            }
        }
        try test("Queue cleanup never restores state on a replacement unowned queue") {
            try resetSetup(installed: true)
            mock.failure = "cupsreject"; mock.partialReject = true; mock.replaceQueueOnRejectFailure = true
            try expectFailure("queue changed") { try uninstall() }
            try expectSetup(mock.queueURI == "ipp://replacement.invalid/ipp/print", "Replacement queue retained")
            try expectSetup(!mock.calls.contains("cupsaccept") && !mock.calls.contains("cupsenable") && !mock.calls.contains("cupsdisable") && !mock.calls.contains("delete-queue"), "Recovery refuses to mutate a replacement queue")
            try expectSetup(mock.loaded && (try String(contentsOf: agent, encoding: .utf8)) == oldPlist, "Previous service plist retained")
            try assertOldRuntime()
        }
        try test("Outer upgrade reports incomplete if intact queue acceptance recovery fails") {
            try resetSetup(installed: true)
            mock.failure = "cupsreject"; mock.partialReject = true; mock.failAcceptanceAt = 2
            try expectFailure("Recovery requires attention") { try upgrade(source) }
            try expectSetup(mock.acceptanceCalls == 2 && mock.queueURI == uri && mock.loaded, "Outer recovery attempts intact queue state restoration and reports its failure")
            try assertOldRuntime()
        }
        try test("Queue acceptance recovery requires IPP readback") {
            try resetSetup(installed: true)
            mock.failure = "cupsreject"; mock.partialReject = true; mock.ignoreAcceptanceRecovery = true
            try expectFailure("prior queue acceptance or paused state was not restored") { try uninstall() }
            try expectSetup(!mock.accepting && mock.queueURI == uri && mock.loaded, "Command success alone cannot prove queue acceptance restored")
            try assertOldRuntime()
        }
        try test("Outer upgrade requires paused-state readback for recreated queue") {
            try resetSetup(installed: true)
            mock.failure = "defaults"; mock.paused = true
            // The new queue resets pause state; ignore recovery's pause command.
            mock.ignorePauseRecovery = true
            try expectFailure("prior queue acceptance or paused state was not restored") { try upgrade(source) }
            try expectSetup(mock.queueURI == uri && mock.loaded, "Old queue/service remain available when readback detects incomplete recovery")
            try assertOldRuntime()
        }
        try test("Failed upgrade preserves registered but unloaded prior service plist") {
            try resetSetup(installed: true)
            mock.loaded = false; mock.failure = "defaults"
            try expectFailure("prior installation was restored") { try upgrade(source) }
            try assertPreviousInstallation(accepting: true, paused: false, loaded: false)
            try expectSetup(mock.calls.filter { $0 == "bootstrap" }.count == 1, "Previously unloaded service is never bootstrapped during recovery")
        }
        try test("Failed inner rollback never claims prior upgrade restored after bootout failure") {
            try resetSetup(installed: true)
            mock.failure = "defaults"; mock.rollbackBootoutFailure = true
            try expectFailure("Recovery requires attention") {
                do { try upgrade(source) } catch {
                    try expectSetup(!String(describing: error).contains("prior installation was restored"), "Incomplete rollback cannot report recovery success")
                    throw error
                }
            }
            try expectSetup(mock.loaded && mock.queueURI == nil, "New service is retained safely and old queue is not recreated against the wrong runtime")
            try expectSetup(try String(contentsOf: runtime.appendingPathComponent("version"), encoding: .utf8) == "new-runtime", "Running service retains its runtime")
            let backups = try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("runtime.backup-") }
            try expectSetup(backups.count == 1, "Previous runtime backup remains available")
            try expectSetup(try String(contentsOf: backups[0].appendingPathComponent("version"), encoding: .utf8) == "old-runtime", "Retained backup is the previous runtime")
            try assertProfile()
        }
        try test("Upgrade recovery verifies prior runtime identity before restoring service") {
            try resetSetup(installed: true)
            mock.failure = "defaults"; mock.replaceRuntimeOnRecovery = true
            try expectFailure("prior runtime was not restored") { try upgrade(source) }
            try expectSetup(!mock.loaded && mock.queueURI == nil, "Mismatched runtime never receives the prior service or queue")
            try expectSetup(try String(contentsOf: base.appendingPathComponent("runtime.displaced/version"), encoding: .utf8) == "old-runtime", "Previous runtime remains recoverable")
            try assertProfile()
        }
        try test("Upgrade recovery refuses a loaded service with mismatched prior plist") {
            try resetSetup(installed: true)
            mock.failure = "defaults"; mock.replacePlistOnRecovery = true
            try expectFailure("loaded service does not match") { try upgrade(source) }
            try expectSetup(mock.loaded && mock.queueURI == nil, "Mismatched loaded service is retained without recreating the old queue")
            try expectSetup(try String(contentsOf: agent, encoding: .utf8) == "unrelated-service-plist", "Recovery never overwrites the mismatched loaded service plist")
            try assertOldRuntime()
        }
        try test("Upgrade recovery verifies service loaded readback before success") {
            try resetSetup(installed: true)
            mock.failure = "defaults"; mock.ignoreRecoveryBootstrap = true
            try expectFailure("prior service plist or loaded state was not restored") { try upgrade(source) }
            try expectSetup(!mock.loaded && mock.queueURI == nil, "Failed service recovery does not recreate the queue")
            try assertOldRuntime()
        }
        for operation in ["upgrade", "uninstall"] {
            for blocked in ["pending", "spool/active-job.ipp", "state/inflight.json"] {
                try test(operation + " refuses " + blocked) {
                    try resetSetup(installed: true)
                    if blocked == "pending" { mock.pending = queue + "-17 user 1024" }
                    else { try testWrite("synthetic-card-state", base.appendingPathComponent(blocked)) }
                    try expectFailure(blocked == "pending" ? "jobs" : "card") {
                        if operation == "upgrade" { try upgrade(source) } else { try uninstall() }
                    }
                    try assertPreviousInstallation(accepting: true, paused: false)
                    try expectSetup(!mock.calls.contains("delete-queue") && !mock.calls.contains("bootout") && !mock.calls.contains("assets"), "Refusal precedes teardown or asset staging")
                }
            }
        }
        for operation in ["install", "upgrade", "uninstall"] {
            try test(operation + " never deletes a preexisting unowned queue") {
                try resetSetup(installed: true)
                mock.queueURI = "ipp://other-printer.invalid/ipp/print"
                try expectFailure(operation == "install" ? "already exists" : "another printer") {
                    switch operation { case "install": try install(source); case "upgrade": try upgrade(source); default: try uninstall() }
                }
                try expectSetup(mock.queueURI == "ipp://other-printer.invalid/ipp/print" && mock.loaded, "Unowned queue and service retained")
                try expectSetup(!mock.calls.contains("delete-queue") && !mock.calls.contains("cupsreject") && !mock.calls.contains("bootout"), "Unowned queue refusal has no destructive command")
                try assertOldRuntime()
            }
        }
        for upgrading in [false, true] {
            try test("Asset failure preserves old installation upgrade=\(upgrading)") {
                try resetSetup(oldRuntime: true, installed: upgrading)
                mock.assetFailure = true
                try expectFailure("asset preparation") { if upgrading { try upgrade(source) } else { try install(source) } }
                if upgrading { try assertPreviousInstallation(accepting: true, paused: false) } else { try assertInitialRollback() }
                try expectSetup(!mock.calls.contains("bootstrap") && !mock.calls.contains("bootout") && !mock.calls.contains("delete-queue"), "Asset preparation fails before installation mutation")
            }
        }
        print("PASS: \(count) isolated installer transaction tests; all host commands mocked")
    }
}
