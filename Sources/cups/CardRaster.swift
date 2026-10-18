import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let width = 2048
let height = 1300
let physicalScale = 600.0 / 72.0
let cardWidth = 85.60 / 25.4 * 600
let cardHeight = 53.98 / 25.4 * 600
let card = CGRect(x: (Double(width) - cardWidth) / 2, y: (Double(height) - cardHeight) / 2,
                  width: cardWidth, height: cardHeight)

func failure(_ message: String) -> NSError {
    NSError(domain: "CardRaster", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
}
func valid(_ rect: CGRect) -> Bool {
    [rect.origin.x, rect.origin.y, rect.width, rect.height].allSatisfy { $0.isFinite }
        && rect.width > 0 && rect.height > 0
}
func values(_ rect: CGRect) -> [Double] {
    [rect.minX, rect.minY, rect.width, rect.height]
}
func explicitBox(_ page: CGPDFPage, _ name: String) -> Bool {
    guard let dictionary = page.dictionary else { return false }
    var array: CGPDFArrayRef?
    return CGPDFDictionaryGetArray(dictionary, name, &array)
}
func render(_ page: CGPDFPage, number: Int, directory: URL, mode: String) throws -> [String: Any] {
    let crop = page.getBoxRect(.cropBox)
    guard valid(crop) else { throw failure("Page \(number) has degenerate CropBox bounds") }
    let rotation = ((page.rotationAngle % 360) + 360) % 360
    guard rotation % 90 == 0 else { throw failure("Page \(number) has an invalid rotation") }
    let rotated = rotation == 90 || rotation == 270
    let initialWidth = rotated ? crop.height : crop.width
    let initialHeight = rotated ? crop.width : crop.height
    let autoRotate = initialHeight > initialWidth
        && min(cardWidth / initialHeight, cardHeight / initialWidth)
            > min(cardWidth / initialWidth, cardHeight / initialHeight)
    let sourceWidth = autoRotate ? initialHeight : initialWidth
    let sourceHeight = autoRotate ? initialWidth : initialHeight
    let orientedRect = CGRect(x: 0, y: 0, width: sourceWidth, height: sourceHeight)
    let orientation = page.getDrawingTransform(.cropBox, rect: orientedRect,
                                               rotate: autoRotate ? 90 : 0, preserveAspectRatio: true)
    var scale: Double
    var drawRect: CGRect
    var clipBox = crop
    var preserved = false
    let trim = page.getBoxRect(.trimBox)
    let bleed = page.getBoxRect(.bleedBox).intersection(crop)
    let orientedTrim = trim.applying(orientation)
    if (mode == "fill" || mode == "borderless"), explicitBox(page, "TrimBox"), explicitBox(page, "BleedBox"),
       valid(trim), valid(bleed), crop.contains(trim), bleed.contains(trim),
       abs(orientedTrim.width * physicalScale - cardWidth) < 0.9,
       abs(orientedTrim.height * physicalScale - cardHeight) < 0.9 {
        scale = physicalScale
        let x = card.midX - orientedTrim.midX * scale
        let y = card.midY - orientedTrim.midY * scale
        let mappedBleed = bleed.applying(orientation).applying(CGAffineTransform(a: scale, b: 0, c: 0, d: scale, tx: x, ty: y))
        if mappedBleed.minX <= 0 && mappedBleed.minY <= 0
            && mappedBleed.maxX >= Double(width) && mappedBleed.maxY >= Double(height) {
            preserved = true
            clipBox = bleed
            drawRect = CGRect(x: x, y: y, width: sourceWidth * scale, height: sourceHeight * scale)
        } else {
            scale = mode == "borderless" ? physicalScale
                : max(Double(width) / sourceWidth, Double(height) / sourceHeight)
            drawRect = CGRect(x: (Double(width) - sourceWidth * scale) / 2,
                              y: (Double(height) - sourceHeight * scale) / 2,
                              width: sourceWidth * scale, height: sourceHeight * scale)
        }
    } else {
        scale = (mode == "none" || mode == "borderless") ? physicalScale : mode == "fit"
            ? min(cardWidth / sourceWidth, cardHeight / sourceHeight)
            : max(Double(width) / sourceWidth, Double(height) / sourceHeight)
        drawRect = CGRect(x: (Double(width) - sourceWidth * scale) / 2,
                          y: (Double(height) - sourceHeight * scale) / 2,
                          width: sourceWidth * scale, height: sourceHeight * scale)
    }
    guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: width * 4, space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw failure("Could not create the sRGB rendering context")
    }
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.interpolationQuality = .high
    context.setShouldAntialias(true)
    context.saveGState()
    context.translateBy(x: drawRect.minX, y: drawRect.minY)
    context.scaleBy(x: scale, y: scale)
    context.concatenate(orientation)
    context.clip(to: clipBox)
    context.drawPDFPage(page)
    context.restoreGState()
    guard let pixels = context.data?.assumingMemoryBound(to: UInt8.self) else {
        throw failure("Could not read rendered pixels")
    }
    if mode == "borderless" && !preserved {
        // Replicate fully interior edge samples only into pixels whose centers lie outside the card.
        // CGContext rows run top-down; the centered card has identical vertical bounds in either origin.
        let left = Int(ceil(card.minX))
        let right = Int(floor(card.maxX)) - 1
        let top = Int(ceil(card.minY))
        let bottom = Int(floor(card.maxY)) - 1
        for y in 0..<height {
            for x in 0..<width where Double(x) + 0.5 < card.minX || Double(x) + 0.5 >= card.maxX
                || Double(y) + 0.5 < card.minY || Double(y) + 0.5 >= card.maxY {
                let source = (min(max(y, top), bottom) * width + min(max(x, left), right)) * 4
                let target = (y * width + x) * 4
                for channel in 0..<4 { pixels[target + channel] = pixels[source + channel] }
            }
        }
    }
    guard let image = context.makeImage() else { throw failure("Could not create the rendered image") }
    let stem = String(format: "page-%04d", number)
    let bmpURL = directory.appendingPathComponent(stem + ".bmp")
    let pngURL = directory.appendingPathComponent(stem + ".png")
    guard let destination = CGImageDestinationCreateWithURL(pngURL as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        throw failure("Could not create PNG preview")
    }
    CGImageDestinationAddImage(destination, image, [kCGImagePropertyDPIWidth: 600, kCGImagePropertyDPIHeight: 600] as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw failure("Could not encode PNG preview") }
    var bmp = Data([0x42, 0x4d])
    func appendLE<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { bmp.append(contentsOf: $0) }
    }
    let rowBytes = (width * 3 + 3) & ~3
    appendLE(UInt32(54 + rowBytes * height)); appendLE(UInt32(0)); appendLE(UInt32(54))
    appendLE(UInt32(40)); appendLE(Int32(width)); appendLE(Int32(height))
    appendLE(UInt16(1)); appendLE(UInt16(24)); appendLE(UInt32(0))
    appendLE(UInt32(rowBytes * height)); appendLE(Int32(23622)); appendLE(Int32(23622))
    appendLE(UInt32(0)); appendLE(UInt32(0))
    // CGContext storage is top-down; a positive-height BMP stores its bottom row first.
    for y in (0..<height).reversed() {
        let row = pixels + y * width * 4
        for x in 0..<width { bmp.append(contentsOf: [row[x * 4 + 2], row[x * 4 + 1], row[x * 4]]) }
        bmp.append(contentsOf: repeatElement(UInt8(0), count: rowBytes - width * 3))
    }
    try bmp.write(to: bmpURL, options: .atomic)
    let blackURL = directory.appendingPathComponent(stem + "-black.bmp")
    var blackBMP = Data([0x42, 0x4d])
    func appendBlackLE<T: FixedWidthInteger>(_ value: T) {
        var encoded = value.littleEndian
        withUnsafeBytes(of: &encoded) { blackBMP.append(contentsOf: $0) }
    }
    let blackStride = ((width + 31) / 32) * 4
    appendBlackLE(UInt32(62 + blackStride * height)); appendBlackLE(UInt32(0)); appendBlackLE(UInt32(62))
    appendBlackLE(UInt32(40)); appendBlackLE(Int32(width)); appendBlackLE(Int32(height))
    appendBlackLE(UInt16(1)); appendBlackLE(UInt16(1)); appendBlackLE(UInt32(0))
    appendBlackLE(UInt32(blackStride * height)); appendBlackLE(Int32(23622)); appendBlackLE(Int32(23622))
    appendBlackLE(UInt32(2)); appendBlackLE(UInt32(0))
    blackBMP.append(contentsOf: [0, 0, 0, 0, 255, 255, 255, 0])
    let factor = 9
    let sampleOffset = factor / 2
    let stripHeight = 128
    var blackRows = [UInt8](repeating: 255, count: blackStride * height)
    for stripTop in stride(from: 0, to: height, by: stripHeight) {
        let stripRows = min(stripHeight, height - stripTop)
        guard let blackContext = CGContext(data: nil, width: width * factor, height: stripRows * factor,
                                          bitsPerComponent: 8, bytesPerRow: width * factor * 4, space: colorSpace,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw failure("Could not create the black sampling context")
        }
        blackContext.setFillColor(CGColor(colorSpace: colorSpace, components: [1, 1, 1, 1])!)
        blackContext.fill(CGRect(x: 0, y: 0, width: width * factor, height: stripRows * factor))
        blackContext.interpolationQuality = .high
        blackContext.setShouldAntialias(false)
        blackContext.scaleBy(x: CGFloat(factor), y: CGFloat(factor))
        blackContext.translateBy(x: 0, y: -CGFloat(height - stripTop - stripRows))
        blackContext.translateBy(x: drawRect.minX, y: drawRect.minY)
        blackContext.scaleBy(x: scale, y: scale)
        blackContext.concatenate(orientation)
        blackContext.clip(to: clipBox)
        blackContext.drawPDFPage(page)
        guard let blackPixels = blackContext.data?.assumingMemoryBound(to: UInt8.self) else {
            throw failure("Could not read the black sampling pixels")
        }
        let left = Int(ceil(card.minX))
        let right = Int(floor(card.maxX)) - 1
        let top = Int(ceil(card.minY))
        let bottom = Int(floor(card.maxY)) - 1
        for y in stripTop..<(stripTop + stripRows) {
            for x in 0..<width {
                var sourceX = x
                var sourceY = y
                if mode == "borderless" && !preserved && (Double(x) + 0.5 < card.minX || Double(x) + 0.5 >= card.maxX
                    || Double(y) + 0.5 < card.minY || Double(y) + 0.5 >= card.maxY) {
                    sourceX = min(max(x, left), right)
                    sourceY = min(max(y, top), bottom)
                }
                // The selected high-resolution pixel has a finite footprint; this approximates point sampling.
                let offset = (((sourceY - stripTop) * factor + sampleOffset) * width * factor + sourceX * factor + sampleOffset) * 4
                let sum = Int(blackPixels[offset]) + Int(blackPixels[offset + 1]) + Int(blackPixels[offset + 2])
                if sum <= 96 { blackRows[(height - 1 - y) * blackStride + x / 8] &= ~(UInt8(0x80) >> (x % 8)) }
            }
        }
    }
    blackBMP.append(contentsOf: blackRows)
    try blackBMP.write(to: blackURL, options: .atomic)
    return ["page": number, "bmp": bmpURL.path, "preview": pngURL.path,
            "black_bmp": blackURL.path,
            "black_sampling": ["method": "9x_aa_off_center_pixel", "source_dpi": 5400, "target_dpi": 600,
                               "source_pixel_offset": [4, 4], "rgb_sum_max": 96,
                               "sample_footprint_pixels": 1.0 / 9.0, "approximation": "finite_pixel_footprint", "strip_height_pixels": 128],
            "source_width_points": crop.width, "source_height_points": crop.height,
            "rotation": (rotation + (autoRotate ? 90 : 0)) % 360,
            "automatic_rotation": autoRotate ? 90 : 0, "scale": scale,
            "card_rect_pixels": values(card), "draw_rect_pixels": values(drawRect),
            "trim_bleed_physical_size_preserved": preserved,
            "geometry_policy": mode == "borderless" ? "physical_size_with_edge_bleed"
                : preserved ? "trim_bleed_physical_size" : mode,
            "coordinate_system": "bottom_left",
            "card_origin": "centered_uncalibrated"]
}

