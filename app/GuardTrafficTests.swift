import Foundation

// Synthetic packets only: no capture from a real session is ever committed.

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAIL line \(line): \(message)") }
}

/// Writes what WireReader reads.
private struct Wire {
    var bytes: [UInt8] = []
    mutating func u8(_ v: Int) { bytes.append(UInt8(v)) }
    mutating func u16(_ v: Int) { bytes += [UInt8(v >> 8 & 255), UInt8(v & 255)] }
    mutating func u32(_ v: UInt32) { bytes += [24, 16, 8, 0].map { UInt8(v >> $0 & 255) } }
    mutating func i32(_ v: Int) { u32(UInt32(bitPattern: Int32(v))) }
    mutating func f32(_ v: Float) { u32(v.bitPattern) }
    mutating func bool(_ v: Bool) { u8(v ? 1 : 0) }
    mutating func string(_ s: String) { let b = Array(s.utf8); u16(b.count); bytes += b }
    mutating func compact(_ v: Int) {
        var n = abs(v), first = UInt8(n & 63) | (v < 0 ? 64 : 0)
        n >>= 6
        if n > 0 { first |= 128 }
        bytes.append(first)
        while n > 0 { var b = UInt8(n & 127); n >>= 7; if n > 0 { b |= 128 }; bytes.append(b) }
    }
    mutating func status(_ id: Int, _ x: Float, _ y: Float, _ stats: [(Int, Int, String?)]) {
        compact(id); f32(x); f32(y); compact(stats.count)
        for (t, v, text) in stats {
            u8(t)
            if let text { string(text) } else { compact(v) }
            compact(0)
        }
    }
}

private func update(_ objects: [(type: Int, id: Int, x: Float, y: Float, stats: [(Int, Int, String?)])], drops: [Int] = []) -> [UInt8] {
    var w = Wire()
    w.f32(0); w.f32(0); w.u8(0)
    w.compact(1); w.u16(3); w.u16(4); w.u16(5)   // one tile
    w.compact(objects.count)
    for o in objects { w.u16(o.type); w.status(o.id, o.x, o.y, o.stats) }
    w.compact(drops.count)
    for d in drops { w.compact(d) }
    return w.bytes
}
private func newTick(_ statuses: [(id: Int, x: Float, y: Float, stats: [(Int, Int, String?)])] = []) -> [UInt8] {
    var w = Wire()
    w.i32(1); w.i32(200); w.u32(0); w.u16(0); w.u16(statuses.count)
    for s in statuses { w.status(s.id, s.x, s.y, s.stats) }
    return w.bytes
}
private func mapInfo(_ name: String, modifiers: String = "TAMEMINIONS_2;|D") -> [UInt8] {
    var w = Wire()
    w.i32(256); w.i32(512); w.string(name); w.string("{d}"); w.string("realm")
    w.i32(777); w.i32(3); w.f32(1); w.bool(true); w.bool(false); w.bool(true)
    w.u16(85); w.i32(1234); w.string("v1"); w.u16(0); w.u16(15); w.bool(false); w.i32(9); w.string(modifiers)
    w.u16(0)
    return w.bytes
}
private func createSuccess(_ id: Int) -> [UInt8] { var w = Wire(); w.i32(id); w.i32(1); w.string("x"); return w.bytes }
private func damage(target: Int, amount: Int, attacker: Int) -> [UInt8] {
    var w = Wire(); w.i32(target); w.u8(1); w.u8(4); w.u16(amount); w.bool(false); w.u16(2); w.i32(attacker); return w.bytes
}
private func enemyHit(_ target: Int) -> [UInt8] {
    var w = Wire(); w.i32(5); w.u16(7); w.i32(100); w.i32(target); w.bool(false); w.i32(100); return w.bytes
}

/// Frames and encrypts messages as the server would, one cipher across them all.
private func frames(_ messages: [(UInt8, [UInt8])], outgoing: Bool = false) -> [UInt8] {
    var cipher = RC4(key: outgoing ? RC4.outgoing : RC4.incoming), out: [UInt8] = []
    for (type, payload) in messages {
        var body = payload
        cipher.apply(&body)
        let size = UInt32(body.count + 5)
        out += [24, 16, 8, 0].map { UInt8(size >> $0 & 255) } + [type] + body
    }
    return out
}

