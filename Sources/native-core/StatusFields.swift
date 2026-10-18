import Foundation

func decodeDeviceStatus(_ info:[UInt8],_ status:[UInt8]) throws -> [String:Any] {
    try require(info.count>=51 && status.count>=60,"Printer information response is incomplete")
    let flags=status[0]
    func ascii(_ range:Range<Int>) -> String { String(bytes:info[range],encoding:.ascii)?.trimmingCharacters(in:.whitespacesAndNewlines) ?? "" }
    // Byte offsets follow avansia_status_info2_t in the native vendor header.
    // Its three-byte print counter has no documented encoding; retain raw bytes.
    return ["model":"Evolis Avansia","firmware":ascii(38..<42),"base_revision":ascii(34..<38),"serial":ascii(42..<50),
            "printer_id":info[50],"ribbon_type_code":info[2],"ribbon_panel_code":info[3],
            "ribbon_remaining_percent":devicePercent(Int(status[42])),"film_remaining_percent":devicePercent(Int(status[43])),
            "ready":flags&0x11==0x11 && flags&4==0,"printing":flags&8 != 0,"error":flags&4 != 0,"mechanical_busy":flags&2 != 0,"interface_busy":flags&32 != 0,"flags":String(format:"%02x",flags),
            "card_position":Int(status[1]),"printer_status":Int(status[2]),"encoder_status_raw":Int(status[3]),
            "memory_status_raw":hex(Array(status[4..<6])),"data_status_raw":hex(Array(status[6..<8])),"option_unit_status_raw":Int(status[8]),
            "total_print_number_raw":hex(Array(status[9..<12])),"color_control_raw":hex(Array(status[12..<15])),
            "magnetic_encoder_rom":menuText(status[15..<19]),"heat_roller_rom":menuText(status[19..<23]),"standby_status":Int(status[41]),"status_payload":hex(status)]
}
