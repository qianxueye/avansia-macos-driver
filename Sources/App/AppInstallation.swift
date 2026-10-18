import Foundation
import Darwin

enum AppInstallationState: String {
    case unknown, notInstalled, installed, incomplete
    var title: String {
        switch self {
        case .unknown: return AppStrings.text("Installation not verified")
        case .notInstalled: return AppStrings.text("Driver not installed")
        case .installed: return AppStrings.text("Driver installed")
        case .incomplete: return AppStrings.text("Installation needs attention")
        }
    }
    var explanation: String {
        switch self {
        case .unknown: return AppStrings.text("Check installation to verify the print queue and user service.")
        case .notInstalled: return AppStrings.text("The print queue and user service are absent. Retained runtime files do not mean the driver is installed.")
        case .installed: return AppStrings.text("The driver is installed for this user.")
        case .incomplete: return AppStrings.text("The queue, user service, or runtime is incomplete. Check the details before updating or uninstalling.")
        }
    }
}
struct AppInstallationResult {
    let state: AppInstallationState
    let details: String
}
struct AppInstallationProbe {
    private struct QueueInformation: Decodable {
        let exists: Bool
        let device_uri: String?
        enum CodingKeys: String, CodingKey { case exists, device_uri }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            exists = try values.decode(Bool.self, forKey: .exists)
            if try values.decodeNil(forKey: .device_uri) { device_uri = nil }
            else { device_uri = try values.decode(String.self, forKey: .device_uri) }
            guard exists || device_uri == nil else { throw AppFailure.message("Queue information contradicts its absence flag") }
        }
    }
    private let setup: URL
    private let runner: any AppCommandRunning
    init(setup: URL, runner: any AppCommandRunning = NativeCommandRunner()) { self.setup = setup; self.runner = runner }
    func inspect() async -> AppInstallationResult {
        let endpoint = "ipp://localhost:18631/ipp/print"
        let service = "local.avansia.ipp"
        do {
            let queueResult = try await runner.run(setup, ["queue-info"], timeout: 4, progress: { _ in })
            guard queueResult.status == 0 else {
                return AppInstallationResult(state: .unknown, details: "Queue inspection failed (Setup exit \(queueResult.status)).")
            }
            let queue = try JSONDecoder().decode(QueueInformation.self, from: Data(queueResult.output.utf8))
            let serviceResult = try await runner.run(URL(fileURLWithPath: "/bin/launchctl"), ["print", "gui/\(getuid())/" + service], timeout: 4, progress: { _ in })
            let servicePresent: Bool
            if serviceResult.status == 0 { servicePresent = true }
            else if serviceResult.status == 113 && serviceResult.output.contains("Could not find service \"" + service + "\"") { servicePresent = false }
            else {
                return AppInstallationResult(state: .unknown, details: "Service inspection failed (launchctl exit \(serviceResult.status)).")
            }
            let queueOwned = queue.exists && queue.device_uri == endpoint
            let state: AppInstallationState = queueOwned && servicePresent ? .installed
                : !queue.exists && !servicePresent ? .notInstalled : .incomplete
            let details = "Queue Evolis_Avansia: " + (queue.exists ? queue.device_uri ?? "present; endpoint unavailable" : "absent")
                + "\nUser service local.avansia.ipp: " + (servicePresent ? "loaded" : "absent")
            return AppInstallationResult(state: state, details: details)
        } catch {
            if case AppFailure.timedOut = error {
                return AppInstallationResult(state: .unknown, details: "Installation inspection timed out; state is unverified.")
            }
            let failure = error as NSError
            return AppInstallationResult(state: .unknown, details: "Installation inspection could not complete (\(failure.domain), code \(failure.code)).")
        }
    }
}
