import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let tool = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
let root = FileManager.default.temporaryDirectory.appendingPathComponent("avansia-icon-tests-" + UUID().uuidString)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func fixture(_ name: String, opaque: Bool, empty: Bool = false) -> URL {
    let context = CGContext(data:nil,width:32,height:32,bitsPerComponent:8,bytesPerRow:128,space:space,bitmapInfo:info)!
    if !empty {
        context.setFillColor(CGColor(colorSpace:space,components:[0.8,0.2,0.1,1])!)
        context.fill(CGRect(x:opaque ? 0:8,y:opaque ? 0:8,width:opaque ? 32:16,height:opaque ? 32:16))
    }
    let url=root.appendingPathComponent(name)
    let destination=CGImageDestinationCreateWithURL(url as CFURL,UTType.png.identifier as CFString,1,nil)!
    CGImageDestinationAddImage(destination,context.makeImage()!,nil)
    require(CGImageDestinationFinalize(destination),"Fixture PNG encoding failed")
    return url
}
func run(_ arguments: [String]) throws -> (Int32, Data, String) {
    let process=Process(),output=Pipe(),errors=Pipe()
    process.executableURL=tool;process.arguments=arguments
    process.standardOutput=output;process.standardError=errors
    try process.run()
    let data=output.fileHandleForReading.readDataToEndOfFile()
    let errorData=errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus,data,String(decoding:errorData,as:UTF8.self))
}
func checkOutputs(_ output: URL) throws -> Int {
    var checked=0
    for (name,size) in [("Avansia-48.png",48),("Avansia-128.png",128),("Avansia-512.png",512),("Avansia.png",512)] {
        let source=CGImageSourceCreateWithURL(output.appendingPathComponent(name) as CFURL,nil)!
        let image=CGImageSourceCreateImageAtIndex(source,0,nil)!
        require(image.width==size && image.height==size,"Wrong PNG dimensions")
        let context=CGContext(data:nil,width:size,height:size,bitsPerComponent:8,bytesPerRow:size*4,space:space,bitmapInfo:info)!
        context.draw(image,in:CGRect(x:0,y:0,width:size,height:size))
        let pixels=context.data!.assumingMemoryBound(to:UInt8.self)
        require(pixels[3]==0,"Transparent corner was lost")
        checked+=1
    }
    let url=output.appendingPathComponent("Avansia.icns")
    let data=[UInt8](try Data(contentsOf:url))
    require(Array(data.prefix(4))==Array("icns".utf8),"Missing ICNS header")
    let declared=(4..<8).reduce(0) { $0*256+Int(data[$1]) }
    require(declared==data.count,"ICNS length mismatch")
    let source=CGImageSourceCreateWithURL(url as CFURL,nil)!
    require(CGImageSourceGetCount(source)>=7,"ICNS size representations missing")
    let widths=(0..<CGImageSourceGetCount(source)).map { CGImageSourceCreateImageAtIndex(source,$0,nil)!.width }
    require(widths.contains(16) && widths.contains(128) && widths.contains(512) && widths.contains(1024),"ICNS retina size missing")
    return checked+1
}
let input=fixture("synthetic-alpha.png",opaque:false)
let output=root.appendingPathComponent("converted")
let result=try run([input.path,output.path])
require(result.0==0,"Transparent conversion failed: " + result.2)
let report=try JSONSerialization.jsonObject(with:result.1) as! [String:Any]
let proof=report["source_alpha"] as! [String:Int]
require(proof["fully_transparent_pixels"]==768 && proof["opaque_pixels"]==256,"Source alpha proof is wrong")
let converted=try checkOutputs(output)
let centerSource=CGImageSourceCreateWithURL(output.appendingPathComponent("Avansia-48.png") as CFURL,nil)!
let centerImage=CGImageSourceCreateImageAtIndex(centerSource,0,nil)!
let centerContext=CGContext(data:nil,width:48,height:48,bitsPerComponent:8,bytesPerRow:48*4,space:space,bitmapInfo:info)!
centerContext.draw(centerImage,in:CGRect(x:0,y:0,width:48,height:48))
let center=centerContext.data!.assumingMemoryBound(to:UInt8.self)+((24*48+24)*4)
require(abs(Int(center[0])-204)<=1 && abs(Int(center[1])-51)<=1 && abs(Int(center[2])-26)<=1 && center[3]==255,"Opaque center color changed")
let fallback=root.appendingPathComponent("fallback")
let fallbackResult=try run(["--fallback",fallback.path])
require(fallbackResult.0==0,"Fallback failed: " + fallbackResult.2)
let fallbackChecked=try checkOutputs(fallback)
let fallbackReport=try JSONSerialization.jsonObject(with:fallbackResult.1) as! [String:Any]
require(fallbackReport["mode"] as? String=="project_owned_fallback","Wrong fallback identity")
let invalid=root.appendingPathComponent("invalid.png")
try Data("Not a PNG".utf8).write(to:invalid)
let opaque=fixture("opaque.png",opaque:true)
let empty=fixture("empty.png",opaque:false,empty:true)
for (index,input) in [invalid,opaque,empty].enumerated() {
    let destination=root.appendingPathComponent("rejected-\(index)")
    let result=try run([input.path,destination.path])
    require(result.0 != 0 && !result.2.isEmpty,"Invalid/opaque/empty source was accepted")
    require(!FileManager.default.fileExists(atPath:destination.path),"Rejected input created output")
}
print("PASS: synthetic transparency/color, \(converted+fallbackChecked) PNG/ICNS checks, fallback, and 3 input-boundary rejections; no artwork or hardware used")
