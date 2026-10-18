import Foundation
import Darwin

@main struct AvansiaService {
    static func main() {
        umask(0o077)
        do {
            for name in ["spool", "state"] {
                let folder = driverBase.appendingPathComponent(name)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            }
            var levels = (-1, -1)
            if !FileManager.default.fileExists(atPath: driverBase.appendingPathComponent("spool/active-job.ipp").path)
                && !FileManager.default.fileExists(atPath: driverBase.appendingPathComponent("state/inflight.json").path) {
                if let status = try? runNative(runtimeRoot.appendingPathComponent("AvansiaCore"), ["ribbon"], timeout: 45) { levels = markerLevels(status) }
            }
            var configuration = try String(contentsOf: runtimeRoot.appendingPathComponent("avansia.conf"), encoding: .utf8)
            configuration += "\nATTR integer marker-levels \(levels.0),\(levels.1)\n"
            let configURL = driverBase.appendingPathComponent("printer.conf")
            try configuration.write(to: configURL, atomically: true, encoding: .utf8)
            setenv("AVANSIA_IPP_PORT", "18631", 1)
            let arguments = [runtimeRoot.appendingPathComponent("bin/ippeveprinter").path, "-n", "localhost", "-p", "18631", "-r", "off", "--no-web-forms", "-a", configURL.path, "-f", "application/pdf", "-c", runtimeRoot.appendingPathComponent("AvansiaJob").path, "-D", "/dev/null", "-d", driverBase.appendingPathComponent("spool").path, "Evolis Avansia"]
            let pointers = arguments.map { strdup($0) } + [nil]
            defer { pointers.forEach { free($0) } }
            pointers.withUnsafeBufferPointer { _ = execv(arguments[0], $0.baseAddress!) }
            throw driverError("Cannot start private IPP service: \(String(cString: strerror(errno)))")
        } catch {
            log("ERROR: " + error.localizedDescription.replacingOccurrences(of: "\n", with: " "))
            exit(1)
        }
    }
}
