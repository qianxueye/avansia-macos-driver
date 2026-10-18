import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

struct IconError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
func fail(_ message: String) -> IconError { IconError(message: message) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
func context(_ width: Int, _ height: Int) throws -> CGContext {
    guard let result = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                 bytesPerRow: width * 4, space: space, bitmapInfo: bitmapInfo) else {
        throw fail("Could not create an sRGB icon context")
    }
    return result
}
func alphaProof(_ image: CGImage) throws -> [String: Int] {
    let bitmap = try context(image.width, image.height)
    bitmap.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    guard let data = bitmap.data?.assumingMemoryBound(to: UInt8.self) else { throw fail("Could not read icon pixels") }
    var transparent = 0
    var partial = 0
    for index in 0..<(image.width * image.height) {
        let alpha = data[index * 4 + 3]
        if alpha == 0 { transparent += 1 }
        else if alpha < 255 { partial += 1 }
    }
    return ["width": image.width, "height": image.height, "fully_transparent_pixels": transparent,
            "partially_transparent_pixels": partial,
            "opaque_pixels": image.width * image.height - transparent - partial]
}
func loadPNG(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          CGImageSourceGetType(source) as String? == UTType.png.identifier,
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        throw fail("Input must be a valid PNG image")
    }
    let proof = try alphaProof(image)
    guard proof["fully_transparent_pixels"]! > 0,
          proof["opaque_pixels"]! + proof["partially_transparent_pixels"]! > 0 else {
        throw fail("Official artwork must contain both transparent and visible pixels; no background removal is performed")
    }
    return image
}
func fallback() throws -> CGImage {
    let bitmap = try context(1024, 1024)
    func fill(_ rect: CGRect, _ rgb: [CGFloat], radius: CGFloat = 0) {
        bitmap.setFillColor(CGColor(colorSpace: space, components: rgb + [1])!)
        bitmap.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        bitmap.fillPath()
    }
    // Original geometric artwork: paper, printer enclosure, output sheet and status light.
    fill(CGRect(x: 280, y: 590, width: 464, height: 300), [0.15, 0.19, 0.24], radius: 18)
    fill(CGRect(x: 296, y: 606, width: 432, height: 268), [0.96, 0.97, 0.98], radius: 8)
    fill(CGRect(x: 144, y: 310, width: 736, height: 380), [0.19, 0.24, 0.30], radius: 58)
    fill(CGRect(x: 222, y: 398, width: 580, height: 68), [0.06, 0.09, 0.13], radius: 18)
    fill(CGRect(x: 264, y: 130, width: 496, height: 310), [0.15, 0.19, 0.24], radius: 16)
    fill(CGRect(x: 280, y: 146, width: 464, height: 294), [0.96, 0.97, 0.98], radius: 6)
    for y in [210, 264, 318] {
        fill(CGRect(x: 334, y: y, width: 356, height: 16), [0.48, 0.55, 0.62], radius: 8)
    }
    bitmap.setFillColor(CGColor(colorSpace: space, components: [0.15, 0.78, 0.65, 1])!)
    bitmap.fillEllipse(in: CGRect(x: 770, y: 592, width: 34, height: 34))
    guard let image = bitmap.makeImage() else { throw fail("Could not create the project-owned fallback") }
    return image
}
func resized(_ image: CGImage, _ size: Int) throws -> CGImage {
    let bitmap = try context(size, size)
    bitmap.interpolationQuality = .high
    let scale = min(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
    let width = CGFloat(image.width) * scale
    let height = CGFloat(image.height) * scale
    bitmap.draw(image, in: CGRect(x: (CGFloat(size) - width) / 2, y: (CGFloat(size) - height) / 2,
                                 width: width, height: height))
    guard let result = bitmap.makeImage() else { throw fail("Could not resize the icon") }
    return result
}
func writePNG(_ image: CGImage, _ url: URL) throws {
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
        throw fail("Could not create PNG output")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw fail("Could not encode PNG output") }
    try (data as Data).write(to: url, options: .atomic)
}
func build(_ image: CGImage, output: URL, mode: String) throws -> [String: Any] {
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("avansia-icons-" + UUID().uuidString)
    let iconset = temporary.appendingPathComponent("Avansia.iconset")
    try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: temporary) }
    let sizes = [16, 32, 48, 64, 128, 256, 512, 1024]
    var variants = [Int: CGImage]()
    for size in sizes { variants[size] = try resized(image, size) }
    var outputs = [[String: Any]]()
    for (name, size) in [("Avansia-48.png", 48), ("Avansia-128.png", 128), ("Avansia-512.png", 512), ("Avansia.png", 512)] {
        let url = output.appendingPathComponent(name)
        try writePNG(variants[size]!, url)
        outputs.append(["path": url.path, "alpha": try alphaProof(variants[size]!)])
    }
    for size in [16, 32, 128, 256, 512] {
        try writePNG(variants[size]!, iconset.appendingPathComponent("icon_\(size)x\(size).png"))
        try writePNG(variants[size * 2]!, iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
    }
    let icns = output.appendingPathComponent("Avansia.icns")
    let process = Process()
    let errors = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    process.arguments = ["-c", "icns", "-o", icns.path, iconset.path]
    process.standardError = errors
    try process.run()
    let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw fail("iconutil failed: " + String(decoding: diagnostic, as: UTF8.self))
    }
    return ["mode": mode, "source_alpha": try alphaProof(image), "png_outputs": outputs,
            "icns": icns.path, "icns_logical_sizes": [16, 32, 128, 256, 512], "icns_scales": [1, 2],
            "conversion": "sRGB, aspect-preserving resize, original alpha retained; no background removal"]
}

do {
    let arguments = CommandLine.arguments
    guard arguments.count == 3 else { throw fail("Usage: BuildIcons INPUT.png OUTPUTDIR | BuildIcons --fallback OUTPUTDIR") }
    let output = URL(fileURLWithPath: arguments[2], isDirectory: true).standardizedFileURL
    let isFallback = arguments[1] == "--fallback"
    let image = try isFallback ? fallback() : loadPNG(URL(fileURLWithPath: arguments[1]))
    let report = try build(image, output: output, mode: isFallback ? "project_owned_fallback" : "private_official_conversion")
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys, .prettyPrinted]))
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
