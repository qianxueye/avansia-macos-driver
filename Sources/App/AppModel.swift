import Foundation
import Combine
import Darwin

enum AppFailure: LocalizedError {
    case message(String)
    case timedOut(String)
    var errorDescription: String? {
        switch self {
        case .message(let text): return text
        case .timedOut(let details): return "The command timed out. Its outcome may be unknown; refresh before trying again.\n" + details
        }
    }
}
indirect enum JSONValue: Decodable, Equatable {
    case string(String), number(Double), bool(Bool), object([String: JSONValue]), array([JSONValue]), null
    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode(Double.self) { self = .number(item) }
        else if let item = try? value.decode([String: JSONValue].self) { self = .object(item) }
        else { self = .array(try value.decode([JSONValue].self)) }
    }
    var text: String {
        switch self {
        case .string(let value): return AppStrings.text(value)
        case .number(let value): return value.formatted(.number.locale(AppStrings.locale))
        case .bool(let value): return AppStrings.text(value ? "Yes" : "No")
        case .null: return AppStrings.text("Unknown")
        case .array(let items): return items.map(\.text).joined(separator: ", ")
        case .object: return AppStrings.text("Available")
        }
    }
    var isPresent: Bool {
        switch self { case .null, .bool(false): return false; case .array(let values): return !values.isEmpty; default: return true }
    }
}
struct SupplyStatus: Decodable {
    var remaining_percent: Int?
    var reference: String?
    var label: String?
    var region: String?
    var identity_observed_at: String?
    var type: String?
    var percent: Int? { remaining_percent.flatMap { (0...100).contains($0) ? $0 : nil } }
    var percentText: String { percent.map { (Double($0) / 100).formatted(.percent.precision(.fractionLength(0)).locale(AppStrings.locale)) } ?? AppStrings.text("Unknown") }
}
struct AccessoryStatus: Decodable, Identifiable {
    let id: String
    let name: String
    let status: String
    var displayStatus: String { AppStrings.text(["connected", "disconnected"].contains(status) ? status.capitalized : "Unknown") }
    var displayName: String { AppStrings.text(name) }
}
struct QueueStatus: Decodable {
    var active_job: JSONValue?
    var recovery_required: Bool?
    var active: Bool { active_job?.isPresent == true }
}
struct PrinterSnapshot: Decodable {
    let schema_version: Int
    let updated_at: String?
    let observed_at: String?
    let connection: String
    let stale: Bool
    let device: [String: JSONValue]?
    let ribbon: SupplyStatus?
    let film: SupplyStatus?
    let accessories: [AccessoryStatus]?
    let queue: QueueStatus?
    let error: String?
    var recoveryRequired: Bool { connection == "recovery" || queue?.recovery_required == true }
    var busy: Bool { connection == "busy" || queue?.active == true }
    var connectionText: String { AppStrings.connection(connection) }
    func isStale(at now: Date = Date()) -> Bool {
        guard !stale, let text = observed_at, let observed = Self.date(text) else { return true }
        let age = now.timeIntervalSince(observed)
        return age > 60 || age < -60
    }
    static func date(_ text: String) -> Date? {
        let format = ISO8601DateFormatter()
        if let date = format.date(from: text) { return date }
        format.formatOptions.insert(.withFractionalSeconds)
        return format.date(from: text)
    }
}
struct SettingChoice: Decodable, Identifiable {
    let value: Int
    let label: String
    var id: Int { value }
}
struct PrinterSetting: Decodable, Identifiable {
    let id: String
    let label: String
    let group: String
    let type: String
    let current: Int?
    let minimum: Int?
    let maximum: Int?
    let choices: [SettingChoice]?
    let writable: Bool
    var displayLabel: String { AppStrings.text(label) }
    var acceptsInput: Bool { writable && current != nil && ((type == "choice" && choices?.isEmpty == false) || (type == "scalar" && minimum != nil && maximum != nil)) }
    func accepts(_ value: Int) -> Bool {
        if let choices, !choices.isEmpty { return choices.contains { $0.value == value } }
        guard let minimum, let maximum else { return false }
        return minimum <= value && value <= maximum
    }
}
struct PrinterInformation: Decodable, Identifiable {
    let label: String
    let value: JSONValue
    var id: String { label }
}
struct SettingsSnapshot: Decodable {
    let schema_version: Int
    let stale: Bool
    let settings: [PrinterSetting]
    let information: [PrinterInformation]?
}
struct CommandResult: Sendable {
    let status: Int32
    let output: String
}
protocol AppCommandRunning {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval,
             progress: @escaping @Sendable (String) -> Void) async throws -> CommandResult
}
struct NativeCommandRunner: AppCommandRunning {
    func run(_ executable: URL, _ arguments: [String], timeout: TimeInterval = 60,
             progress: @escaping @Sendable (String) -> Void = { _ in }) async throws -> CommandResult {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AvansiaUtility-" + UUID().uuidString)
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                    defer { try? FileManager.default.removeItem(at: folder) }
                    let outputURL = folder.appendingPathComponent("output")
                    FileManager.default.createFile(atPath: outputURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
                    let output = try FileHandle(forWritingTo: outputURL)
                    defer { try? output.close() }
                    let process = Process()
                    process.executableURL = executable
                    process.arguments = arguments
                    var environment = ProcessInfo.processInfo.environment
                    environment["LC_ALL"] = "C"
                    environment["LANG"] = "C"
                    process.environment = environment
                    process.standardOutput = output
                    process.standardError = output
                    process.standardInput = FileHandle.nullDevice
                    try process.run()
                    let started = ProcessInfo.processInfo.systemUptime
                    var last = ""
                    func readOutput() -> String {
                        guard let reader = try? FileHandle(forReadingFrom: outputURL) else { return "" }
                        defer { try? reader.close() }
                        let size = (try? reader.seekToEnd()) ?? 0
                        try? reader.seek(toOffset: size > 1_048_576 ? size - 1_048_576 : 0)
                        return String(decoding: (try? reader.readToEnd()) ?? Data(), as: UTF8.self)
                    }
                    while process.isRunning {
                        let current = readOutput()
                        if current != last { last = current; progress(current) }
                        if ProcessInfo.processInfo.systemUptime - started > timeout {
                            process.terminate()
                            let grace = ProcessInfo.processInfo.systemUptime + 2
                            while process.isRunning && ProcessInfo.processInfo.systemUptime < grace { Thread.sleep(forTimeInterval: 0.05) }
                            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                            process.waitUntilExit()
                            throw AppFailure.timedOut(readOutput())
                        }
                        Thread.sleep(forTimeInterval: 0.15)
                    }
                    process.waitUntilExit()
                    let final = readOutput()
                    progress(final)
                    continuation.resume(returning: CommandResult(status: process.terminationStatus, output: final))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}
@MainActor final class UtilityModel: ObservableObject {
    @Published var snapshot: PrinterSnapshot?
    @Published var settings: SettingsSnapshot?
    @Published var runtimeAvailable = false
    @Published var installationState: AppInstallationState = .unknown
    @Published var installationDetails = ""
    @Published var checkingInstallation = false
    @Published var cacheError: String?
    @Published var cacheDetails: String?
    @Published var operation: String?
    @Published var output = ""
    @Published var actionError: String?
    @Published var actionDetails: String?
    @Published var notice: String?
    @Published var settingsNeedRefresh = true
    @Published var inspected = false
    @Published var stoppedJobID = ""
    let base: URL
    let package: URL
    let fixture: URL?
    private let runner: any AppCommandRunning
    private let installationProbe: AppInstallationProbe
    private var commandID: UUID?
    var runtime: URL { base.appendingPathComponent("runtime") }
    var core: URL { runtime.appendingPathComponent("AvansiaCore") }
    var setup: URL { package.appendingPathComponent("AvansiaSetup") }
    var imageURL: URL { runtime.appendingPathComponent("Assets/Avansia.png") }
    var commandsAllowed: Bool { fixture == nil && operation == nil && !checkingInstallation }
    var canInstall: Bool { commandsAllowed && installationState == .notInstalled }
    var canUpdate: Bool { commandsAllowed && runtimeAvailable && [.installed, .incomplete].contains(installationState) }
    var canUninstall: Bool { commandsAllowed && [.installed, .incomplete].contains(installationState) }
    var canPrint: Bool { commandsAllowed && runtimeAvailable && installationState == .installed && snapshot?.recoveryRequired != true }
    var stale: Bool { cacheError != nil || snapshot?.isStale() != false }
    var canReadDetails: Bool { commandsAllowed && runtimeAvailable && snapshot?.busy != true && snapshot?.recoveryRequired != true }
    var canChangeSettings: Bool { canReadDetails && snapshot?.connection == "ready" && !stale && !settingsNeedRefresh }
    var canAcknowledge: Bool { commandsAllowed && runtimeAvailable && inspected && snapshot?.recoveryRequired == true && snapshot?.queue?.active_job == .bool(false) }
    init(base: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AvansiaDriver"),
         package: URL = (Bundle.main.resourceURL ?? Bundle.main.bundleURL).appendingPathComponent("Driver"),
         fixture: URL? = ProcessInfo.processInfo.environment["AVANSIA_UI_FIXTURE"].map { URL(fileURLWithPath: $0) },
         runner: any AppCommandRunning = NativeCommandRunner(), installationProbe: AppInstallationProbe = AppInstallationProbe()) {
        self.base = base; self.package = package; self.fixture = fixture; self.runner = runner; self.installationProbe = installationProbe
    }
    func reloadCache() {
        runtimeAvailable = FileManager.default.isExecutableFile(atPath: core.path)
        let path = fixture ?? base.appendingPathComponent("state/status.json")
        do {
            let data = try Data(contentsOf: path)
            let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            if fixture != nil {
                runtimeAvailable = object?["runtime_available"] as? Bool ?? true
                installationState = (object?["installation_state"] as? String).flatMap(AppInstallationState.init(rawValue:)) ?? .unknown
            }
            let snapshotData = try object?["snapshot"].map { try JSONSerialization.data(withJSONObject: $0) } ?? data
            let decoded = try JSONDecoder().decode(PrinterSnapshot.self, from: snapshotData)
            guard decoded.schema_version == 1 else { throw AppFailure.message("Unsupported status format") }
            snapshot = decoded
            if fixture != nil, let fixtureSettings = object?["settings"] {
                settings = try JSONDecoder().decode(SettingsSnapshot.self, from: JSONSerialization.data(withJSONObject: fixtureSettings))
                settingsNeedRefresh = settings?.stale != false
            }
            cacheError = nil; cacheDetails = nil
        } catch {
            cacheError = AppStrings.text(runtimeAvailable ? "Status is unavailable. Use Refresh to request a new observation." : "The driver is not installed. Install it to start monitoring.")
            cacheDetails = error.localizedDescription
        }
    }
    func pollCache() async {
        while !Task.isCancelled {
            reloadCache()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
        }
    }
    func refreshInstallation() async {
        guard commandsAllowed else { return }
        checkingInstallation = true
        defer { checkingInstallation = false }
        let result = await installationProbe.inspect()
        runtimeAvailable = FileManager.default.isExecutableFile(atPath: core.path)
        installationState = result.state == .installed && !runtimeAvailable ? .incomplete : result.state
        installationDetails = result.details
    }
    func pollInstallation() async {
        while !Task.isCancelled {
            await refreshInstallation()
            try? await Task.sleep(nanoseconds: 15_000_000_000)
        }
    }
    @discardableResult private func perform(_ title: String, executable: URL, arguments: [String], timeout: TimeInterval = 60) async -> String? {
        guard commandsAllowed else { return nil }
        let id = UUID()
        commandID = id
        operation = title; actionError = nil; actionDetails = nil; notice = nil; output = ""
        defer { commandID = nil; operation = nil; reloadCache() }
        do {
            let result = try await runner.run(executable, arguments, timeout: timeout) { [weak self] text in
                Task { @MainActor in if self?.commandID == id { self?.output = text } }
            }
            output = result.output
            guard result.status == 0 else { throw AppFailure.message(result.output.isEmpty ? "Command failed (exit \(result.status))." : result.output) }
            return result.output
        } catch {
            actionDetails = error.localizedDescription
            if case AppFailure.timedOut = error {
                actionError = AppStrings.text("The operation timed out. Its result may be unknown; refresh before trying again.")
            } else if arguments.first == "set-setting" {
                actionError = AppStrings.text("The setting result is uncertain. Read settings again before another change.")
            } else if arguments.first == "acknowledge" {
                actionError = AppStrings.text("The recovery record was not cleared. Confirm physical inspection and resolve queued jobs before trying again.")
            } else if arguments.first == "cancel-stopped" {
                actionError = AppStrings.text("The stopped job was not canceled. Check the job number and resolve local jobs in Print Center first.")
            } else {
                actionError = AppStrings.text("The operation did not complete. Read the details and refresh before trying again.")
            }
            return nil
        }
    }
    func refreshDetails() async {
        guard canReadDetails else { return }
        _ = await perform(AppStrings.text("Refreshing printer details"), executable: core, arguments: ["snapshot", "--refresh-details"])
    }
    func refreshSettings() async {
        guard canReadDetails else { return }
        settingsNeedRefresh = true
        guard let text = await perform(AppStrings.text("Reading printer settings"), executable: core, arguments: ["settings"]) else { return }
        do {
            let result = try JSONDecoder().decode(SettingsSnapshot.self, from: Data(text.utf8))
            guard result.schema_version == 1 else { throw AppFailure.message("Unsupported settings format") }
            settings = result; settingsNeedRefresh = result.stale
        } catch {
            actionError = AppStrings.text("The settings response could not be read. Refresh settings before making changes.")
            actionDetails = error.localizedDescription
        }
    }
    func apply(_ setting: PrinterSetting, value: Int) async {
        guard canChangeSettings, setting.acceptsInput, setting.accepts(value), let expected = setting.current, value != expected else { return }
        settingsNeedRefresh = true
        guard await perform(AppStrings.format("Applying %@", setting.displayLabel), executable: core, arguments: ["set-setting", setting.id, String(expected), String(value)]) != nil else { return }
        await refreshSettings()
    }
    func setupAction(_ command: String) async {
        guard ["install", "upgrade", "uninstall", "status"].contains(command), commandsAllowed else { return }
        guard command != "install" || canInstall, command != "upgrade" || canUpdate, command != "uninstall" || canUninstall else { return }
        let arguments = [command] + (["install", "upgrade"].contains(command) ? [package.path] : [])
        let titles = ["install": "Installing driver", "upgrade": "Updating driver", "uninstall": "Uninstalling driver", "status": "Checking installation"]
        _ = await perform(AppStrings.text(titles[command]!), executable: setup, arguments: arguments, timeout: 900)
        if command != "status" { await refreshInstallation() }
    }
    func importSDK(_ url: URL) async {
        guard commandsAllowed else { return }
        _ = await perform(AppStrings.text("Importing official SDK"), executable: setup, arguments: ["import-sdk", url.path], timeout: 900)
    }
    func acknowledge() async {
        guard canAcknowledge else { return }
        if await perform(AppStrings.text("Acknowledging inspected card"), executable: setup, arguments: ["acknowledge", "--confirm-card-inspected"]) != nil { inspected = false }
    }
    func cancelStopped() async {
        guard commandsAllowed, runtimeAvailable, let id = Int(stoppedJobID), id > 0 else { return }
        _ = await perform(AppStrings.text("Canceling stopped remote job"), executable: setup, arguments: ["cancel-stopped", String(id)])
    }
    func printPDF(_ url: URL, copies: Int, sides: String, scaling: String) async {
        guard commandsAllowed, runtimeAvailable, snapshot?.recoveryRequired != true, (1...100).contains(copies),
              ["one-sided", "two-sided-long-edge", "two-sided-short-edge"].contains(sides), ["none", "fit", "fill"].contains(scaling) else { return }
        await refreshInstallation()
        guard canPrint else {
            actionError = AppStrings.text("Printing requires a verified installation with no recovery pending.")
            actionDetails = installationDetails
            return
        }
        if await perform(AppStrings.text("Submitting PDF to the print queue"), executable: URL(fileURLWithPath: "/usr/bin/lp"), arguments: ["-d", "Evolis_Avansia", "-n", String(copies), "-o", "sides=" + sides, "-o", "print-scaling=" + scaling, "-o", "media=iso_id-1_53.98x85.6mm", url.path]) != nil {
            notice = AppStrings.text("The PDF was submitted to the queue. Check Print Center for job status.")
        }
    }
}
