import Foundation
import CoreFoundation

enum ColorCorrectionFace { case front, back }
struct ColorCorrectionError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}
struct ColorCorrectionProfile {
    let id: String
    private let front: [[UInt8]]
    private let back: [[UInt8]]

    static func load(_ path: String) throws -> ColorCorrectionProfile {
        let file = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? file.close() }
        let data = try file.read(upToCount: 65537) ?? Data()
        guard !data.isEmpty, data.count <= 65536,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == ["version", "id", "input", "front", "back"],
              integer(object["version"]) == 1,
              let id = object["id"] as? String, !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let input = object["input"] as? [Any], input.count == 5,
              input.compactMap(integer) == [0, 64, 128, 192, 255] else {
            throw ColorCorrectionError(message: "Invalid color profile: expected schema version 1 and fixed input knots")
        }
        return try ColorCorrectionProfile(id: id, front: channels(object["front"]), back: channels(object["back"]))
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              !["f", "d"].contains(String(cString: number.objCType)) else { return nil }
        return Int(exactly: number.int64Value)
    }
    private static func channels(_ value: Any?) throws -> [[UInt8]] {
        guard let object = value as? [String: Any], Set(object.keys) == ["red", "green", "blue"] else {
            throw ColorCorrectionError(message: "Invalid color profile: each face requires red, green, and blue curves")
        }
        return try ["red", "green", "blue"].map { name in
            guard let values = object[name] as? [Any], values.count == 5 else {
                throw ColorCorrectionError(message: "Invalid color profile: each channel requires five integer outputs")
            }
            let output = values.compactMap(integer)
            guard output.count == 5, output.first == 0, output.last == 255,
                  output.allSatisfy({ (0...255).contains($0) }),
                  zip(output, output.dropFirst()).allSatisfy({ $0 <= $1 }) else {
                throw ColorCorrectionError(message: "Invalid color profile: curves must be monotonic, within 0...255, and anchored at 0 and 255")
            }
            let input = [0, 64, 128, 192, 255]
            return (0...255).map { value in
                let segment = min(value / 64, 3)
                let width = input[segment + 1] - input[segment]
                let numerator = (value - input[segment]) * (output[segment + 1] - output[segment])
                return UInt8(output[segment] + (numerator + width / 2) / width)
            }
        }
    }
    func correctBMP(_ input: String, to output: String, face: ColorCorrectionFace) throws {
        let source = URL(fileURLWithPath: input).standardizedFileURL.resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: output).standardizedFileURL.resolvingSymlinksInPath()
        guard source != destination else { throw ColorCorrectionError(message: "Color correction requires a separate output BMP") }
        let width = 2048, height = 1300, offset = 54
        let expectedSize = offset + width * height * 3
        let file = try FileHandle(forReadingFrom: source)
        defer { try? file.close() }
        var data = try file.read(upToCount: expectedSize + 1) ?? Data()
        guard data.count == expectedSize else { throw ColorCorrectionError(message: "Color correction requires a complete 2048 x 1300 BMP") }
        func le(_ start: Int, _ length: Int) -> Int {
            (0..<length).reduce(0) { $0 | Int(data[start + $1]) << (8 * $1) }
        }
        guard data[0] == 66, data[1] == 77, le(2, 4) == expectedSize,
              le(10, 4) == offset, le(14, 4) == 40, le(18, 4) == width, le(22, 4) == height,
              le(26, 2) == 1, le(28, 2) == 24, le(30, 4) == 0,
              [0, width * height * 3].contains(le(34, 4)), le(38, 4) == 23622, le(42, 4) == 23622 else {
            throw ColorCorrectionError(message: "Color correction requires a 600 dpi, bottom-up, uncompressed 24-bit BGR BMP")
        }
        let tables = face == .front ? front : back
        try data.withUnsafeMutableBytes { storage in
            let pixels = storage.bindMemory(to: UInt8.self)
            for index in stride(from: offset, to: expectedSize, by: 3) {
                let originalSum = Int(pixels[index]) + Int(pixels[index + 1]) + Int(pixels[index + 2])
                let blue = tables[2][Int(pixels[index])]
                let green = tables[1][Int(pixels[index + 1])]
                let red = tables[0][Int(pixels[index + 2])]
                guard (originalSum <= 96) == (Int(blue) + Int(green) + Int(red) <= 96) else {
                    throw ColorCorrectionError(message: "The color profile changes the black-separation boundary; no corrected output will be published")
                }
                pixels[index] = blue
                pixels[index + 1] = green
                pixels[index + 2] = red
            }
        }
        try data.write(to: destination, options: .atomic)
    }
}
