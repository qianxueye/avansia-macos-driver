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
    private let runner: any AppCommandRunning
    init(runner: any AppCommandRunning = NativeCommandRunner()) { self.runner = runner }
    func inspect() async -> AppInstallationResult {
        let name = "Evolis_Avansia"
        let endpoint = "ipp://localhost:18631/ipp/print"
        let service = "local.avansia.ipp"
        do {
            let queueResult = try await runner.run(URL(fileURLWithPath: "/usr/bin/lpstat"), ["-v"], timeout: 4, progress: { _ in })
            guard queueResult.status == 0 else {
                return AppInstallationResult(state: .unknown, details: "Queue inspection failed (lpstat exit \(queueResult.status)).")
            }
            let queueEndpoint = queueResult.output.split(separator: "\n").compactMap { line -> String? in
                guard let separator = line.firstIndex(of: ":"),
                      line[..<separator].split(whereSeparator: { $0.isWhitespace }).last == Substring(name) else { return nil }
                return String(line[line.index(after: separator)...]).trimmingCharacters(in: .whitespaces)
            }.first
            let serviceResult = try await runner.run(URL(fileURLWithPath: "/bin/launchctl"), ["print", "gui/\(getuid())/" + service], timeout: 4, progress: { _ in })
            let servicePresent: Bool
            if serviceResult.status == 0 { servicePresent = true }
            else if serviceResult.status == 113 && serviceResult.output.contains("Could not find service \"" + service + "\"") { servicePresent = false }
            else {
                return AppInstallationResult(state: .unknown, details: "Service inspection failed (launchctl exit \(serviceResult.status)).")
            }
            let queueOwned = queueEndpoint == endpoint
            let state: AppInstallationState = queueOwned && servicePresent ? .installed
                : queueEndpoint == nil && !servicePresent ? .notInstalled : .incomplete
            let details = "Queue Evolis_Avansia: " + (queueEndpoint ?? "absent")
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
