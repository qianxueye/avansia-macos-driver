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
            var configuration = try String(contentsOf: runtimeRoot.appendingPathComponent("avansia.conf"), encoding: .utf8)
            configuration += "\nATTR integer marker-levels -1,-1\n"
            let configURL = driverBase.appendingPathComponent("printer.conf")
            try configuration.write(to: configURL, atomically: true, encoding: .utf8)
            setenv("AVANSIA_IPP_PORT", "18631", 1)
            var arguments = [runtimeRoot.appendingPathComponent("bin/ippeveprinter").path, "-n", "localhost", "-p", "18631", "-r", "off", "--no-web-forms", "--status-command", runtimeRoot.appendingPathComponent("AvansiaCore").path, "-a", configURL.path, "-f", "application/pdf", "-c", runtimeRoot.appendingPathComponent("AvansiaJob").path, "-D", "/dev/null", "-d", driverBase.appendingPathComponent("spool").path]
            let icons = [48, 128, 512].map { runtimeRoot.appendingPathComponent("Assets/Avansia-\($0).png").path }
            if icons.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) {
                arguments += ["-i", icons.joined(separator: ",")]
            }
            arguments.append("Evolis Avansia")
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
