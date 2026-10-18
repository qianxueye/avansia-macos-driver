import Foundation
import Darwin

let root = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
let log = root.appendingPathComponent("commands.log")
let line = Data((CommandLine.arguments.dropFirst().joined(separator: " ") + "\n").utf8)
if FileManager.default.fileExists(atPath: log.path), let file = try? FileHandle(forWritingTo: log) {
    try file.seekToEnd(); try file.write(contentsOf: line); try file.close()
} else { try line.write(to: log) }
switch CommandLine.arguments.dropFirst().first {
case "locale":
    let environment = ProcessInfo.processInfo.environment
    let result = ["LC_ALL": environment["LC_ALL"] ?? "", "LANG": environment["LANG"] ?? ""]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: result))
case "settings":
    let response = root.appendingPathComponent("settings-response.json")
    if FileManager.default.fileExists(atPath: response.path) {
        FileHandle.standardOutput.write(try Data(contentsOf: response))
        exit(0)
    }
    print("""
    {"schema_version":1,"stale":false,"device_serial":"SYNTHETIC-A","settings":[{"id":"image.sharpness","label":"Sharpness","group":"Image Setup","type":"scalar","current":0,"minimum":-2,"maximum":2,"choices":[],"writable":true}],"information":[]}
    """)
case "set-setting":
    FileHandle.standardError.write(Data("Simulated uncertain setting outcome; refresh required.\n".utf8)); exit(7)
case "sleep": sleep(10)
default:
    usleep(400_000)
    FileHandle.standardError.write(Data("Simulated command failure.\n".utf8)); exit(7)
}
