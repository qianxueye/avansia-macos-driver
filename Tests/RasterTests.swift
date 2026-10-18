import Foundation
import CoreGraphics
import PDFKit
import Darwin

let raster = URL(fileURLWithPath: CommandLine.arguments[1])
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let pointMM = 72.0 / 25.4
let physicalScale = 600.0 / 72.0
let cardWidth = 85.6 / 25.4 * 600
let cardHeight = 53.98 / 25.4 * 600
let space = CGColorSpace(name: CGColorSpace.sRGB)!
let localScheduler = "/private/var/run/cupsd"
let localCUPSCommands: Set<String> = ["/usr/bin/lpstat", "/usr/sbin/lpadmin", "/usr/bin/lp", "/usr/bin/cancel"]
func require(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}
func close(_ a: Double, _ b: Double, _ message: String, tolerance: Double = 0.001) {
    require(abs(a-b) < tolerance, message + ": \(a) versus \(b)")
}
func run(_ executable: String, _ arguments: [String]) throws -> (Int32, Data, String) {
    let process = Process(), output = Pipe(), errors = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = localCUPSCommands.contains(executable) ? ["-h", localScheduler] + arguments : arguments
    var environment = ProcessInfo.processInfo.environment
    environment["CUPS_SERVER"] = localScheduler
    process.environment = environment
    process.standardOutput = output; process.standardError = errors
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    let diagnostic = errors.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, data, String(decoding: diagnostic, as: UTF8.self))
}
func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> CGRect {
    CGRect(x: x*pointMM, y: y*pointMM, width: w*pointMM, height: h*pointMM)
}
func boxData(_ rect: CGRect) -> Data {
    var box = rect
    return Data(bytes: &box, count: MemoryLayout<CGRect>.size)
}
func fill(_ context: CGContext, _ rect: CGRect, _ rgb: [CGFloat]) {
    context.setFillColor(CGColor(colorSpace: space, components: rgb + [1])!)
    context.fill(rect)
}
struct Fixture {
    let name: String
    let pdf: URL
    let markers: [CGRect]
    let bleed: Bool
    let cropOffset: Bool
}
func fixture(_ name: String, portrait: Bool, bleed: Bool, rotateSecond: Bool = false, cropOffset: Bool = false) -> Fixture {
    let url = root.appendingPathComponent(name + ".pdf")
    let cardW = portrait ? 53.98 : 85.6, cardH = portrait ? 85.6 : 53.98
    let margin = bleed ? 3.0 : 0.0
    let originX = cropOffset ? 5.0 : margin, originY = cropOffset ? 8.0 : margin
    var media = rect(0, 0, cropOffset ? 100 : cardW + 2*margin, cropOffset ? 70 : cardH + 2*margin)
    let context = CGContext(url as CFURL, mediaBox: &media, nil)!
    var markers = [CGRect]()
    let count = cropOffset ? 1 : 2
    for index in 0..<count {
        var info: [CFString: Any] = [kCGPDFContextMediaBox: boxData(media)]
        if bleed {
            info[kCGPDFContextTrimBox] = boxData(rect(3, 3, cardW, cardH))
            info[kCGPDFContextBleedBox] = boxData(media)
        }
        context.beginPDFPage(info as CFDictionary)
        fill(context, media, cropOffset ? [0, 0, 0] : index == 0 ? [0.2, 0.4, 0.6] : [0.6, 0.2, 0.4])
        fill(context, rect(originX, originY, cardW, cardH), cropOffset ? [0.1, 0.7, 0.9] : index == 0 ? [0.8, 0.8, 0.8] : [0.9, 0.9, 0.9])
        let marker = index == 0 ? rect(originX+8, originY+10, 12, 1) : rect(originX+30, originY+35, 6, 2)
        fill(context, marker, [0, 0, 0]); markers.append(marker)
        context.endPDFPage()
    }
    context.closePDF()
    if rotateSecond || cropOffset {
        let document = PDFDocument(url: url)!
        if rotateSecond { document.page(at: 1)!.rotation = 90 }
        if cropOffset { document.page(at: 0)!.setBounds(rect(5, 8, cardW, cardH), for: .cropBox) }
        require(document.write(to: url), "Synthetic PDF metadata write failed")
    }
    return Fixture(name: name, pdf: url, markers: markers, bleed: bleed, cropOffset: cropOffset)
}
let fixtures = [fixture("portrait-bleed-duplex", portrait: true, bleed: true),
                fixture("landscape-rotated-duplex", portrait: false, bleed: false, rotateSecond: true),
                fixture("offset-crop", portrait: false, bleed: false, cropOffset: true)]
