import Foundation
import Darwin

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw AppFailure.message("Test failed: " + message) }
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
        for path in [state, runtime, package] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true) }
        let timestamp = ISO8601DateFormatter().string(from: Date())
        func snapshot(connection: String = "ready", stale: Bool = false, observed: Any? = nil, recovery: Bool = false, active: Bool = false) -> [String: Any] {
            ["schema_version": 1, "updated_at": timestamp, "observed_at": observed ?? timestamp,
             "connection": connection, "stale": stale, "device": ["model": "Synthetic printer"],
             "ribbon": ["remaining_percent": NSNull()], "film": ["remaining_percent": 0],
             "accessories": [["id": "test", "name": "Synthetic accessory", "status": "unknown"]],
             "queue": ["active_job": active, "recovery_required": recovery]]
        }
        func write(_ object: [String: Any], to path: URL = state.appendingPathComponent("status.json")) throws {
            try JSONSerialization.data(withJSONObject: object).write(to: path, options: .atomic)
        }
        let model = UtilityModel(base: base, package: package, fixture: nil)
        model.reloadCache()
        try expect(!model.runtimeAvailable && model.cacheError != nil && !model.canReadDetails, "Missing runtime is visible and blocks native commands")
        let helper = URL(fileURLWithPath: CommandLine.arguments[1])
        for path in [runtime.appendingPathComponent("AvansiaCore"), package.appendingPathComponent("AvansiaSetup")] {
            try FileManager.default.copyItem(at: helper, to: path)
        }
        try write(snapshot())
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
        await model.apply(model.settings!.settings[0], value: 1)
        try expect(model.actionError == AppStrings.text("The setting result is uncertain. Read settings again before another change.") && model.actionDetails?.contains("uncertain") == true && model.settingsNeedRefresh && !model.canChangeSettings, "Failed setting has localized context and preserves technical details and explicit-refresh safety")
        let commandLog = try String(contentsOf: runtime.appendingPathComponent("commands.log"), encoding: .utf8)
        try expect(commandLog.contains("set-setting image.sharpness 0 1"), "Setting write includes logical ID and expected old value")
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
        let preview = UtilityModel(base: folder.appendingPathComponent("absent"), package: package, fixture: fixture)
        preview.reloadCache(); preview.reloadCache()
        try expect(preview.runtimeAvailable && !preview.commandsAllowed, "Fixture mode remains stable and forbids live commands")
        await preview.refreshDetails(); await preview.setupAction("install")
        try expect(preview.operation == nil, "Fixture controls never launch hardware or installation")
        do {
            _ = try await NativeCommandRunner().run(helper, ["sleep"], timeout: 0.1)
            throw AppFailure.message("Test failed: timeout was accepted")
        } catch { try expect(error.localizedDescription.contains("timed out"), "Command timeout is reported") }
        print("PASS: packaged zh-Hans resources and interpolation, localized status/settings/recovery/errors, preserved technical diagnostics, app cache polling, unknown/zero supplies, stale/disconnected/missing runtime, recovery gates, expected-value writes, retry block, responsive/nonoverlapping failure/timeout, and fixture isolation")
    }
}
