import Foundation

protocol DeviceTransport: AnyObject {
    func write(_ data:[UInt8],timeout:UInt32) throws
    func read(_ size:Int,timeout:UInt32) throws -> [UInt8]
    func status() throws -> [String:Any]
    func ribbonStatus() throws -> [String:Any]
}
extension USB: DeviceTransport {}

func menuText(_ bytes:ArraySlice<UInt8>) -> String {
    String(bytes:bytes,encoding:.ascii)?.trimmingCharacters(in:CharacterSet.whitespacesAndNewlines.union(.controlCharacters)) ?? ""
}
func menuSigned(_ bytes:[UInt8],_ offset:Int) -> Int { Int(Int16(bitPattern:UInt16(bytes[offset])<<8|UInt16(bytes[offset+1]))) }
struct MenuDescriptor {
    let selector:[UInt8], bytes:[UInt8]
    var label:String { menuText(bytes[4..<20]) }
    var type:Int { Int(bytes[20]) }
    var minimum:Int { menuSigned(bytes,21) }
    var maximum:Int { menuSigned(bytes,23) }
    var current:Int { menuSigned(bytes,25) }
    var display:String { menuText(bytes.dropFirst(27)) }
    init(selector:[UInt8],bytes:[UInt8]) throws {
        try require(selector.count==8 && selector.contains(where:{$0 != 0}) && (27...1870).contains(bytes.count),"Invalid menu descriptor bounds")
        if bytes[20]==1 || bytes[20]==2 { try require((bytes.count-27)%20==0,"Malformed menu children") }
        if [UInt8(3),4,6].contains(bytes[20]) {
            let minimum=menuSigned(bytes,21), maximum=menuSigned(bytes,23), current=menuSigned(bytes,25)
            try require(minimum<=maximum && (minimum...maximum).contains(current),"Invalid numeric menu range or current value")
            if bytes[20]==6 { try require(bytes.count==27,"Malformed scalar descriptor") }
            else { try require(maximum-minimum<(1870-27)/16 && bytes.count==27+(maximum-minimum+1)*16,"Malformed choice descriptor") }
        }
        self.selector=selector; self.bytes=bytes
    }
    var children:[(String,[UInt8])] {
        guard type==1 || type==2 else { return [] }
        return stride(from:27,to:bytes.count,by:20).map { offset in
            (menuText(bytes[offset..<offset+16]),Array(bytes[offset+16..<offset+20])+[0,0,0,0])
        }
    }
    func child(_ labels:[String]) throws -> [UInt8]? {
        let matches=children.filter{labels.contains($0.0)}
        try require(matches.count<=1,"Ambiguous menu child label")
        return matches.first?.1
    }
    var choices:[[String:Any]] {
        guard type==3 || type==4, maximum>=minimum, maximum-minimum<(1870-27)/16,
              bytes.count==27+(maximum-minimum+1)*16 else { return [] }
        return (minimum...maximum).map { value in
            let offset=27+(value-minimum)*16
            return ["value":value,"label":menuText(bytes[offset..<offset+16])]
        }
    }
}
struct SettingRule {
    let id:String, group:String, label:String, type:Int
    static let all:[SettingRule] = {
        var rules:[SettingRule]=[]
        func add(_ group:String,_ type:Int,_ values:[(String,String)]) { rules += values.map{SettingRule(id:$0.0,group:group,label:$0.1,type:type)} }
        add("Printer Setup",4,[("printer.buzzer","Buzzer")])
        add("Printer Setup",3,[("printer.power-save-mode","Power Save Mode")])
        add("Printer Setup",6,[("printer.power-save-time","Power Save Time"),("printer.vertical-offset","Vertical Offset"),("printer.horizontal-offset","Horiz. Offset")])
        add("Image Setup",6,[("image.sharpness","Sharpness"),("image.yellow-balance","Yellow Balance"),("image.magenta-balance","Magenta Balance"),("image.cyan-balance","Cyan Balance"),("image.black-balance","Black Balance"),("image.color-shift-vertical","Color Shift Vtc"),("image.black-shift-horizontal","Black Shift Hrz"),("image.yellow-shift-front","Y Shift Hrz-F"),("image.magenta-shift-front","M Shift Hrz-F"),("image.cyan-shift-front","C Shift Hrz-F"),("image.yellow-shift-back","Y Shift Hrz-B"),("image.magenta-shift-back","M Shift Hrz-B"),("image.cyan-shift-back","C Shift Hrz-B")])
        add("Image Setup",4,[("image.color-shift-horizontal","Color Shift Hrz")])
        add("Ribbon Setup",3,[("ribbon.film-type","Film Type")])
        add("Ribbon Setup",6,[("ribbon.ribbon-warning-percent","Ribn near end(%)"),("ribbon.film-warning-percent","Film near end(%)")])
        add("Card Setup",3,[("card.type","Card Type"),("card.normal-exit","Std card exit"),("card.error-exit","Err card exit"),("card.side","Set card side"),("card.eject-side","Card eject side")])
        add("Card Setup",6,[("card.decurl-front","Decurl (Front)"),("card.decurl-back","Decurl (Back)")])
        for n in 1...3 {
            add("Heater Setup",3,[("heater.card\(n)-speed","CARD\(n) Heat Speed")])
            add("Heater Setup",6,[("heater.card\(n)-temperature","CARD\(n) Heat Temp.")])
        }
        add("Service/Printer Setup",3,[("service.black-quality","Print Quality Bk")])
        return rules
    }()
    func matches(_ menu:MenuDescriptor,_ group:String) -> Bool {
        let labelMatches=label==menu.label || (id=="service.black-quality" && menu.label=="Print Quality BK")
        guard self.group==group && labelMatches && type==menu.type && menu.current>=menu.minimum && menu.current<=menu.maximum else { return false }
        if type==6 { return menu.bytes.count==27 }
        guard !menu.choices.isEmpty else { return false }
        if id=="service.black-quality" {
            return menu.minimum==0 && menu.maximum==1 && menu.choices.compactMap{$0["label"] as? String}==["HIGH SPEED","HIGH QUALITY"]
        }
        return true
    }
}
struct DiscoveredSetting {
    let descriptor:MenuDescriptor, group:String, rule:SettingRule?, ordinal:Int
    var json:[String:Any] {
        ["id":rule?.id ?? "readonly.\(ordinal)","label":descriptor.label,"group":group,
         "type":descriptor.type==6 ? "scalar" : (descriptor.type==3 || descriptor.type==4) ? "choice" : "unknown",
         "descriptor_type":descriptor.type,"current":descriptor.current,"minimum":descriptor.minimum,"maximum":descriptor.maximum,
         "choices":descriptor.choices,"writable":rule != nil]
    }
}
struct MenuDiscovery {
    var settings:[DiscoveredSetting]=[]
    var information:[[String:Any]]=[]
}
final class DeviceMenu {
    let transport:DeviceTransport
    init(_ transport:DeviceTransport) { self.transport=transport }
    func get(_ selector:[UInt8]) throws -> MenuDescriptor {
        try require(selector.count==8 && selector.contains(where:{$0 != 0}),"Zero or malformed menu selector rejected")
        func request(_ opcode:UInt8,_ length:Int,_ count:Int) throws -> [UInt8] {
            try transport.write([28,opcode,0,0,0,10]+selector+[UInt8(length>>8),UInt8(length&255)],timeout:5000)
            let header=try transport.read(6,timeout:5000)
            guard header==[28,opcode]+be32(count) else { throw DeviceAccessFailure(connection:"error",description:"Invalid menu response header") }
            let payload=try transport.read(count,timeout:5000)
            guard payload.count==count else { throw DeviceAccessFailure(connection:"error",description:"Truncated menu response") }
            return payload
        }
        let size=try request(0x4d,2,2), count=Int(size[0])<<8|Int(size[1])
        try require((27...1870).contains(count),"Menu response exceeds descriptor bounds")
        return try MenuDescriptor(selector:selector,bytes:request(0x4e,count,count))
    }
    func root(_ name:String,_ mode:String) throws -> MenuDescriptor? {
        let menu=try get([0,0,0,0]+Array(name.utf8))
        guard menu.type==1, let selector=try menu.child([mode]) else { return nil }
        let child=try get(selector)
        try require(child.label==mode && child.type==2,"Menu root identity mismatch")
        return child
    }
    func discover() throws -> MenuDiscovery {
        var result=MenuDiscovery(), visited=Set<String>(), count=0
        func visit(_ menu:MenuDescriptor,_ group:String,_ depth:Int) throws {
            try require(depth<=8 && count<96,"USER menu discovery bound exceeded")
            let key=hex(menu.selector)
            if visited.contains(key) { return }; visited.insert(key); count+=1
            if menu.type==2 {
                for (_,selector) in menu.children {
                    guard selector.contains(where:{$0 != 0}) else { continue }
                    if visited.contains(hex(selector)) { continue }
                    try require(depth<8 && count<96,"USER menu discovery bound exceeded")
                    try visit(get(selector),menu.label,depth+1)
                }
            } else if menu.type==5 || menu.type==7 {
                result.information.append(["label":menu.label,"group":group,"value":menu.display])
            } else {
                let rule=SettingRule.all.first{$0.matches(menu,group)}
                if let rule { try require(!result.settings.contains{$0.rule?.id==rule.id},"Duplicate logical setting identity") }
                result.settings.append(DiscoveredSetting(descriptor:menu,group:group,rule:rule,ordinal:result.settings.count))
            }
        }
        guard let user=try root("USER","User Mode") else { throw DeviceMetadataUnavailable(description:"USER menu root is unavailable") }
        try visit(user,"",0)
        if let service=try root("SERV","Service Mode"), let setupSelector=try service.child(["Printer Setup"]) {
            let setup=try get(setupSelector)
            try require(setup.label=="Printer Setup" && setup.type==2,"Service printer-setup identity mismatch")
            if let selector=try setup.child(["Print Quality Bk","Print Quality BK"]) {
                let quality=try get(selector), group="Service/Printer Setup"
                result.settings.append(DiscoveredSetting(descriptor:quality,group:group,rule:SettingRule.all.first{$0.matches(quality,group)},ordinal:result.settings.count))
            }
        }
        return result
    }
    func set(_ setting:DiscoveredSetting,expected:Int,value:Int,beforeWrite:() throws -> Void,willWrite:([UInt8]) throws -> Void) throws -> [String:Any] {
        guard let rule=setting.rule else { throw Failure("Setting is read-only") }
        let fresh=try get(setting.descriptor.selector)
        try require(rule.matches(fresh,setting.group) && Array(fresh.bytes.prefix(25))==Array(setting.descriptor.bytes.prefix(25)) && fresh.bytes.dropFirst(27)==setting.descriptor.bytes.dropFirst(27),"Fresh setting identity/type/range/choices changed")
        try require(fresh.current==expected,"Setting current value differs from expected value")
        try require((fresh.minimum...fresh.maximum).contains(value),"Setting value is outside the discovered range")
        if rule.type==3 || rule.type==4 { try require(fresh.choices.contains{$0["value"] as? Int==value},"Setting choice is unavailable") }
        if fresh.current==value { return ["id":rule.id,"changed":false,"current":value,"write_attempted":false] }
        var header=Array(fresh.bytes.prefix(27)); let encoded=UInt16(bitPattern:Int16(value))
        header[25]=UInt8(encoded>>8); header[26]=UInt8(encoded&255)
        try beforeWrite(); try willWrite(header)
        try transport.write([28,0x4f,0,0,0,27]+header,timeout:5000)
        try require(try transport.read(6,timeout:5000)==[28,0x4f,0,0,0,0],"Setting write acknowledgement failed; refresh settings before another attempt")
        let readback=try get(fresh.selector)
        try require(Array(readback.bytes.prefix(27))==header && readback.bytes.dropFirst(27)==fresh.bytes.dropFirst(27),"Setting readback differs; refresh settings before another attempt")
        return ["id":rule.id,"changed":true,"current":value,"write_attempted":true,"readback_verified":true]
    }
}
