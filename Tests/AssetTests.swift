import Foundation
import CryptoKit

@main struct AssetTests {
    static func main() throws {
        let files = FileManager.default
        let folder = files.temporaryDirectory.appendingPathComponent("avansia-assets-" + UUID().uuidString)
        try files.createDirectory(at: folder, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: folder) }
        func expect(_ condition: Bool, _ message: String) throws {
            if !condition { throw RuntimeAssetError(message) }
        }
        func rejects(_ body: () throws -> Void) throws {
            var rejected = false
            do { try body() } catch { rejected = true }
            try expect(rejected, "Invalid external component was accepted")
        }
        let source = folder.appendingPathComponent("sample.bin")
        let bytes = Data("Synthetic component integrity fixture".utf8)
        try bytes.write(to: source)
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        try RuntimeAssets.verify(source, digest: digest, maximum: 1024)
        try rejects { try RuntimeAssets.verify(source, digest: String(repeating: "0", count: 64), maximum: 1024) }
        try rejects { try RuntimeAssets.verify(source, digest: digest, maximum: 1) }
        try rejects { try RuntimeAssets.verify(folder, digest: digest, maximum: 1024) }
        try Data().write(to: source)
        try rejects { try RuntimeAssets.verify(source, digest: digest, maximum: 1024) }
        let output = folder.appendingPathComponent("installed/libevolis.dylib")
        try files.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        let sentinel = Data("Existing installation must survive failed import".utf8)
        try sentinel.write(to: output)
        for name in ["tampered.dylib", "truncated.whl"] {
            let invalid = folder.appendingPathComponent(name)
            try bytes.write(to: invalid)
            try rejects { try RuntimeAssets.importSDK(invalid, to: output) }
            try expect(try Data(contentsOf: output) == sentinel, "Failed SDK import changed the existing library")
        }
#if ASSET_TESTS
        let direct = folder.appendingPathComponent("synthetic.dylib")
        try bytes.write(to: direct)
        RuntimeAssets.testLibraryDigest = digest
        defer { RuntimeAssets.testLibraryDigest = nil; RuntimeAssets.testAfterLibraryCopy = nil }
        RuntimeAssets.testAfterLibraryCopy = { staged in
            try expect(staged != direct && staged.deletingLastPathComponent() == output.deletingLastPathComponent(), "SDK verification must inspect a staged copy beside the destination")
            try Data("Changed bytes after source verification".utf8).write(to: staged)
        }
        try rejects { try RuntimeAssets.importSDK(direct, to: output) }
        try expect(try Data(contentsOf: output) == sentinel, "Tampered staged copy replaced the existing native library")
        try expect(try Data(contentsOf: direct) == bytes, "Staged-copy test leaves the verified source intact")
        let retained = try files.contentsOfDirectory(atPath: output.deletingLastPathComponent().path)
        try expect(!retained.contains { $0.hasPrefix(".sdk-import-") }, "Failed staged verification left import residue")
        RuntimeAssets.testAfterLibraryCopy = { _ in try Data("Source changed after copy".utf8).write(to: direct) }
        try RuntimeAssets.importSDK(direct, to: output)
        try expect(try Data(contentsOf: output) == bytes, "Publication must use verified staged bytes even when the source subsequently changes")
        try RuntimeAssets.verify(output, digest: digest, maximum: 1024)
        RuntimeAssets.testAfterLibraryCopy = nil
        RuntimeAssets.testLibraryDigest = nil
        print("PASS: direct-library staged digest rejects post-copy tampering, preserves existing output, removes staging, and publishes verified copy despite later source changes")
#endif
        if CommandLine.arguments.count == 2 {
            let official = URL(fileURLWithPath: CommandLine.arguments[1])
            try RuntimeAssets.importSDK(official, to: output)
            try RuntimeAssets.verify(output, digest: RuntimeAssets.libraryDigest, maximum: 32 * 1024 * 1024)
            try expect(try Data(contentsOf: output) != sentinel, "Official native member was not extracted")
            print("PASS: official pinned archive/member extraction without Python; no library execution")
        }
        print("PASS: integrity pins, size/type/empty boundaries, malformed archive/library rejection and preserved existing output")
    }
}