enum TrafficTests {
    static func run() {
        // Compact ints both ways, including several bytes and the sign bit.
        for v in [0, 1, 63, 64, -1, -63, 8191, 123_456, -987_654] {
            var w = Wire(); w.compact(v)
            var r = WireReader(w.bytes)
            check(r.compact() == v && r.remaining == 0, "compact \(v)")
        }
        var short = WireReader([0x80])
        check(short.compact() == nil, "a compact int cut short is nil")

        // RC4: the published test vector (key "Key", plaintext "Plaintext").
        var rc4 = RC4(key: Array("Key".utf8)), plain = Array("Plaintext".utf8)
        rc4.apply(&plain)
        check(plain == RC4.hex("bbf316e8d940af0ad3"), "RC4 test vector")

        // Framing: out-of-order segments, a message split over segments, two messages in one.
        let stream = frames([(TrafficPacket.ID.createSuccess, createSuccess(100)), (TrafficPacket.ID.mapInfo, mapInfo("Nexus"))])
        var flow = TrafficFlow(outgoing: false)
        flow.syn(seq: 999)
        let cut = 7
        var got = flow.segment(seq: 1000 + UInt32(cut), payload: Array(stream[cut...]))
        check(got.isEmpty, "nothing until the hole fills")
        got = flow.segment(seq: 1000, payload: Array(stream[..<cut]))
        check(got.count == 2 && got[0].type == TrafficPacket.ID.createSuccess, "both messages once in order")
        check(TrafficPacket.parse(type: got[0].type, payload: got[0].payload, outgoing: false) == .createSuccess(objectID: 100), "decrypted")
        if case let .mapInfo(m)? = TrafficPacket.parse(type: got[1].type, payload: got[1].payload, outgoing: false) {
            check(m.name == "Nexus" && m.seed == 777 && m.modifiers == "TAMEMINIONS_2;|D" && m.width == 256, "map info fields")
        } else { check(false, "map info parses") }
        // A retransmitted segment changes nothing.
        check(flow.segment(seq: 1000, payload: Array(stream[..<cut])).isEmpty && flow.broken == nil, "retransmit ignored")

        var late = TrafficFlow(outgoing: false)
        _ = late.segment(seq: 5, payload: [1, 2, 3])
        check(late.broken == "mid_stream", "a connection without its SYN is broken")
        var bad = TrafficFlow(outgoing: false)
        bad.syn(seq: 0)
        _ = bad.segment(seq: 1, payload: [0, 0, 0, 2, 9])
        check(bad.broken == "bad_frame", "a size under the header is broken")

        // Outgoing hits and every stat kind.
        check(TrafficPacket.parse(type: TrafficPacket.ID.enemyHit, payload: enemyHit(42), outgoing: true) == .enemyHit(target: 42), "enemy hit")
        var w = Wire(); w.status(7, 1.5, 2.5, [(0, 5000, nil), (80, 0, "a,b,c,d,e"), (31, 0, "")])
        var r = WireReader(w.bytes)
        let s = TrafficPacket.status(&r)
        check(s?.stats == [TrafficStat(type: 0, value: 5000, text: nil), TrafficStat(type: 80, value: 0, text: "a,b,c,d,e"),
                           TrafficStat(type: 31, value: 0, text: "")] && r.remaining == 0, "stats by kind")

        loot()
    }

