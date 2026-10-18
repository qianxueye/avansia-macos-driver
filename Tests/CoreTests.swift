import Foundation

func coreCheck(_ condition:@autoclosure () throws -> Bool,_ message:String) throws { try require(try condition(),"Test failed: "+message) }
func coreReject(_ body:() throws -> Void) throws {
    var rejected=false;do { try body() } catch { rejected=true }
    try coreCheck(rejected,"Expected rejection")
}
func syntheticMenu(_ id:UInt8,_ label:String,_ type:UInt8,_ minimum:Int=0,_ maximum:Int=0,_ current:Int=0,extra:[UInt8]=[]) -> [UInt8] {
    var bytes=[UInt8](repeating:0,count:27);bytes[0]=id
    let text=Array(label.utf8);bytes.replaceSubrange(4..<20,with:Array(text.prefix(16))+[UInt8](repeating:32,count:max(0,16-text.count)))
    bytes[20]=type
    for (offset,value) in [(21,minimum),(23,maximum),(25,current)] { let word=UInt16(bitPattern:Int16(value));bytes[offset]=UInt8(word>>8);bytes[offset+1]=UInt8(word&255) }
    return bytes+extra
}
func syntheticChild(_ label:String,_ id:UInt8) -> [UInt8] { Array(label.utf8)+[UInt8](repeating:32,count:16-label.utf8.count)+[id,0,0,0] }
func syntheticChoice(_ name:String) -> [UInt8] { Array(name.utf8)+[UInt8](repeating:32,count:16-name.utf8.count) }
final class SyntheticDevice:DeviceTransport {
    var state:[String:Any]=["serial":"SYN00001","ready":true,"printing":false,"error":false,"flags":"11","ribbon_remaining_percent":91,"film_remaining_percent":255]
    var nodes:[String:[UInt8]]=[:], replies:[[UInt8]]=[], writes:[[UInt8]]=[]
    var statusCalls=0, ribbonCalls=0, failWrite=false, badACK=false, ignoreWrite=false, wrongHeader=false
    var beforeStatus:(() -> Void)?
    init() {
        nodes["USER"]=syntheticMenu(1,"",1,extra:syntheticChild("User Mode",2))
        nodes["SERV"]=syntheticMenu(11,"",1,extra:syntheticChild("User Mode",2)+syntheticChild("Service Mode",12))
        nodes["2"]=syntheticMenu(2,"User Mode",2,extra:syntheticChild("Image Setup",3)+syntheticChild("Version",5)+syntheticChild("Printer Info.",7))
        nodes["3"]=syntheticMenu(3,"Image Setup",2,extra:syntheticChild("Sharpness",4)+syntheticChild("Unsafe Action",9))
        nodes["4"]=syntheticMenu(4,"Sharpness",6,-2,2,0)
        nodes["9"]=syntheticMenu(9,"Unsafe Action",9)
        nodes["5"]=syntheticMenu(5,"Version",2,extra:syntheticChild("Magnetic Encoder",6))
        nodes["6"]=syntheticMenu(6,"Magnetic Encoder",5,extra:syntheticChoice("DISCONNECTED"))
        nodes["7"]=syntheticMenu(7,"Printer Info.",2,extra:syntheticChild("Total Count",8))
        nodes["8"]=syntheticMenu(8,"Total Count",5,extra:syntheticChoice("1234"))
        nodes["12"]=syntheticMenu(12,"Service Mode",2,extra:syntheticChild("Action Check",19)+syntheticChild("Printer Setup",13))
        nodes["13"]=syntheticMenu(13,"Printer Setup",2,extra:syntheticChild("Print Quality Bk",14))
        nodes["14"]=syntheticMenu(14,"Print Quality Bk",3,0,1,1,extra:syntheticChoice("HIGH SPEED")+syntheticChoice("HIGH QUALITY"))
    }
    func write(_ data:[UInt8],timeout:UInt32) throws {
        writes.append(data)
        if data[1]==0x4f {
            if failWrite { throw Failure("Injected partial write") }
            try coreCheck(data.count==33 && Array(data.prefix(6))==[28,79,0,0,0,27],"One exact O header")
            let key=String(data[6]);guard var value=nodes[key] else { throw Failure("Unknown write ID") }
            try coreCheck(Array(data[6..<31])==Array(value.prefix(25)),"Only current bytes may change")
            if !ignoreWrite { value[25]=data[31];value[26]=data[32];nodes[key]=value }
            replies.append(badACK ? [28,0x15,0,0,0,0] : [28,79,0,0,0,0]);return
        }
        try coreCheck(data.count==16 && [UInt8(0x4d),0x4e].contains(data[1]),"Only M/N/O protocol requests")
        let selector=Array(data[6..<14])
        let key=selector[0]==0 ? String(bytes:selector[4..<8],encoding:.ascii)! : String(selector[0])
        guard let value=nodes[key] else { throw Failure("Unknown synthetic selector "+key) }
        if data[1]==0x4d { replies += [[28,0x4d,0,0,0,2],[UInt8(value.count>>8),UInt8(value.count&255)]] }
        else { replies += [[28,wrongHeader ? 0x15 : 0x4e]+be32(value.count),value] }
    }
    func read(_ size:Int,timeout:UInt32) throws -> [UInt8] {
        try coreCheck(!replies.isEmpty,"Missing response")
        let value=replies.removeFirst();try coreCheck(value.count==size,"Response bounds")
        return value
    }
    func status() throws -> [String:Any] { statusCalls+=1;beforeStatus?();return state }
    func ribbonStatus() throws -> [String:Any] { ribbonCalls+=1;return ["ribbon":["code":"TEST-RIBBON","label":"Synthetic YMCK","zone":"TEST"]] }
    var writeCount:Int { writes.filter{$0[1]==0x4f}.count }
}
@main struct CoreTests {
    static func main() throws {
        let temporary=FileManager.default.temporaryDirectory.appendingPathComponent("avansia-core-tests-"+UUID().uuidString)
        try FileManager.default.createDirectory(at:temporary,withIntermediateDirectories:false)
        defer { try? FileManager.default.removeItem(at:temporary) }
        let fake=SyntheticDevice(), base=temporary.appendingPathComponent("driver")
        var now=Date(timeIntervalSince1970:1000), opens=0, pending=false
        let manager=DeviceManager(base:base,factory:{opens+=1;return fake},pending:{pending},clock:{now})
        let first=try manager.snapshot()
        try coreCheck(fake.statusCalls==1 && fake.ribbonCalls==0 && fake.writes.isEmpty,"Cheap poll must not enter RFID/menu")
        try coreCheck(first["connection"] as? String=="ready" && first["stale"] as? Bool==false,"Fresh state")
        try coreCheck(deviceIPPLine(first)=="AVANSIA_STATUS_V1 ready 91 -1","IPP four-token protocol and unknown film")
        let observed=first["observed_at"] as! String
        now=Date(timeIntervalSince1970:1010)
        pending=true;let active=try manager.snapshot();pending=false
        try coreCheck(active["connection"] as? String=="busy" && active["observed_at"] as? String==observed && opens==1,"Pending queue defers USB")
        let marker=base.appendingPathComponent("state/inflight.json");try Data().write(to:marker)
        let recovery=try manager.snapshot();try FileManager.default.removeItem(at:marker)
        try coreCheck(recovery["connection"] as? String=="recovery" && opens==1,"Uncertain card defers USB")
        let busy=DeviceManager(base:base,factory:{throw DeviceAccessFailure(connection:"busy",description:"Shared mutex busy")},pending:{false},clock:{now})
        let deferred=try busy.snapshot()
        try coreCheck(deferred["connection"] as? String=="busy" && deferred["observed_at"] as? String==observed,"Busy mutex is not disconnection")
        let lost=DeviceManager(base:base,factory:{throw DeviceAccessFailure(connection:"disconnected",description:"Unavailable")},pending:{false},clock:{now})
        try coreCheck(try lost.snapshot()["stale"] as? Bool==true,"Disconnect keeps stale cache")
        let empty=DeviceManager(base:temporary.appendingPathComponent("empty"),factory:{throw DeviceAccessFailure(connection:"disconnected",description:"Unavailable")},pending:{false})
        let unknown=try empty.snapshot()
        try coreCheck(unknown["observed_at"] is NSNull && deviceIPPLine(unknown)=="AVANSIA_STATUS_V1 disconnected -1 -1","Unobserved status must not invent supply zeros")
        let detailed=try manager.snapshot(refreshDetails:true)
        try coreCheck(fake.ribbonCalls==1,"Only explicit detail refresh uses RFID")
        let accessories=detailed["accessories"] as! [[String:Any]]
        try coreCheck(accessories.count==1 && accessories[0]["status"] as? String=="disconnected","Accessory comes from observed display field")
        try coreCheck((detailed["device"] as! [String:Any])["total_count"] as? Int==1234,"Numeric total comes from USER display")
        _=try manager.snapshot()
        try coreCheck((manager.store.read("status.json")["device"] as! [String:Any])["total_count"] as? Int==1234,"Cheap status retains cached detail total")
        fake.state["serial"]="SYN00002"
        let replaced=try manager.snapshot()
        try coreCheck((replaced["ribbon"] as! [String:Any])["reference"]==nil && (replaced["accessories"] as! [[String:Any]]).isEmpty,"Printer change invalidates identity")
        fake.state["mechanical_busy"]=true
        let menuReads=fake.writes.count, rfidReads=fake.ribbonCalls
        let busyHardware=try manager.snapshot(refreshDetails:true)
        try coreCheck(busyHardware["connection"] as? String=="busy" && fake.writes.count==menuReads && fake.ribbonCalls==rfidReads,"Busy hardware prevents menu/RFID refresh")
        fake.state["mechanical_busy"]=false
        let settings=try manager.settings(), entries=settings["settings"] as! [[String:Any]]
        try coreCheck(entries.first{$0["id"] as? String=="image.sharpness"}?["writable"] as? Bool==true,"Typed USER setting discovered")
        try coreCheck(entries.first{$0["id"] as? String=="service.black-quality"}?["current"] as? Int==1,"SERV chooses Service Mode, not User Mode")
        try coreCheck(!fake.writes.contains{Array($0[6..<14]).first==19},"Action Check sibling must never be traversed")
        try coreCheck(entries.filter{$0["writable"] as? Bool==true}.count==2,"Unknown/actions are read-only")
        let before=fake.writeCount
        let unchanged=try manager.setSetting("image.sharpness",expected:0,value:0)
        try coreCheck(unchanged["changed"] as? Bool==false && fake.writeCount==before,"No-op must not send O")
        let changed=try manager.setSetting("image.sharpness",expected:0,value:-2)
        try coreCheck(changed["readback_verified"] as? Bool==true && fake.writeCount==before+1 && !manager.store.settingUncertain,"Write once and verify exact readback")
        try coreCheck(Array(fake.writes.last(where:{$0[1]==0x4f})!.suffix(2))==[255,254],"Signed current encoding")
        try coreReject{_=try manager.setSetting("image.sharpness",expected:0,value:1)}
        try coreReject{_=try manager.setSetting("image.sharpness",expected:-2,value:3)}
        try coreReject{_=try manager.setSetting("raw.01020304",expected:0,value:1)}
        let afterRejections=fake.writeCount
        fake.badACK=true
        try coreReject{_=try manager.setSetting("image.sharpness",expected:-2,value:1)}
        try coreCheck(fake.writeCount==afterRejections+1 && manager.store.settingUncertain,"ACK failure must preserve uncertainty guard")
        try coreReject{_=try manager.setSetting("image.sharpness",expected:1,value:0)}
        try coreCheck(fake.writeCount==afterRejections+1,"Uncertain write cannot be retried")
        fake.badACK=false;_=try manager.settings()
        try coreCheck(!manager.store.settingUncertain,"Explicit fresh settings read clears guard")
        fake.ignoreWrite=true
        try coreReject{_=try manager.setSetting("image.sharpness",expected:1,value:0)}
        try coreCheck(manager.store.settingUncertain,"Readback mismatch keeps guard")
        fake.ignoreWrite=false;_=try manager.settings()
        fake.failWrite=true
        try coreReject{_=try manager.setSetting("image.sharpness",expected:1,value:0)}
        try coreCheck(manager.store.settingUncertain,"Partial write keeps guard, no rollback")
        fake.failWrite=false;_=try manager.settings()
        fake.nodes["14"]=syntheticMenu(14,"Print Quality Bk",3,0,1,1,extra:syntheticChoice("OTHER")+syntheticChoice("UNKNOWN"))
        let altered=try manager.settings()["settings"] as! [[String:Any]]
        try coreCheck(!altered.contains{$0["id"] as? String=="service.black-quality"},"Unexpected SERV choices are not writable")
        try coreReject{_=try DeviceMenu(fake).get([UInt8](repeating:0,count:8))}
        try coreReject{_=try MenuDescriptor(selector:[1,0,0,0,0,0,0,0],bytes:[UInt8](repeating:0,count:26))}
        try coreReject{_=try MenuDescriptor(selector:[1,0,0,0,0,0,0,0],bytes:syntheticMenu(1,"Group",2,extra:[1]))}
        for offset in [0,4,20,23] {
            let changed=SyntheticDevice(), menu=DeviceMenu(changed)
            let setting=try menu.discover().settings.first{$0.rule?.id=="image.sharpness"}!
            changed.nodes["4"]![offset]^=1
            try coreReject{_=try menu.set(setting,expected:0,value:1,beforeWrite:{},willWrite:{_ in})}
            try coreCheck(changed.writeCount==0,"Fresh descriptor mutation must stop before O")
        }
        let late=SyntheticDevice()
        let lateManager=DeviceManager(base:temporary.appendingPathComponent("late-queue"),factory:{late},pending:{!late.writes.isEmpty})
        try coreReject{_=try lateManager.setSetting("image.sharpness",expected:0,value:1)}
        try coreCheck(late.writeCount==0,"A queue arriving during discovery must prevent O")
        let swapped=SyntheticDevice()
        swapped.beforeStatus={ if swapped.statusCalls==2 { swapped.state["serial"]="SYN99999" } }
        let swapManager=DeviceManager(base:temporary.appendingPathComponent("swapped"),factory:{swapped},pending:{false})
        try coreReject{_=try swapManager.setSetting("image.sharpness",expected:0,value:1)}
        try coreCheck(swapped.writeCount==0,"Printer identity change must prevent O")
        try coreReject{_=try MenuDescriptor(selector:[1,0,0,0,0,0,0,0],bytes:syntheticMenu(1,"Bad scalar",6,3,2,2))}
        try coreReject{_=try MenuDescriptor(selector:[1,0,0,0,0,0,0,0],bytes:syntheticMenu(1,"Bad choice",3,0,1,0))}
        func uncertainFixture(_ name:String,_ device:SyntheticDevice) throws -> DeviceManager {
            let manager=DeviceManager(base:temporary.appendingPathComponent(name),factory:{device},pending:{false},clock:{now})
            try manager.store.journal(["id":"image.sharpness","serial":"SYN00001","expected":0,"target":1,"started_at":deviceISO(now)])
            return manager
        }
        let manual=SyntheticDevice();manual.nodes["4"]=syntheticMenu(4,"Sharpness",6,-2,2,-2)
        let manualManager=try uncertainFixture("manual-resolution",manual)
        _=try manualManager.snapshot()
        try coreCheck(manualManager.store.settingUncertain && manual.writes.isEmpty,"Cheap refresh must not reconcile uncertainty")
        let resolved=try manualManager.settings()
        let resolution=resolved["reconciled_setting"] as! [String:Any]
        try coreCheck(!manualManager.store.settingUncertain && resolution["resolved_current"] as? Int == -2 && resolution["matches_requested_value"] as? Bool==false,"Fresh same-device observation resolves a manual third value without claiming target success")
        try coreCheck(manualManager.store.read("setting-resolution.json")["resolved_current"] as? Int == -2 && manual.writeCount==0,"Resolution records current and never writes O")
        for serial in ["SYN00002",""] {
            let replacement=SyntheticDevice();replacement.state["serial"]=serial
            let replacementManager=try uncertainFixture("replacement-"+serial,replacement)
            let journalURL=replacementManager.store.state.appendingPathComponent("setting-uncertain.json")
            let before=try Data(contentsOf:journalURL)
            _=try replacementManager.settings();_=try replacementManager.snapshot(refreshDetails:true)
            try coreCheck(replacementManager.store.settingUncertain && Data(contentsOf:journalURL)==before && replacement.writeCount==0,"Replacement/empty serial must retain uncertainty in both explicit refresh paths")
        }
        let absent=SyntheticDevice();absent.nodes["3"]=syntheticMenu(3,"Image Setup",2,extra:syntheticChild("Unsafe Action",9))
        let absentManager=try uncertainFixture("absent-setting",absent)
        _=try absentManager.settings();_=try absentManager.snapshot(refreshDetails:true)
        try coreCheck(absentManager.store.settingUncertain,"Missing journaled setting cannot reconcile")
        let duplicate=SyntheticDevice()
        duplicate.nodes["3"]=syntheticMenu(3,"Image Setup",2,extra:syntheticChild("Sharpness",4)+syntheticChild("Sharpness",15))
        duplicate.nodes["15"]=syntheticMenu(15,"Sharpness",6,-2,2,0)
        let duplicateManager=try uncertainFixture("duplicate-setting",duplicate)
        _=try duplicateManager.settings()
        try coreCheck(duplicateManager.store.settingUncertain,"Ambiguous logical setting cannot reconcile")
        let descriptor=try MenuDescriptor(selector:[4,0,0,0,0,0,0,0],bytes:syntheticMenu(4,"Sharpness",6,-2,2,0))
        let rule=SettingRule.all.first{$0.id=="image.sharpness"}!
        let duplicateDiscovery=MenuDiscovery(settings:[DiscoveredSetting(descriptor:descriptor,group:"Image Setup",rule:rule,ordinal:0),DiscoveredSetting(descriptor:descriptor,group:"Image Setup",rule:rule,ordinal:1)])
        try coreReject{_=try duplicateManager.reconcileSetting(duplicate.state,duplicateDiscovery)}
        try coreCheck(duplicateManager.store.settingUncertain,"Reconciliation itself must enforce uniqueness")
        let malformedJournals:[Data]=[Data("{".utf8),try JSONSerialization.data(withJSONObject:["id":"image.sharpness"]),try JSONSerialization.data(withJSONObject:["id":"image.sharpness","serial":"SYN00001","expected":false,"target":1,"started_at":deviceISO(now)])]
        for (index,journal) in malformedJournals.enumerated() {
            let device=SyntheticDevice(), manager=try uncertainFixture("malformed-journal-\(index)",device)
            let url=manager.store.state.appendingPathComponent("setting-uncertain.json")
            try journal.write(to:url)
            _=try manager.settings();_=try manager.snapshot(refreshDetails:true)
            try coreCheck(manager.store.settingUncertain && Data(contentsOf:url)==journal && device.writeCount==0,"Malformed journal must be retained without mutation")
        }
        let detailsDevice=SyntheticDevice(), detailsManager=try uncertainFixture("details-resolution",detailsDevice)
        let detailResolution=try detailsManager.snapshot(refreshDetails:true)
        try coreCheck(!detailsManager.store.settingUncertain && (detailResolution["setting_resolution"] as? [String:Any])?["resolved_current"] as? Int==0,"Explicit detail refresh reconciles only its observed journaled setting")
        let waitingDevice=SyntheticDevice(), waitingBase=temporary.appendingPathComponent("late-journal")
        let waitingStore=DeviceStore(waitingBase)
        let waiting=DeviceManager(base:waitingBase,factory:{
            try waitingStore.journal(["id":"image.sharpness","serial":"SYN00001","expected":0,"target":1,"started_at":deviceISO(now)])
            return waitingDevice
        },pending:{false})
        do { _=try waiting.setSetting("image.sharpness",expected:0,value:1);throw Failure("Late journal was accepted") }
        catch let error as SettingFailure { try coreCheck(!error.writeAttempted && error.refreshRequired,"Late journal must report refresh required without a write attempt") }
        try coreCheck(waitingDevice.writes.isEmpty && waitingDevice.statusCalls==0 && waitingStore.settingUncertain,"Post-lock uncertainty check must stop before device observation or O")
        let malformed=SyntheticDevice();malformed.wrongHeader=true
        try coreReject{_=try DeviceMenu(malformed).discover()}
        let cycle=SyntheticDevice();cycle.nodes["3"]=syntheticMenu(3,"Image Setup",2,extra:syntheticChild("User Mode",2))
        _=try DeviceMenu(cycle).discover()
        try coreCheck(cycle.writes.count<30,"Menu cycle must remain bounded")
        var info=[UInt8](repeating:32,count:52), bytes=[UInt8](repeating:0,count:60)
        info.replaceSubrange(42..<50,with:Array("SYN00003".utf8));bytes[0]=0x11;bytes[1]=7;bytes[9]=1;bytes[10]=2;bytes[11]=3;bytes[42]=255;bytes[43]=100
        let decoded=try decodeDeviceStatus(info,bytes)
        try coreCheck(decoded["total_print_number_raw"] as? String=="010203" && decoded["total_count"]==nil,"Counter encoding must not be guessed")
        try coreCheck(decoded["ribbon_remaining_percent"] is NSNull && decoded["film_remaining_percent"] as? Int==100 && decoded["card_position"] as? Int==7,"Vendor-header offsets and unknown percent")
        try coreReject{_=try decodeDeviceStatus(info,[0])}
        try coreCheck(deviceIPPLine(["connection":"bad\nvalue","ribbon":["remaining_percent":0],"film":["remaining_percent":101]])=="AVANSIA_STATUS_V1 unknown 0 -1","IPP output tokens are bounded")
        print("PASS: synthetic Core monitoring/cache/menu/settings/ACK/readback/uncertainty/header/IPP tests; no hardware access")
    }
}
