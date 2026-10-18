import Foundation
import CoreFoundation
import Darwin

struct DeviceAccessFailure:Error,CustomStringConvertible {
    let connection:String, description:String
}
struct SettingFailure:Error,CustomStringConvertible {
    let description:String, writeAttempted:Bool, refreshRequired:Bool
}
func deviceISO(_ date:Date) -> String { ISO8601DateFormatter().string(from:date) }
func devicePercent(_ value:Any?) -> Any {
    guard let value=value as? Int, (0...100).contains(value) else { return NSNull() }
    return value
}
func deviceIPPLine(_ snapshot:[String:Any]) -> String {
    let states:Set<String>=["ready","busy","recovery","disconnected","error","unknown"]
    let state=snapshot["connection"] as? String ?? "unknown"
    func percent(_ name:String) -> Int {
        let object=snapshot[name] as? [String:Any]
        return devicePercent(object?["remaining_percent"]) as? Int ?? -1
    }
    return "AVANSIA_STATUS_V1 \(states.contains(state) ? state : "unknown") \(percent("ribbon")) \(percent("film"))"
}
func deviceQueueOutput(_ arguments:[String]) throws -> String {
    let process=Process(), pipe=Pipe()
    process.executableURL=URL(fileURLWithPath:"/usr/bin/lpstat")
    process.arguments=arguments
    process.standardOutput=pipe; process.standardError=pipe
    try process.run()
    let data=pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
    try require(process.terminationStatus==0,"Cannot inspect the local print queue")
    return String(decoding:data,as:UTF8.self)
}
func deviceQueuePending(run:([String]) throws -> String) throws -> Bool {
    try run(["-h","/private/var/run/cupsd","-W","not-completed","-o"]).split(separator:"\n").contains{$0.hasPrefix("Evolis_Avansia-")}
}
func deviceQueuePending() throws -> Bool {
    try deviceQueuePending(run:deviceQueueOutput)
}
func openMonitoredDevice() throws -> DeviceTransport {
    do { return try USB() }
    catch {
        let message=String(describing:error)
        let state=message.contains("Another process is using") ? "busy" : message.contains("not found or could not be opened") || message.contains("USB read failed: -4;") ? "disconnected" : "error"
        throw DeviceAccessFailure(connection:state,description:message)
    }
}
final class DeviceStore {
    let state:URL
    init(_ base:URL) { state=base.appendingPathComponent("state") }
    func read(_ name:String) -> [String:Any] {
        guard let file=try? FileHandle(forReadingFrom:state.appendingPathComponent(name)) else { return [:] }
        defer { try? file.close() }
        guard let data=try? file.read(upToCount:1048577), data.count<=1048576,
              let object=try? JSONSerialization.jsonObject(with:data) as? [String:Any] else { return [:] }
        return object
    }
    func update(_ name:String,_ body:(inout [String:Any]) throws -> Void) throws -> [String:Any] {
        try FileManager.default.createDirectory(at:state,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let lock=open(state.appendingPathComponent("cache.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        try require(lock>=0,"Cannot open the status cache lock")
        defer { close(lock) }
        try require(flock(lock,LOCK_EX)==0,"Cannot lock the status cache")
        var object=read(name); try body(&object)
        try JSONSerialization.data(withJSONObject:object,options:.sortedKeys).write(to:state.appendingPathComponent(name),options:.atomic)
        try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:state.appendingPathComponent(name).path)
        return object
    }
    var settingUncertain:Bool { FileManager.default.fileExists(atPath:state.appendingPathComponent("setting-uncertain.json").path) }
    func journal(_ object:[String:Any]) throws {
        _=try update("setting-uncertain.json"){$0=object}
        let file=open(state.appendingPathComponent("setting-uncertain.json").path,O_RDONLY|O_NOFOLLOW)
        try require(file>=0,"Cannot persist setting uncertainty state"); defer { close(file) }
        try require(fsync(file)==0,"Cannot persist setting uncertainty state")
        let directory=open(state.path,O_RDONLY)
        try require(directory>=0,"Cannot persist state directory"); defer { close(directory) }
        try require(fsync(directory)==0,"Cannot persist state directory")
    }
    func clearSettingUncertain() throws {
        if settingUncertain { try FileManager.default.removeItem(at:state.appendingPathComponent("setting-uncertain.json")) }
    }
}
final class DeviceManager {
    let base:URL, store:DeviceStore
    let factory:() throws -> DeviceTransport, pending:() throws -> Bool, clock:() -> Date
    init(base:URL=FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/AvansiaDriver"),
         factory:@escaping () throws -> DeviceTransport=openMonitoredDevice,
         pending:@escaping () throws -> Bool=deviceQueuePending,clock:@escaping () -> Date=Date.init) {
        self.base=base;store=DeviceStore(base);self.factory=factory;self.pending=pending;self.clock=clock
    }
    func queue() throws -> [String:Any] {
        let files=FileManager.default
        let recovery=files.fileExists(atPath:base.appendingPathComponent("state/inflight.json").path)
        let active=files.fileExists(atPath:base.appendingPathComponent("spool/active-job.ipp").path)
        // Markers are decisive even if CUPS is temporarily unavailable.
        if active || recovery { return ["active_job":active,"recovery_required":recovery] }
        return ["active_job":try pending(),"recovery_required":false]
    }
    func idle() throws -> [String:Any] {
        let current=try queue()
        try require(current["active_job"] as? Bool==false && current["recovery_required"] as? Bool==false,"A pending, active or uncertain card prevents device access")
        return current
    }
    func ready(_ state:[String:Any]) throws {
        try require(state["ready"] as? Bool==true && state["printing"] as? Bool==false && state["error"] as? Bool==false && state["mechanical_busy"] as? Bool != true && state["interface_busy"] as? Bool != true,"The printer must be Ready, idle and error-free")
    }
    func reconcileSetting(_ state:[String:Any],_ discovery:MenuDiscovery) throws -> [String:Any]? {
        guard store.settingUncertain else { return nil }
        let journal=store.read("setting-uncertain.json")
        func integer(_ value:Any?) -> Int? {
            guard let number=value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  !["f","d"].contains(String(cString:number.objCType)) else { return nil }
            return Int(exactly:number.int64Value)
        }
        guard Set(journal.keys)==["id","serial","expected","target","started_at"],
              let id=journal["id"] as? String, SettingRule.all.contains(where:{$0.id==id}),
              let serial=journal["serial"] as? String, !serial.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              let expected=integer(journal["expected"]), let target=integer(journal["target"]),
              (-32768...32767).contains(expected), (-32768...32767).contains(target),
              let started=journal["started_at"] as? String, ISO8601DateFormatter().date(from:started) != nil else {
            throw Failure("Setting uncertainty journal is malformed; it was retained")
        }
        guard let observedSerial=state["serial"] as? String, !observedSerial.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              observedSerial==serial else { throw Failure("Reconnect the journaled printer and refresh settings; uncertainty was retained") }
        let matches=discovery.settings.filter { item in
            guard let rule=item.rule else { return false }
            return rule.id==id && rule.matches(item.descriptor,item.group)
        }
        try require(matches.count==1,"The journaled setting is not uniquely observable; uncertainty was retained")
        let current=matches[0].descriptor.current
        let resolution:[String:Any]=["id":id,"serial":serial,"expected_before":expected,"requested_value":target,
                                     "resolved_current":current,"matches_requested_value":current==target,
                                     "observed_at":deviceISO(clock()),"method":"explicit-fresh-settings-read"]
        _=try store.update("setting-resolution.json"){$0=resolution}
        try store.clearSettingUncertain()
        return resolution
    }
    func connection(_ state:[String:Any]) -> String {
        if state["error"] as? Bool==true { return "error" }
        return state["ready"] as? Bool==true && state["printing"] as? Bool==false && state["mechanical_busy"] as? Bool != true && state["interface_busy"] as? Bool != true ? "ready" : "busy"
    }
    func updateStatus(_ hardware:[String:Any]?,connection:String?,stale:Bool,queue:[String:Any],error:String?=nil,details:MenuDiscovery?=nil,ribbonIdentity:[String:Any]?=nil,settingResolution:[String:Any]?=nil) throws -> [String:Any] {
        try store.update("status.json") { value in
            value["schema_version"]=1; value["updated_at"]=deviceISO(clock()); value["queue"]=queue
            value["stale"]=stale; value["settings_refresh_required"]=store.settingUncertain
            value["error"]=error
            if value["observed_at"]==nil { value["observed_at"]=NSNull() }
            if value["device"]==nil { value["device"]=[String:Any]() }
            if value["accessories"]==nil { value["accessories"]=[[String:Any]]() }
            var ribbon=value["ribbon"] as? [String:Any] ?? [:], film=value["film"] as? [String:Any] ?? [:]
            if let hardware {
                let old=value["device"] as? [String:Any] ?? [:]
                if (hardware["serial"] as? String ?? "").isEmpty || old["serial"] as? String != hardware["serial"] as? String {
                    ribbon=[:];film=[:];value["accessories"]=[[String:Any]]()
                    value["information"]=[[String:Any]]();value["details_observed_at"]=NSNull();value["setting_resolution"]=NSNull()
                }
                var device=hardware
                if old["serial"] as? String==hardware["serial"] as? String { device["total_count"]=old["total_count"] }
                value["device"]=device;value["observed_at"]=deviceISO(clock())
                ribbon["remaining_percent"]=devicePercent(hardware["ribbon_remaining_percent"])
                film["remaining_percent"]=devicePercent(hardware["film_remaining_percent"])
            }
            if ribbon["remaining_percent"]==nil { ribbon["remaining_percent"]=NSNull() }
            if film["remaining_percent"]==nil { film["remaining_percent"]=NSNull() }
            if let identity=ribbonIdentity, let device=value["device"] as? [String:Any], !(device["serial"] as? String ?? "").isEmpty {
                ribbon["reference"]=identity["code"];ribbon["label"]=identity["label"];ribbon["region"]=identity["zone"]
                ribbon["identity_observed_at"]=deviceISO(clock())
            }
            if let details {
                value["information"]=details.information;value["details_observed_at"]=deviceISO(clock())
                var device=value["device"] as? [String:Any] ?? [:]
                for item in details.information {
                    if item["label"] as? String=="Total Count",let text=item["value"] as? String,let count=Int(text),count>=0 { device["total_count"]=count }
                    if item["label"] as? String=="Film Type" { film["type"]=item["value"] }
                }
                value["device"]=device
                if let setting=details.settings.first(where:{$0.rule?.id=="ribbon.film-type"}) {
                    film["type"]=setting.descriptor.choices.first(where:{$0["value"] as? Int==setting.descriptor.current})?["label"]
                }
                let names=["Magnetic Encoder":"magnetic-encoder","Chip port #1":"chip-port-1","Chip port #2":"chip-port-2","External Box":"external-box"]
                value["accessories"]=details.information.compactMap { item -> [String:Any]? in
                    guard let label=item["label"] as? String, let id=names[label], let text=item["value"] as? String else { return nil }
                    let status=text=="DISCONNECTED" ? "disconnected" : text=="CONNECTED" ? "connected" : "unknown"
                    return ["id":id,"name":label,"status":status,"display":text]
                }
            }
            if let settingResolution { value["setting_resolution"]=settingResolution }
            value["ribbon"]=ribbon;value["film"]=film
            value["connection"]=connection ?? "unknown"
        }
    }
    func snapshot(refreshDetails:Bool=false) throws -> [String:Any] {
        var current:[String:Any]=["active_job":false,"recovery_required":false]
        do {
            current=try queue()
            if current["recovery_required"] as? Bool==true || current["active_job"] as? Bool==true {
                return try updateStatus(nil,connection:current["recovery_required"] as? Bool==true ? "recovery" : "busy",stale:true,queue:current)
            }
            let transport=try factory(); _=try idle()
            let hardware=try transport.status()
            var details:MenuDiscovery?, identity:[String:Any]?, detailError:String?, resolution:[String:Any]?
            if refreshDetails {
                do {
                    try ready(hardware); _=try idle()
                    details=try DeviceMenu(transport).discover()
                    _=try idle();let fresh=try transport.status();try ready(fresh)
                    try require(fresh["serial"] as? String==hardware["serial"] as? String,"Printer changed during detail refresh")
                    let ribbon=try transport.ribbonStatus();identity=ribbon["ribbon"] as? [String:Any]
                    resolution=try reconcileSetting(fresh,details!)
                } catch let error as DeviceAccessFailure { throw error }
                catch { detailError=String(describing:error) }
            }
            return try updateStatus(hardware,connection:connection(hardware),stale:false,queue:current,error:detailError,details:details,ribbonIdentity:identity,settingResolution:resolution)
        } catch {
            let latest=(try? queue()) ?? current
            let message=String(describing:error)
            let failure=(error as? DeviceAccessFailure)?.connection ?? (message.contains("USB read failed: -4;") || message.contains("USB write failed: -4;") ? "disconnected" : message.contains("USB") || message.contains("response") ? "error" : "unknown")
            let state=latest["recovery_required"] as? Bool==true ? "recovery" : latest["active_job"] as? Bool==true ? "busy" : failure
            return try updateStatus(nil,connection:state,stale:true,queue:latest,error:String(describing:error))
        }
    }
    func settings() throws -> [String:Any] {
        do {
            let queue=try idle(), transport=try factory(); _=try idle()
            let state=try transport.status();try ready(state)
            let discovery=try DeviceMenu(transport).discover()
            var resolution:[String:Any]?
            if store.settingUncertain {
                let fresh=try transport.status();try ready(fresh)
                try require(fresh["serial"] as? String==state["serial"] as? String,"Printer changed during settings refresh")
                resolution=try reconcileSetting(fresh,discovery)
            }
            let value:[String:Any]=["schema_version":1,"updated_at":deviceISO(clock()),"observed_at":deviceISO(clock()),"stale":false,"device_serial":state["serial"] ?? NSNull(),"queue":queue,"settings":discovery.settings.map{$0.json},"information":discovery.information,"reconciled_setting":resolution ?? NSNull(),"settings_refresh_required":store.settingUncertain]
            _=try store.update("settings.json"){$0=value}
            _=try updateStatus(state,connection:connection(state),stale:false,queue:queue,details:discovery,settingResolution:resolution)
            return value
        } catch {
            var cached=store.read("settings.json")
            cached["schema_version"]=1;cached["updated_at"]=deviceISO(clock());cached["stale"]=true;cached["error"]=String(describing:error)
            cached["settings_refresh_required"]=store.settingUncertain
            cached["queue"]=(try? queue()) ?? ["active_job":false,"recovery_required":false]
            cached["observed_at"]=cached["observed_at"] ?? NSNull();cached["device_serial"]=cached["device_serial"] ?? NSNull()
            cached["information"]=cached["information"] ?? [[String:Any]]()
            cached["settings"]=(cached["settings"] as? [[String:Any]] ?? []).map { item in var item=item;item["writable"]=false;return item }
            return cached
        }
    }
    func setSetting(_ id:String,expected:Int,value:Int,expectedSerial:String) throws -> [String:Any] {
        var attempted=false
        do {
            try require(!expectedSerial.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,"Expected printer serial is required")
            try require(SettingRule.all.contains{$0.id==id},"Unknown or read-only logical setting ID")
            try require(!store.settingUncertain,"Refresh settings explicitly before another write")
            _=try idle();let transport=try factory();_=try idle()
            try require(!store.settingUncertain,"Refresh settings explicitly before another write")
            let state=try transport.status();try ready(state)
            try require(state["serial"] as? String==expectedSerial,"Printer identity differs from the observed settings; refresh settings before applying")
            let menu=DeviceMenu(transport), discovery=try menu.discover()
            let matches=discovery.settings.filter{$0.rule?.id==id}
            try require(matches.count==1,"Requested writable setting is unavailable")
            let result=try menu.set(matches[0],expected:expected,value:value,beforeWrite:{
                _=try self.idle()
                try require(!self.store.settingUncertain,"Refresh settings explicitly before another write")
                let fresh=try transport.status();try self.ready(fresh)
                try require(fresh["serial"] as? String==expectedSerial,"Printer changed during setting discovery")
            },willWrite:{ _ in
                try self.store.journal(["id":id,"serial":state["serial"] ?? NSNull(),"expected":expected,"target":value,"started_at":deviceISO(self.clock())])
                attempted=true
            })
            if attempted { try store.clearSettingUncertain() }
            _=try? store.update("settings.json") { cache in cache["stale"]=true;cache["updated_at"]=deviceISO(clock()) }
            return result
        } catch { throw SettingFailure(description:String(describing:error),writeAttempted:attempted,refreshRequired:attempted || store.settingUncertain) }
    }
}