    static func loot() {
        var lines: [String] = []
        let loot = TrafficLoot(portals: [1900]) { lines.append($0) }
        loot.projectile = { object, from, to in object == 50 && from == 10 && to == 20 ? (300, 25) : (0, 0) }
        func feed(_ type: UInt8, _ payload: [UInt8], _ time: Double, outgoing: Bool = false) {
            guard let p = TrafficPacket.parse(type: type, payload: payload, outgoing: outgoing) else { return check(false, "parse \(type)") }
            loot.handle(p, time: time)
        }
        typealias ID = TrafficPacket.ID
        func kinds(_ kind: String) -> [[String]] {
            lines.filter { $0.hasPrefix(kind + "\t") }.map { $0.dropLast().split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
        }

        // Map 1: you arrive, the map is named with its info; your stats once each.
        feed(ID.mapInfo, mapInfo("Realm\tof"), 9)
        feed(ID.createSuccess, createSuccess(100), 10)
        feed(ID.update, update([(type: 782, id: 100, x: 1, y: 1, stats: [(0, 700, nil), (1, 650, nil), (31, 0, "Wizard")])]), 10)
        check(kinds("map").first == ["map", "10.000", "1", "Realm of"], "map line with its tab cleaned")
        check(kinds("map_info").first?[3...] == ["782", "85", "777", "3", "1234", "9", "256", "512", "realm", "v1", "TAMEMINIONS_2;|D"], "map info columns")
        check(kinds("player_stat").map { $0[3] } == ["0", "31"], "HP left out, max HP and text kept")
        feed(ID.newTick, newTick([(id: 100, x: 1, y: 1, stats: [(0, 700, nil), (80, 0, "a,b,c,d,e")])]), 10.1)
        check(kinds("player_stat").count == 3 && kinds("player_stat").last?[5] == "a,b,c,d", "repeat skipped, stat 80 cut to 4 parts")

        // A mob takes your shot, your ability and someone's damage, then leaves: a kill, held for the hits file.
        feed(ID.update, update([(type: 3000, id: 50, x: 5, y: 5, stats: [(0, 1000, nil)]), (type: 3001, id: 51, x: 40, y: 40, stats: [])]), 11)
        feed(ID.enemyHit, enemyHit(50), 12, outgoing: true)
        feed(ID.damage, damage(target: 50, amount: 80, attacker: 100), 13)
        feed(ID.damage, damage(target: 50, amount: 90, attacker: 7), 14)
        feed(ID.damage, damage(target: 51, amount: 0, attacker: 7), 14)   // no damage: not a hit
        feed(ID.newTick, newTick([(id: 50, x: 6, y: 5, stats: [])]), 19)
        // The server sends the bag (and a portal) the tick before it removes the mob that dropped it.
        feed(ID.update, update([(type: 1287, id: 60, x: 6, y: 5, stats: [(8, 2591, nil), (9, -1, nil), (80, 0, "AAIE_f_9__3__f8=")]),
                                (type: 1900, id: 61, x: 6, y: 6, stats: [])]), 19.5)
        feed(ID.newTick, newTick(), 19.8)
        check(kinds("drop").isEmpty, "bags wait one tick")
        feed(ID.update, update([], drops: [50, 51]), 20)
        check(kinds("kill").isEmpty, "a kill waits for the hits file")
        feed(ID.newTick, newTick(), 20.4)
        let kill = kinds("kill")
        check(kill.count == 1 && kill[0][3...] == ["50", "3000", "6.00", "5.00", "0.00", "300", "25", "80", "1000", "removed", "6000", "90"],
              "kill with your damage by source, max HP, time since the last hit and others' damage: \(kill)")
        check(kinds("bag").first?[7...8] == ["2591", "-1"] && kinds("bag").first?.count == 15, "bag items")
        check(kinds("bag_stat").first?[4...] == ["80", "0", "AAIE_f_9__3__f8="], "bag text stat")
        check(kinds("portal").first?[3...4] == ["61", "1900"], "portal")
        check(kinds("drop").map { [$0[3], $0[4]] } == [["60", "50"], ["61", "50"]], "bag and portal go to the kill")

        // A second sighting of the same bag is not a new bag.
        feed(ID.update, update([(type: 1287, id: 60, x: 6, y: 5, stats: [])]), 21)
        check(kinds("bag").count == 1, "bag once per map")

        // Map 2: a new id; object ids start over, so last map's 50 is not this map's 50.
        feed(ID.mapInfo, mapInfo("Nexus"), 30)
        feed(ID.createSuccess, createSuccess(200), 30)
        feed(ID.update, update([(type: 782, id: 200, x: 1, y: 1, stats: [(0, 700, nil)])]), 30)
        check(kinds("map").last?[2...] == ["2", "Nexus"], "second map")
        check(kinds("player_stat").last?[3...4] == ["0", "700"], "stats again on a new map")
        feed(ID.update, update([(type: 1287, id: 60, x: 0, y: 0, stats: [])]), 31)
        check(kinds("bag").count == 2, "an id seen last map is new here")
        feed(ID.update, update([], drops: [50]), 32)
        loot.flush(now: 100, all: true)
        check(kinds("kill").count == 1 && loot.kills == 1, "an object never hit this map is no kill")
        print("Traffic decoder tests passed")
    }
}