do {
    guard CommandLine.arguments.count == 4, ["fill", "fit", "none", "borderless"].contains(CommandLine.arguments[3]) else {
        throw failure("Usage: CardRaster INPUT.pdf OUTPUT_DIR fill|fit|none|borderless")
    }
    let input = URL(fileURLWithPath: CommandLine.arguments[1])
    guard let document = CGPDFDocument(input as CFURL) else { throw failure("Could not open PDF") }
    guard !document.isEncrypted else { throw failure("Encrypted PDFs are not supported") }
    guard (1...100).contains(document.numberOfPages) else { throw failure("PDF must contain between 1 and 100 pages") }
    // Validate every page before producing any output.
    for number in 1...document.numberOfPages {
        guard let page = document.page(at: number), valid(page.getBoxRect(.cropBox)), valid(page.getBoxRect(.mediaBox)) else {
            throw failure("Page \(number) has degenerate bounds")
        }
    }
    let directory = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).standardizedFileURL
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var pages: [[String: Any]] = []
    for number in 1...document.numberOfPages {
        pages.append(try render(document.page(at: number)!, number: number, directory: directory, mode: CommandLine.arguments[3]))
    }
    let manifest: [String: Any] = ["page_count": pages.count, "pages": pages, "mode": CommandLine.arguments[3],
                                  "dpi": 600, "raster_width": width, "raster_height": height,
                                  "card_origin": "centered_uncalibrated", "color_space": "sRGB"]
    let json = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
    FileHandle.standardOutput.write(json)
    FileHandle.standardOutput.write(Data([10]))
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
    exit(1)
}
