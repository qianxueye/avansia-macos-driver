import Foundation
import CryptoKit

struct RuntimeAssetError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

enum RuntimeAssets {
#if ASSET_TESTS
    static var testLibraryDigest: String?
    static var testAfterLibraryCopy: ((URL) throws -> Void)?
#endif
    static let sdkURL = URL(string: "https://files.pythonhosted.org/packages/19/02/b4eca9226cdd1ca1b89f0d9c674e0856ab5d411f5ecf251f4c9c63d79bb0/evolis_sdk-9.4.1-py3-none-any.whl")!
    static let archiveDigest = "9228bac974dd19609bda2e923e0a9b12ff8fdfed06ea45f34c0eee8ca0999f0e"
    static let libraryDigest = "5c13d2a6dd3f34ea2fd65817e81820cec30f90a2aae6249046d89c8c7b2b99f9"
    static let libraryPath = "native/vendor/evolis/lib/macos/libevolis.dylib"
    static let imageURL = URL(string: "https://us.evolis.com/wp-content/uploads/2023/03/avansia-card-printer-evolis-940x0-c-default.png")!

    static func verify(_ file: URL, digest: String, maximum: Int) throws {
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= maximum else {
            throw RuntimeAssetError("The imported component is empty, oversized, or not a regular file")
        }
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard actual == digest else { throw RuntimeAssetError("The component does not match the supported official SDK 9.4.1 integrity pin") }
    }

    static func download(_ source: URL, to destination: URL, maximum: Int) throws {
        let semaphore = DispatchSemaphore(value: 0)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 180
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var failure: Error?
        let task = session.downloadTask(with: source) { temporary, response, error in
            do {
                if let error { throw error }
                guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                      response.url?.scheme == "https", let temporary else {
                    throw RuntimeAssetError("The original distribution server did not return a successful HTTPS download")
                }
                let values = try temporary.resourceValues(forKeys: [.fileSizeKey])
                guard let size = values.fileSize, size > 0, size <= maximum else {
                    throw RuntimeAssetError("The downloaded component exceeds its expected size limit")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch { failure = error }
            semaphore.signal()
        }
        task.resume()
        guard semaphore.wait(timeout: .now() + 185) == .success else {
            task.cancel()
            throw RuntimeAssetError("The external component download timed out")
        }
        if let failure { throw failure }
    }

    static func importSDK(_ source: URL, to destination: URL) throws {
#if ASSET_TESTS
        let digest = testLibraryDigest ?? libraryDigest
#else
        let digest = libraryDigest
#endif
        let files = FileManager.default
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".sdk-import-" + UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        if source.pathExtension.lowercased() == "dylib" {
            try verify(source, digest: digest, maximum: 32 * 1024 * 1024)
            try files.copyItem(at: source, to: temporary)
#if ASSET_TESTS
            try testAfterLibraryCopy?(temporary)
#endif
        } else {
            try verify(source, digest: archiveDigest, maximum: 32 * 1024 * 1024)
            guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
                throw RuntimeAssetError("Could not stage the native SDK library")
            }
            let output = try FileHandle(forWritingTo: temporary)
            defer { try? output.close() }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
            process.arguments = ["-p", source.path, "evolis/lib/macos/libevolis.dylib"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw RuntimeAssetError("The SDK archive could not be extracted") }
            try output.synchronize()
        }
        try verify(temporary, digest: digest, maximum: 32 * 1024 * 1024)
        try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
        if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
        try files.moveItem(at: temporary, to: destination)
    }

    static func prepare(runtime: URL, previous: URL?, iconBuilder: URL, importedSDK: URL? = nil) throws {
        let files = FileManager.default
        let library = runtime.appendingPathComponent(libraryPath)
        if files.fileExists(atPath: library.path) {
            try verify(library, digest: libraryDigest, maximum: 32 * 1024 * 1024)
        } else if let importedSDK {
            try importSDK(importedSDK, to: library)
        } else if let previousLibrary = previous?.appendingPathComponent(libraryPath),
                  files.fileExists(atPath: previousLibrary.path) {
            try importSDK(previousLibrary, to: library)
        } else {
            let cache = files.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/AvansiaDriver")
            try files.createDirectory(at: cache, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let imported = cache.appendingPathComponent("libevolis-9.4.1.dylib")
            let archive = cache.appendingPathComponent("evolis_sdk-9.4.1.whl")
            if files.fileExists(atPath: imported.path) {
                try importSDK(imported, to: library)
            } else {
            if !files.fileExists(atPath: archive.path) {
                print("Downloading the proprietary Evolis native SDK 9.4.1 from its original distribution endpoint. No Python runtime is installed.")
                let staged = cache.appendingPathComponent(UUID().uuidString + ".whl")
                defer { try? files.removeItem(at: staged) }
                try download(sdkURL, to: staged, maximum: 32 * 1024 * 1024)
                try verify(staged, digest: archiveDigest, maximum: 32 * 1024 * 1024)
                try files.moveItem(at: staged, to: archive)
            }
            try importSDK(archive, to: library)
            }
        }

        let assets = runtime.appendingPathComponent("Assets")
        let original = assets.appendingPathComponent("Avansia-original.png")
        if files.fileExists(atPath: original.path) {
            try buildIcons(iconBuilder, source: original, destination: assets)
        } else if let old = previous?.appendingPathComponent("Assets/Avansia-original.png"), files.fileExists(atPath: old.path) {
            try files.createDirectory(at: assets, withIntermediateDirectories: true)
            try files.copyItem(at: old, to: original)
            try buildIcons(iconBuilder, source: original, destination: assets)
        } else {
            do {
                try files.createDirectory(at: assets, withIntermediateDirectories: true)
                print("Fetching the transparent Avansia product image from Evolis for this local installation.")
                try download(imageURL, to: original, maximum: 4 * 1024 * 1024)
                try buildIcons(iconBuilder, source: original, destination: assets)
            } catch {
                try? files.removeItem(at: original)
                print("The external product image is unavailable; retaining the bundled project-owned printer icon. \(error)")
            }
        }
    }

    static func buildIcons(_ executable: URL, source: URL, destination: URL) throws {
        let process = Process()
        process.executableURL = executable
        process.arguments = [source.path, destination.path]
        process.standardOutput = FileHandle.standardOutput
        process.standardError = FileHandle.standardError
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw RuntimeAssetError("The transparent printer icon could not be prepared") }
    }
}
