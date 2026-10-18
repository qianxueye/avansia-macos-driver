import Foundation
import Darwin

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppFailure.message("Test failed: " + message) }
}
actor InstallationCommandFixture: AppCommandRunning {
    var queue = CommandResult(status: 0, output: #"{"exists":false,"device_uri":null}"#)
    var service = CommandResult(status: 113, output: "Could not find service \"local.avansia.ipp\" in domain for user gui: 501\n")
    var calls: [(String, [String])] = []
    var failNextProbe = false
    func configure(queue: CommandResult, service: CommandResult) { self.queue = queue; self.service = service }
    func timeoutNextProbe() { failNextProbe = true }
    func history() -> [(String, [String])] { calls }
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval, progress: @escaping @Sendable (String) -> Void) async throws -> CommandResult {
        calls.append((executable.path, arguments))
        if arguments == ["queue-info"] {
            try expect(executable.lastPathComponent == "AvansiaSetup" && timeout == 4, "Queue probe invokes the bounded native Setup JSON interface")
            if failNextProbe { failNextProbe = false; throw AppFailure.timedOut("device for OtherFixture: file:///dev/null") }
            try await Task.sleep(nanoseconds: 30_000_000)
            return queue
        }
        if executable.path == "/bin/launchctl" {
            try expect(arguments == ["print", "gui/\(getuid())/local.avansia.ipp"] && timeout == 4, "Service probe targets only the driver service")
            return service
        }
        if arguments.first == "uninstall" {
            queue = CommandResult(status: 0, output: #"{"exists":false,"device_uri":null}"#)
            service = CommandResult(status: 113, output: "Could not find service \"local.avansia.ipp\" in domain for user gui: 501\n")
        } else if arguments.first == "install" {
            queue = CommandResult(status: 0, output: #"{"exists":true,"device_uri":"ipp://localhost:18631/ipp/print"}"#)
            service = CommandResult(status: 0, output: "Synthetic loaded service\n")
        }
        return CommandResult(status: 0, output: "Synthetic command completed\n")
    }
}
@main struct AppModelTests {
    @MainActor static func main() async throws {
        try expect(Bundle.main.preferredLocalizations.first == "zh-Hans", "The packaged development language is Simplified Chinese")
        try expect(AppStrings.text("Unknown") == "\u{672A}\u{77E5}", "Chinese strings are loaded from the packaged resource")
        for key in ["Overview", "Supplies", "Disconnected", "Connected", "Printer error", "Sharpness", "Image Setup", "HIGH QUALITY", "Chip port #1", "Chip port #2", "External Box", "Physical inspection required", "I inspected the physical card and printer.", "Install", "Update", "Actual size", "Fit", "Fill"] {
            try expect(AppStrings.text(key) != key, "A visible status, setting, recovery, or operation label is localized: " + key)
        }
        try expect(AppStrings.format("Print copies: %ld", 13).contains("13"), "Localized print count interpolation preserves its value")
        try expect(AppStrings.format("Cancel stopped remote job %@?", "41").contains("41"), "Localized recovery prompt preserves the job identifier")
        try expect(AppStrings.connection("future-state") == AppStrings.text("Unknown"), "Unknown protocol states remain explicitly unknown")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AvansiaAppTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: folder) }
        let base = folder.appendingPathComponent("driver")
        let state = base.appendingPathComponent("state")
        let runtime = base.appendingPathComponent("runtime")
        let package = folder.appendingPathComponent("package")
        let agentFile = folder.appendingPathComponent("LaunchAgents/local.avansia.ipp.plist")
        for path in [state, runtime, package, agentFile.deletingLastPathComponent()] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        func snapshot(connection: String = "ready", stale: Bool = false, observed: Any? = nil, recovery: Bool = false, active: Bool = false, serial: String? = "SYNTHETIC-A") -> [String: Any] {
            ["schema_version": 1, "updated_at": timestamp, "observed_at": observed ?? timestamp,
             "connection": connection, "stale": stale, "device": ["model": "Synthetic printer", "serial": serial.map { $0 as Any } ?? NSNull()],
             "ribbon": ["remaining_percent": NSNull()], "film": ["remaining_percent": 0],
             "accessories": [["id": "test", "name": "Synthetic accessory", "status": "unknown"]],
             "queue": ["active_job": active, "recovery_required": recovery]]
        }
        func write(_ object: [String: Any], to path: URL = state.appendingPathComponent("status.json")) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
        }
        let model = UtilityModel(base: base, package: package, agentFile: agentFile, fixture: nil)
        model.reloadCache()
        try expect(!model.runtimeAvailable && model.cacheError != nil && !model.canReadDetails, "Missing runtime is visible and blocks native commands")
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        func verifyCommandLocale() async throws {
            let previousAll = getenv("LC_ALL").map { String(cString: $0) }
            let previousLanguage = getenv("LANG").map { String(cString: $0) }
            defer {
                if let previousAll { setenv("LC_ALL", previousAll, 1) } else { unsetenv("LC_ALL") }
                if let previousLanguage { setenv("LANG", previousLanguage, 1) } else { unsetenv("LANG") }
            }
            setenv("LC_ALL", "zh_CN.UTF-8", 1)
            setenv("LANG", "zh_CN.UTF-8", 1)
            let result = try await NativeCommandRunner().run(helper, ["locale"])
            let environment = try JSONSerialization.jsonObject(with: Data(result.output.utf8)) as? [String: String]
            try expect(result.status == 0 && environment?["LC_ALL"] == "C" && environment?["LANG"] == "C", "Native child receives explicit environment values; this does not establish CLI output language")
            try expect(AppStrings.text("Unknown") == "\u{672A}\u{77E5}", "Command locale does not change the localized Chinese UI")
        }
        try await verifyCommandLocale()
        for path in [runtime.appendingPathComponent("AvansiaCore"), package.appendingPathComponent("AvansiaSetup")] {
            try FileManager.default.copyItem(at: helper, to: path)
        }
        try write(snapshot())
        let probeRunner = InstallationCommandFixture()
        let installation = UtilityModel(base: base, package: package, agentFile: agentFile, fixture: nil, runner: probeRunner)
        installation.reloadCache()
        await installation.refreshInstallation()
        try expect(installation.runtimeAvailable && installation.installationState == .notInstalled && installation.canInstall && !installation.canPrint && !installation.canUpdate,
                   "Retained runtime with no queue or loaded agent is not installed, permits Install, and blocks Print")
        try expect(!installation.installationDetails.contains("OtherFixture"), "Installation diagnostics do not retain unrelated printer output")
        try expect(installation.canReadDetails, "Retained runtime remains available for explicit diagnostics")
        try Data("Synthetic orphan configuration".utf8).write(to: agentFile)
        await installation.refreshInstallation()
        try expect(installation.installationState == .incomplete && !installation.canInstall && installation.canUninstall && !installation.canPrint,
                   "Orphan LaunchAgent configuration is incomplete and enables the existing uninstall recovery flow")
        try FileManager.default.removeItem(at: agentFile)
        await installation.refreshInstallation()
        await installation.printPDF(folder.appendingPathComponent("never-submitted.pdf"), copies: 1, sides: "one-sided", scaling: "none")
        var probeCalls = await probeRunner.history()
        try expect(probeCalls.filter { $0.1 == ["queue-info"] }.allSatisfy { $0.0 == package.appendingPathComponent("AvansiaSetup").path }, "Default installation probe resolves Setup from the model's injected package")
        try expect(!probeCalls.contains { $0.0 == "/usr/bin/lpstat" }, "Installation status never parses localized lpstat output")
        try expect(!probeCalls.contains { $0.0 == "/usr/bin/lp" }, "Removed queue is rejected before PDF submission")
        await installation.setupAction("install")
        try expect(installation.installationState == .installed && installation.canPrint && !installation.canInstall, "Successful setup refreshes verified installation state")
        let previousServer = getenv("CUPS_SERVER").map { String(cString: $0) }
        setenv("CUPS_SERVER", "remote-fixture.invalid:631", 1)
        await installation.printPDF(folder.appendingPathComponent("mock-only.pdf"), copies: 2, sides: "two-sided-long-edge", scaling: "fit")
        if let previousServer { setenv("CUPS_SERVER", previousServer, 1) } else { unsetenv("CUPS_SERVER") }
        let submissions = await probeRunner.history().filter { $0.0 == "/usr/bin/lp" }
        try expect(submissions.count == 1 && Array(submissions[0].1.prefix(4)) == ["-h", "/private/var/run/cupsd", "-d", "Evolis_Avansia"],
                   "PDF submission explicitly pins the local scheduler despite a hostile inherited CUPS_SERVER")
        await installation.setupAction("uninstall")
        try expect(installation.runtimeAvailable && installation.installationState == .notInstalled && installation.canInstall && !installation.canPrint,
                   "Successful uninstall refreshes the UI even when runtime files remain")
        let ownedQueue = CommandResult(status: 0, output: #"{"exists":true,"device_uri":"ipp://localhost:18631/ipp/print"}"#)
        let loadedService = CommandResult(status: 0, output: "Synthetic loaded service\n")
        let absentService = CommandResult(status: 113, output: "Could not find service \"local.avansia.ipp\" in domain for user gui: 501\n")
        for (queue, service) in [(ownedQueue, absentService), (CommandResult(status: 0, output: #"{"exists":false,"device_uri":null}"#), loadedService),
                                 (CommandResult(status: 0, output: #"{"exists":true,"device_uri":"ipp://elsewhere.invalid/ipp/print"}"#), loadedService),
                                 (CommandResult(status: 0, output: #"{"exists":true,"device_uri":null}"#), loadedService)] {
            await probeRunner.configure(queue: queue, service: service)
            await installation.refreshInstallation()
            try expect(installation.installationState == .incomplete && !installation.canPrint && installation.canUninstall, "Incomplete or foreign-endpoint installation never enables Print")
        }
        let malformedQueueResponses = ["", "not JSON", "{}", #"{"exists":1,"device_uri":null}"#,
                                       #"{"exists":"false","device_uri":null}"#, #"{"exists":false}"#,
                                       #"{"exists":true,"device_uri":42}"#,
                                       #"{"exists":false,"device_uri":"ipp://localhost:18631/ipp/print"}"#,
                                       "\u{7528}\u{4E8E}Evolis_Avansia\u{7684}\u{8BBE}\u{5907}\u{FF1A}ipp://localhost:18631/ipp/print"]
        for output in malformedQueueResponses {
            await probeRunner.configure(queue: CommandResult(status: 0, output: output), service: loadedService)
            let beforeMalformed = await probeRunner.history().count
            await installation.refreshInstallation()
            let afterMalformed = await probeRunner.history().count
            try expect(installation.installationState == .unknown && !installation.canPrint && !installation.canInstall && afterMalformed == beforeMalformed + 1,
                       "Malformed or localized prose responses fail closed before service inspection")
        }
        await probeRunner.configure(queue: CommandResult(status: 1, output: #"{"exists":false,"device_uri":null}"#), service: absentService)
        await installation.refreshInstallation()
        try expect(installation.installationState == .unknown && !installation.canInstall && !installation.canPrint, "Nonzero queue-info status is an error even if stdout resembles clean absence")
        await probeRunner.configure(queue: ownedQueue, service: CommandResult(status: 113, output: "Could not find domain for user gui: 501\n"))
        await installation.refreshInstallation()
        try expect(installation.installationState == .unknown && !installation.canInstall && !installation.canPrint, "Query errors are not treated as clean absence")
        await probeRunner.timeoutNextProbe()
        await installation.refreshInstallation()
        try expect(installation.installationState == .unknown && !installation.installationDetails.contains("OtherFixture"), "Probe timeouts fail closed without retaining unrelated queue output")
        await probeRunner.configure(queue: ownedQueue, service: loadedService)
        let beforeProbe = await probeRunner.history().count
        let activeProbe = Task { await installation.refreshInstallation() }
        try await Task.sleep(nanoseconds: 10_000_000)
        try expect(installation.checkingInstallation && !installation.commandsAllowed, "Installation queries keep the UI responsive and prevent overlapping commands")
        await installation.refreshInstallation()
        await activeProbe.value
        probeCalls = await probeRunner.history()
        try expect(probeCalls.count == beforeProbe + 2, "Concurrent installation checks do not overlap")
        model.reloadCache()
        try expect(model.runtimeAvailable && model.snapshot?.ribbon?.percent == nil && model.snapshot?.ribbon?.percentText == AppStrings.text("Unknown"), "Unknown percentage never becomes zero")
        try expect(model.snapshot?.film?.percent == 0 && model.snapshot?.film?.percentText == "0%", "Actual zero remains zero")
        try expect(model.snapshot?.accessories?.first?.displayStatus == AppStrings.text("Unknown"), "Unknown accessory is not reported connected")
        try expect(!model.stale && model.canReadDetails, "Fresh ready cache permits explicit refresh")
        try write(snapshot(observed: "2000-01-01T00:00:00Z")); model.reloadCache()
        try expect(model.stale && !model.canChangeSettings, "Old observation is stale even if writer stale flag is false")
        try write(snapshot(connection: "disconnected", stale: true)); model.reloadCache()
        try expect(model.snapshot?.connection == "disconnected" && model.stale, "Disconnected observation remains explicit")
        try write(snapshot(connection: "recovery", recovery: true)); model.reloadCache()
        try expect(!model.canReadDetails && !model.canAcknowledge, "Recovery prevents reads and requires physical inspection")
        model.inspected = true
        try expect(model.canAcknowledge, "Explicit inspection permits acknowledgement only with no active job")
        try write(snapshot(connection: "recovery", recovery: true, active: true)); model.reloadCache()
        try expect(!model.canAcknowledge, "Active job blocks acknowledgement")
        try write(snapshot()); model.reloadCache()
        let poll = Task { await model.pollCache() }
        try await Task.sleep(nanoseconds: 1_700_000_000)
        poll.cancel()
        try expect(!FileManager.default.fileExists(atPath: runtime.appendingPathComponent("commands.log").path), "Cache polling never launches Core")
        await model.refreshSettings()
        try expect(model.settings?.settings.count == 1 && model.canChangeSettings, "Explicit settings load produces typed entries")
        let settingsResponse = runtime.appendingPathComponent("settings-response.json")
        func writeSettings(serial: String?, stale: Bool, error: String? = nil) throws {
            var response: [String: Any] = ["schema_version": 1, "stale": stale, "device_serial": serial.map { $0 as Any } ?? NSNull(),
                                           "settings": [["id": "image.sharpness", "label": "Sharpness", "group": "Image Setup", "type": "scalar", "current": 0, "minimum": -2, "maximum": 2, "choices": [], "writable": true]], "information": []]
            response["error"] = error
            try JSONSerialization.data(withJSONObject: response).write(to: settingsResponse)
        }
        try writeSettings(serial: "SYNTHETIC-A", stale: true, error: "Synthetic disconnected settings error")
        await model.refreshSettings()
        try expect(model.actionError != nil && model.actionDetails == "Synthetic disconnected settings error" && model.settings?.settings.count == 1 && model.settingsNeedRefresh && !model.canChangeSettings,
                   "Successful stale settings JSON displays its error and leaves cached settings read-only")
        try FileManager.default.removeItem(at: settingsResponse)
        await model.refreshSettings()
        let observedSetting = model.settings!.settings[0]
        try write(snapshot(serial: "SYNTHETIC-B")); model.reloadCache()
        let beforeIdentityChange = try String(contentsOf: runtime.appendingPathComponent("commands.log"), encoding: .utf8)
        await model.apply(observedSetting, value: 1)
        let afterIdentityChange = try String(contentsOf: runtime.appendingPathComponent("commands.log"), encoding: .utf8)
        try expect(model.settings?.device_serial == "SYNTHETIC-A" && model.settingsNeedRefresh && !model.canChangeSettings && beforeIdentityChange == afterIdentityChange,
                   "Printer B cannot apply settings observed on printer A")
        try write(snapshot()); model.reloadCache()
        try expect(!model.canChangeSettings, "Returning to printer A does not bypass the required explicit settings refresh")
        try writeSettings(serial: nil, stale: false)
        await model.refreshSettings()
        try expect(!model.canChangeSettings && model.settingsNeedRefresh, "Settings without a device identity remain read-only")
        try FileManager.default.removeItem(at: settingsResponse)
        await model.refreshSettings()
        await model.apply(model.settings!.settings[0], value: 1)
        try expect(model.actionError == AppStrings.text("The setting result is uncertain. Read settings again before another change.") && model.actionDetails?.contains("uncertain") == true && model.settingsNeedRefresh && !model.canChangeSettings, "Failed setting has localized context and preserves technical details and explicit-refresh safety")
        let commandLog = try String(contentsOf: runtime.appendingPathComponent("commands.log"), encoding: .utf8)
        try expect(commandLog.contains("set-setting image.sharpness 0 1 --device-serial SYNTHETIC-A"), "Setting write includes logical ID, expected old value, and observed device identity")
        await model.apply(model.settings!.settings[0], value: 1)
        let unchangedLog = try String(contentsOf: runtime.appendingPathComponent("commands.log"), encoding: .utf8)
        try expect(commandLog == unchangedLog, "Uncertain write cannot auto retry")
        let running = Task { await model.setupAction("status") }
        try await Task.sleep(nanoseconds: 50_000_000)
        try expect(model.operation != nil, "Command execution does not block the UI actor")
        await model.setupAction("upgrade")
        await running.value
        try expect(model.operation == nil && model.actionError == AppStrings.text("The operation did not complete. Read the details and refresh before trying again.") && model.actionDetails?.contains("Simulated command failure") == true, "Process failure clears busy state, localizes context, and preserves diagnostic details")
        let setupLog = try String(contentsOf: package.appendingPathComponent("commands.log"), encoding: .utf8)
        try expect(setupLog == "status\n", "A running command prevents overlapping helpers")
        try write(snapshot(connection: "recovery", recovery: true)); model.reloadCache()
        model.inspected = true
        await model.acknowledge()
        try expect(model.actionError == AppStrings.text("The recovery record was not cleared. Confirm physical inspection and resolve queued jobs before trying again.") && model.inspected && model.snapshot?.recoveryRequired == true, "Recovery failure gives localized next steps without clearing inspection or uncertainty state")
        let fixture = folder.appendingPathComponent("fixture.json")
        try write(["runtime_available": true, "snapshot": snapshot()], to: fixture)
        let preview = UtilityModel(base: folder.appendingPathComponent("absent"), package: package, agentFile: agentFile, fixture: fixture,
                                   runner: probeRunner, installationProbe: AppInstallationProbe(setup: package.appendingPathComponent("AvansiaSetup"), agentFile: agentFile, runner: probeRunner))
        preview.reloadCache(); preview.reloadCache()
        try expect(preview.runtimeAvailable && !preview.commandsAllowed, "Fixture mode remains stable and forbids live commands")
        let beforeFixtureProbe = await probeRunner.history().count
        await preview.refreshDetails(); await preview.setupAction("install"); await preview.refreshInstallation()
        let afterFixtureProbe = await probeRunner.history().count
        try expect(beforeFixtureProbe == afterFixtureProbe, "Fixture mode never probes the system installation")
        try expect(preview.operation == nil, "Fixture controls never launch hardware or installation")
        do {
            _ = try await NativeCommandRunner().run(helper, ["sleep"], timeout: 0.1)
            throw AppFailure.message("Test failed: timeout was accepted")
        } catch { try expect(error.localizedDescription.contains("timed out"), "Command timeout is reported") }
        print("PASS: stale settings error visibility, device-bound settings invalidation and apply arguments, orphan-agent recovery, explicit local print scheduler, structured queue information, retained-runtime separation, malformed/error print gates, nonoverlapping probes, zh-Hans UI, fixture isolation and command safety")
    }
}