let ppdBase = """
*PPD-Adobe: "4.3"
*FormatVersion: "4.3"
*FileVersion: "1.0"
*LanguageVersion: English
*LanguageEncoding: ISOLatin1
*PCFileName: "RASTER.PPD"
*Manufacturer: "Synthetic Test"
*Product: "(Synthetic CR80)"
*ModelName: "Synthetic CR80"
*ShortNickName: "Synthetic CR80"
*NickName: "Synthetic CR80 Geometry"
*PSVersion: "(3010.000) 0"
*LanguageLevel: "3"
*ColorDevice: True
*DefaultColorSpace: RGB
*FileSystem: False
*Throughput: "1"
*cupsVersion: 2.3
*cupsManualCopies: True
*cupsFilter2: "application/vnd.cups-pdf application/pdf 10 -"
*OpenUI *PageSize: PickOne
*OrderDependency: 10 AnySetup *PageSize
*DefaultPageSize: CR80
*PageSize CR80: "<</PageSize[153.014173228346 242.645669291339]>>setpagedevice"
*CloseUI: *PageSize
*DefaultImageableArea: CR80
*ImageableArea CR80: "0 0 153.014173228346 242.645669291339"
*DefaultPaperDimension: CR80
*PaperDimension CR80: "153.014173228346 242.645669291339"
"""
let oldPPD = root.appendingPathComponent("filtered.ppd")
let directPPD = root.appendingPathComponent("direct.ppd")
try (ppdBase + "\n").write(to: oldPPD, atomically: true, encoding: .utf8)
let directDirective = "*cupsFilter2: \"application/pdf application/pdf 0 -\""
try (ppdBase + "\n" + directDirective + "\n").write(to: directPPD, atomically: true, encoding: .utf8)
let source = fixtures[0].pdf
let original = try Data(contentsOf: source)
let target = "printer/Avansia_Raster_Test"
// cupsfilter needs -e to use PPD-declared routes instead of generic PostScript conversion.
let baseOptions = ["-e", "-i", "application/pdf", "-m", target, "-o", "page-ranges=2", "-o", "sides=two-sided-long-edge", "-n", "1"]
let oldRoute = try run("/usr/sbin/cupsfilter", ["--list-filters", "-p", oldPPD.path] + baseOptions + [source.path])
require(oldRoute.0 == 0, "Old route listing failed: " + oldRoute.2)
require(String(decoding: oldRoute.1, as: UTF8.self).contains("cgpdftopdf"), "Negative control did not select the macOS PDF filter: " + String(decoding: oldRoute.1, as: UTF8.self) + " diagnostics: " + oldRoute.2)
var routes = [[String: Any]]()
for mode in ["none", "fit", "fill"] {
    let arguments = ["-p", directPPD.path] + baseOptions + ["-o", "print-scaling=" + mode, source.path]
    let listing = try run("/usr/sbin/cupsfilter", ["--list-filters"] + arguments)
    require(listing.0 == 0, "Direct route listing failed: " + listing.2)
    let filters = String(decoding: listing.1, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    require(!filters.contains("cgpdftopdf"), "CUPS selected a scaling/page-selection filter")
    let result = try run("/usr/sbin/cupsfilter", arguments)
    require(result.0 == 0, "Offline CUPS route failed: " + result.2)
    require(filters.isEmpty, "Direct route unexpectedly contains a filter")
    require(result.1.isEmpty, "Unexpected nonempty zero-filter utility output")
    routes.append(["mode":mode,"filters":filters,"exit_status":result.0,"output_bytes":result.1.count,
                   "byte_forwarding_proven_by_utility":false,
                   "limit":"The standalone cupsfilter utility removes null filters and does not copy input for an empty graph; the native scheduler gate below supplies byte proof."])

}
func le(_ data: [UInt8], _ offset: Int, _ count: Int) -> Int {
    (0..<count).reduce(0) { $0 | Int(data[offset+$1]) << ($1*8) }
}
func ink(_ data: [UInt8], _ x: Int, _ y: Int) -> Bool {
    data[62+y*256+x/8] & (UInt8(0x80) >> (x%8)) == 0
}
func rgb(_ data: [UInt8], _ x: Int, _ y: Int) -> [Int] {
    let index = 54 + y*6144 + x*3
    return [Int(data[index+2]), Int(data[index+1]), Int(data[index])]
}
var geometry = [[String: Any]]()
let queueOnly = ProcessInfo.processInfo.environment["RASTER_QUEUE_ONLY"] == "1"
if !queueOnly {
for fixture in fixtures {
    let document = CGPDFDocument(fixture.pdf as CFURL)!
    var baselineMasks = [Data]()
    for mode in ["none", "fit", "fill"] {
        let folder = root.appendingPathComponent(fixture.name + "-" + mode)
        let result = try run(raster.path, [fixture.pdf.path, folder.path, mode == "none" ? "borderless" : mode])
        require(result.0 == 0, "Raster failed: " + result.2)
        let manifest = try JSONSerialization.jsonObject(with: result.1) as! [String: Any]
        require(manifest["dpi"] as? Int == 600, "Wrong physical dpi")
        let pages = manifest["pages"] as! [[String: Any]]
        require(pages.count == fixture.markers.count, "Every-page render was not preserved")
        var pageResults = [[String: Any]]()
        var masks = [Data]()
        for (index, page) in pages.enumerated() {
            let pdfPage = document.page(at: index+1)!
            let crop = pdfPage.getBoxRect(.cropBox)
            let quarterTurn = (Int(pdfPage.rotationAngle) + (page["automatic_rotation"] as! Int)) % 180 != 0
            let sourceW = quarterTurn ? crop.height : crop.width
            let sourceH = quarterTurn ? crop.width : crop.height
            let scale = page["scale"] as! Double
            let preserved = page["trim_bleed_physical_size_preserved"] as! Bool
            let expected = mode == "none" || (mode == "fill" && fixture.bleed) ? physicalScale : mode == "fit"
                ? min(cardWidth/sourceW, cardHeight/sourceH) : max(2048/sourceW, 1300/sourceH)
            close(scale, expected, "Wrong source scaling")
            require(preserved == (fixture.bleed && mode != "fit"), "Wrong explicit TrimBox/BleedBox policy")
            let draw = page["draw_rect_pixels"] as! [Double]
            if mode == "fit" {
                require(draw[2] <= cardWidth+0.001 && draw[3] <= cardHeight+0.001, "Fit exceeds nominal card")
            } else if mode == "fill" && !fixture.bleed {
                require(draw[2] >= 2048-0.001 && draw[3] >= 1300-0.001, "Fill does not cover raster")
            }
            let bitmap = [UInt8](try Data(contentsOf: URL(fileURLWithPath: page["bmp"] as! String)))
            let maskData = try Data(contentsOf: URL(fileURLWithPath: page["black_bmp"] as! String))
            let mask = [UInt8](maskData); masks.append(maskData)
            require(le(bitmap,18,4)==2048 && le(bitmap,22,4)==1300 && le(bitmap,28,2)==24, "Wrong RGB BMP geometry")
            require(le(bitmap,38,4)==23622 && le(mask,38,4)==23622, "Wrong bitmap physical resolution")
            require(le(mask,10,4)==62 && le(mask,28,2)==1, "K mask lost its explicit 1-bit format")
            let orientation = pdfPage.getDrawingTransform(.cropBox, rect:CGRect(x:0,y:0,width:sourceW,height:sourceH),
                                                         rotate:Int32(page["automatic_rotation"] as! Int), preserveAspectRatio:true)
            let transform = orientation.concatenating(CGAffineTransform(a:scale,b:0,c:0,d:scale,tx:draw[0],ty:draw[1]))
            let marker = fixture.markers[index].applying(transform)
            let centerX = Int(floor(marker.midX)), centerY = Int(floor(marker.midY))
            require(ink(mask,centerX,centerY), "Black vector marker disappeared")
            let columns = (max(0,Int(floor(marker.minX))-2)..<min(2048,Int(ceil(marker.maxX))+2)).filter { ink(mask,$0,centerY) }
            let rows = (max(0,Int(floor(marker.minY))-2)..<min(1300,Int(ceil(marker.maxY))+2)).filter { ink(mask,centerX,$0) }
            require(abs(Double(columns.count)-marker.width)<=1.01 && abs(Double(rows.count)-marker.height)<=1.01, "K marker was stretched, flattened or double-scaled")
            require(rgb(bitmap,centerX,centerY)==[0,0,0], "Source black marker changed color")
            if fixture.cropOffset {
                if mode == "fit" { require(rgb(bitmap,0,0)==[255,255,255], "Crop exterior leaked into fit margin") }
                else { require(zip(rgb(bitmap,0,0),[26,179,230]).allSatisfy { abs($0-$1)<=1 }, "Crop exterior leaked into raster") }
            }
            pageResults.append(["page":index+1,"scale":scale,"rotation":page["rotation"]!,"trim_bleed_preserved":preserved,
                                "marker_measured_pixels":[columns.count,rows.count],"marker_expected_pixels":[marker.width,marker.height]])
        }
        if mode == "none" { baselineMasks=masks }
        if mode == "fill" && fixture.bleed { require(masks==baselineMasks, "Physical-size bleed fill changed K geometry") }
        if masks.count==2 { require(masks[0] != masks[1], "Asymmetric front/back masks were duplicated") }
        geometry.append(["fixture":fixture.name,"mode":mode,"pages":pageResults])
    }
}
}
func queueGate() throws -> [[String: Any]] {
    func checked(_ program: String, _ arguments: [String]) throws -> Data {
        let result = try run(program, arguments)
        guard result.0 == 0 else { throw NSError(domain:"RasterQueue",code:1,userInfo:[NSLocalizedDescriptionKey:program+": "+result.2]) }
        return result.1
    }
    func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain:"RasterQueue",code:1,userInfo:[NSLocalizedDescriptionKey:message]) }
    }
    let queue = "Avansia_Raster_Test_\(ProcessInfo.processInfo.processIdentifier)"
    let uri = "ipp://localhost:18649/ipp/print"
    // A fresh macOS runner can report no destinations or default with exit status 1.
    let beforeQueues = try run("/usr/bin/lpstat", ["-v"])
    let beforeDefault = try run("/usr/bin/lpstat", ["-d"])
    try check(try run("/usr/bin/lpstat", ["-p",queue]).0 != 0,"Refusing to replace an existing test queue")
    let descriptor = Darwin.socket(AF_INET,SOCK_STREAM,0)
    guard descriptor >= 0 else { throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno)) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(18649).bigEndian
    address.sin_addr.s_addr = inet_addr("127.0.0.1")
    let bound = withUnsafePointer(to:&address) { pointer in
        pointer.withMemoryRebound(to:sockaddr.self,capacity:1) { Darwin.bind(descriptor,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    Darwin.close(descriptor)
    try check(bound == 0,"Loopback test port 18649 is already in use")
    let spool = root.appendingPathComponent("spool",isDirectory:true)
    try FileManager.default.createDirectory(at:spool,withIntermediateDirectories:true)
    let conf = root.appendingPathComponent("test-printer.conf")
    let publicConfig = try String(contentsOfFile:CommandLine.arguments[5],encoding:.utf8)
    try publicConfig.write(to:conf,atomically:true,encoding:.utf8)
    let logURL = root.appendingPathComponent("capture-server.log")
    FileManager.default.createFile(atPath:logURL.path,contents:Data())
    let log = try FileHandle(forWritingTo:logURL)
    defer { try? log.close() }
    let server = Process()
    server.executableURL = URL(fileURLWithPath:CommandLine.arguments[4])
    server.arguments = ["-n","localhost","-p","18649","-r","off","--no-web-forms","-a",conf.path,"-f","application/pdf",
                        "-c",CommandLine.arguments[3],"-D","/dev/null","-d",spool.path,"Synthetic Raster Gate"]
    server.standardOutput = log; server.standardError = log
    var created = false
    var jobs = [Int]()
    try queue.write(to:root.deletingLastPathComponent().appendingPathComponent("test-queue-name"),atomically:true,encoding:.utf8)
    try server.run()
    try String(server.processIdentifier).write(to:root.deletingLastPathComponent().appendingPathComponent("test-server-pid"),atomically:true,encoding:.utf8)
    let captures = URL(fileURLWithPath:CommandLine.arguments[3]).deletingLastPathComponent().appendingPathComponent("captures")
    var capturedResults = [[String: Any]]()
    do {
        defer {
            for identifier in jobs { _ = try? run("/usr/bin/cancel",["\(queue)-\(identifier)"]) }
            if created { _ = try? run("/usr/sbin/lpadmin",["-x",queue]) }
            if server.isRunning { server.terminate(); server.waitUntilExit() }
        }
        var ready = false
        for _ in 0..<100 {
            if try run("/usr/bin/ipptool",["-t",uri,"/usr/share/cups/ipptool/get-printer-attributes.test"]).0 == 0 { ready = true; break }
            try check(server.isRunning,"Isolated IPP engine exited")
            Thread.sleep(forTimeInterval:0.1)
        }
        try check(ready,"Isolated IPP engine did not start")
        let capabilityTest=root.appendingPathComponent("capabilities.test")
        try """
        {
          OPERATION Get-Printer-Attributes
          GROUP operation-attributes-tag
          ATTR charset attributes-charset utf-8
          ATTR language attributes-natural-language en
          ATTR uri printer-uri $uri
          ATTR keyword requested-attributes cups-version,print-scaling-supported,print-scaling-default
          STATUS successful-ok
          EXPECT cups-version
          EXPECT print-scaling-supported
        }
        """.write(to:capabilityTest,atomically:true,encoding:.utf8)
        let printerAttributes=String(decoding:try checked("/usr/bin/ipptool",["-tv",uri,capabilityTest.path]),as:UTF8.self)
        let scalingLine=printerAttributes.split(separator:"\n").first { $0.contains("print-scaling-supported (") } ?? ""
        try check(["none","fit","fill"].allSatisfy { scalingLine.contains($0) },"Public configuration does not advertise all tested modes: "+scalingLine)
        let identityLine=printerAttributes.split(separator:"\n").first { $0.contains("cups-version (") } ?? ""
        try check(identityLine.contains("2.4.14"),"Software RIP identity mismatches the pinned CUPS component: "+identityLine)
        _ = try checked("/usr/sbin/lpadmin",["-p",queue,"-E","-v",uri,"-m","everywhere"])
        created = true
        let ppdPath = "/etc/cups/ppd/\(queue).ppd"
        var generated = try String(contentsOfFile:ppdPath,encoding:.utf8)
        if !generated.contains(directDirective) { generated += "\n"+directDirective+"\n" }
        let ppd = root.appendingPathComponent("scheduler-direct.ppd")
        try generated.write(to:ppd,atomically:true,encoding:.utf8)
        _ = try checked("/usr/sbin/lpadmin",["-p",queue,"-P",ppd.path,"-E"])
        for (index,mode) in ["none","fit","fill","selected-pages"].enumerated() {
            let title = "RasterGate-\(index)"
            let scaling = mode == "selected-pages" ? "none" : mode
            let copies = mode == "selected-pages" ? "1" : "2"
            let sides = mode == "selected-pages" ? "one-sided" : "two-sided-long-edge"
            var arguments = ["-d",queue,"-t",title,"-n",copies,"-o","print-scaling="+scaling,"-o","sides="+sides]
            if mode == "selected-pages" { arguments += ["-o","page-ranges=2"] }
            arguments.append(source.path)
            let submission = String(decoding:try checked("/usr/bin/lp",arguments),as:UTF8.self)
            let expression = try NSRegularExpression(pattern:NSRegularExpression.escapedPattern(for:queue)+"-([0-9]+)")
            guard let match = expression.firstMatch(in:submission,range:NSRange(submission.startIndex...,in:submission)),
                  let range = Range(match.range(at:1),in:submission),let identifier = Int(submission[range]) else {
                throw NSError(domain:"RasterQueue",code:1,userInfo:[NSLocalizedDescriptionKey:"Could not read synthetic job identifier"])
            }
            jobs.append(identifier)
            var capture: [String:String]?
            var captureID = ""
            for _ in 0..<300 {
                for file in (try? FileManager.default.contentsOfDirectory(at:captures,includingPropertiesForKeys:nil)) ?? [] where file.pathExtension == "json" {
                    if let data = try? Data(contentsOf:file),let item = try? JSONSerialization.jsonObject(with:data) as? [String:String],item["IPP_JOB_NAME"] == title {
                        capture = item; captureID = file.deletingPathExtension().lastPathComponent; break
                    }
                }
                if capture != nil { break }
                Thread.sleep(forTimeInterval:0.1)
            }
            guard let env = capture else { throw NSError(domain:"RasterQueue",code:1,userInfo:[NSLocalizedDescriptionKey:"Capture command was not invoked for "+mode]) }
            let capturedPDF = try Data(contentsOf:captures.appendingPathComponent(captureID+".pdf"))
            try check(capturedPDF == original,"Native scheduler changed PDF bytes for "+mode)
            try check((env["IPP_PRINT_SCALING"] ?? env["IPP_PRINT_SCALING_DEFAULT"]) == scaling,"Native scheduler lost scaling for "+mode+": explicit="+(env["IPP_PRINT_SCALING"] ?? "absent")+" default="+(env["IPP_PRINT_SCALING_DEFAULT"] ?? "absent"))
            try check((env["IPP_SIDES"] ?? env["IPP_SIDES_DEFAULT"]) == sides,"Native scheduler lost duplex mode")
            try check((env["IPP_COPIES"] ?? env["IPP_COPIES_DEFAULT"]) == copies,"Native scheduler lost copy count")
            if mode == "selected-pages" { try check(["2","2-2"].contains(env["IPP_PAGE_RANGES"] ?? ""),"Native scheduler consumed or lost page ranges") }
            var complete = false
            for _ in 0..<100 {
                let attrs = String(decoding:try checked("/usr/bin/ipptool",["-tv","ipp://localhost:631/jobs/\(identifier)","/usr/share/cups/ipptool/get-job-attributes.test"]),as:UTF8.self)
                if attrs.contains("job-state (enum) = completed") { complete = true; break }
                Thread.sleep(forTimeInterval:0.1)
            }
            try check(complete,"Native synthetic job did not complete")
            capturedResults.append(["mode":mode,"pdf_bytes_identical":true,"copies":env["IPP_COPIES"] ?? env["IPP_COPIES_DEFAULT"] ?? "",
                                    "sides":env["IPP_SIDES"] ?? env["IPP_SIDES_DEFAULT"] ?? "",
                                    "print_scaling":env["IPP_PRINT_SCALING"] ?? env["IPP_PRINT_SCALING_DEFAULT"] ?? "",
                                    "explicit_print_scaling":env["IPP_PRINT_SCALING"] ?? "",
                                    "default_print_scaling":env["IPP_PRINT_SCALING_DEFAULT"] ?? "",
                                    "page_ranges":env["IPP_PAGE_RANGES"] ?? "","job_completed":true])
        }
    }
    let afterQueues = try run("/usr/bin/lpstat",["-v"])
    let afterDefault = try run("/usr/bin/lpstat",["-d"])
    try check(afterQueues.0 == beforeQueues.0 && afterQueues.1 == beforeQueues.1 && afterQueues.2 == beforeQueues.2,"Existing printer snapshot changed")
    try check(afterDefault.0 == beforeDefault.0 && afterDefault.1 == beforeDefault.1 && afterDefault.2 == beforeDefault.2,"Default printer snapshot changed")
    try check(try run("/usr/bin/lpstat",["-p",queue]).0 != 0,"Synthetic queue remains")
    try? FileManager.default.removeItem(at:root.deletingLastPathComponent().appendingPathComponent("test-queue-name"))
    try? FileManager.default.removeItem(at:root.deletingLastPathComponent().appendingPathComponent("test-server-pid"))
    return capturedResults
}
let scheduler = try queueGate()

let report: [String: Any] = ["local_scheduler":localScheduler,"direct_pdf_ppd_directive":directDirective,"forwarding_strategy":"CUPS 2.4.14 software RIP metadata; no mandatory optional-job fields","direct_route":routes,"native_scheduler_capture":scheduler,
                            "negative_control_filter":String(decoding:oldRoute.1,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines),
                            "geometry":geometry,"geometry_cases":geometry.count,"geometry_checks_reused_from_prior_checkpoint":queueOnly,
                            "limits":"Native software scheduler and raster checks only; no physical transport or card acceptance.",
                            "only_ephemeral_test_queue_created_and_removed":true,"existing_queue_uris_and_default_unchanged":true,"usb_access":false,"physical_print":false]
FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]))
FileHandle.standardOutput.write(Data([10]))
