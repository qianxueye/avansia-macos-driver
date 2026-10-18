import Foundation

let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let root = executable.deletingLastPathComponent().appendingPathComponent("captures", isDirectory: true)
let environment = ProcessInfo.processInfo.environment
let name = environment["IPP_JOB_NAME", default: ""]
guard CommandLine.arguments.count == 2, name.hasPrefix("RasterGate-"),
      environment["IPP_JOB_URI", default: ""].hasPrefix("ipp://localhost:18649/ipp/print/"),
      environment["CONTENT_TYPE"] == "application/pdf", let identifier = environment["IPP_JOB_ID"],
      identifier.allSatisfy({ $0.isNumber }) else {
    FileHandle.standardError.write(Data("Refusing invocation outside the isolated raster gate\n".utf8))
    exit(1)
}
do {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]),
                                     to: root.appendingPathComponent(identifier + ".pdf"))
    let captured = environment.filter { $0.key.hasPrefix("IPP_") || $0.key == "CONTENT_TYPE" }
    try JSONSerialization.data(withJSONObject: captured, options: [.sortedKeys]).write(
        to: root.appendingPathComponent(identifier + ".json"), options: .atomic)
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
