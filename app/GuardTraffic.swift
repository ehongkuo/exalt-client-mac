import Foundation

/// Drop-rate capture from game traffic (issue #61). Decodes the game's TCP stream the way RealmHound does and
/// writes the same loot lines the guard's hooks wrote (guard/loot_core.h has the columns), so the importer and the
/// Drop rates views don't change. Pure: bytes in, lines out. GuardCapture.swift feeds it packets.
///
/// Ported from RealmHound (MIT, Copyright (c) pillarzz, github.com/pillarzz/RealmHound at 38d853f): the RC4 keys
/// (crypto/keys.rs), the framing (stream/reassembler.rs), the packet layouts (protocol/), and the loot rules
/// (loot/detection.rs, loot/tracker.rs). Your own shots carry no damage in traffic, so the guard's damage hook
/// still sends those; `TrafficLoot.projectile` joins them to each kill.

/// Big-endian reader for one packet's payload; every read returns nil past the end.
struct WireReader {
    let bytes: [UInt8]
    var at = 0
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    var remaining: Int { bytes.count - at }
    mutating func u8() -> UInt8? { guard at < bytes.count else { return nil }; defer { at += 1 }; return bytes[at] }
    mutating func bool() -> Bool? { u8().map { $0 != 0 } }
    mutating func u16() -> UInt16? {
        guard remaining >= 2 else { return nil }
        defer { at += 2 }
        return UInt16(bytes[at]) << 8 | UInt16(bytes[at + 1])
    }
    mutating func i16() -> Int16? { u16().map { Int16(bitPattern: $0) } }
    mutating func u32() -> UInt32? {
        guard remaining >= 4 else { return nil }
        defer { at += 4 }
        return bytes[at..<at + 4].reduce(0) { $0 << 8 | UInt32($1) }
    }
    mutating func i32() -> Int32? { u32().map { Int32(bitPattern: $0) } }
    mutating func f32() -> Float? { u32().map { Float(bitPattern: $0) } }
    mutating func string() -> String? {
        guard let n = u16().map(Int.init), remaining >= n else { return nil }
        defer { at += n }
        return String(decoding: bytes[at..<at + n], as: UTF8.self)
    }
    /// 6 bits in the first byte (bit 6 the sign), then 7 per byte while the top bit is set.
    mutating func compact() -> Int? {
        guard let first = u8() else { return nil }
        var value = Int(first & 63), shift = 6, byte = first
        while byte & 128 != 0 {
            guard shift < 32, let next = u8() else { return nil }
            byte = next
            value |= Int(byte & 127) << shift
            shift += 7
        }
        return first & 64 != 0 ? -value : value
    }
    mutating func count(max: Int = 65536) -> Int? { compact().flatMap { $0 >= 0 && $0 <= max ? $0 : nil } }
}

struct TrafficStat: Equatable { var type: Int, value: Int, text: String? }
struct TrafficStatus: Equatable { var id: Int, x: Float, y: Float, stats: [TrafficStat] }
struct TrafficMapInfo: Equatable {
    var name = "", displayName = "", realmName = "", version = "", modifiers = ""
    var width = 0, height = 0, seed = 0, background = 0, maxPlayers = 0, opened = 0, unknown = 0
}

enum TrafficPacket: Equatable {
    case update(objects: [(type: Int, status: TrafficStatus)], drops: [Int])
    case newTick(statuses: [TrafficStatus])
    case mapInfo(TrafficMapInfo)
    case createSuccess(objectID: Int)
    case damage(target: Int, amount: Int, attacker: Int)
    case enemyHit(target: Int)   // outgoing: your shot hit target

    static func == (a: TrafficPacket, b: TrafficPacket) -> Bool {
        switch (a, b) {
        case let (.update(o1, d1), .update(o2, d2)):
            return d1 == d2 && o1.count == o2.count && zip(o1, o2).allSatisfy { $0.type == $1.type && $0.status == $1.status }
        case let (.newTick(s1), .newTick(s2)): return s1 == s2
        case let (.mapInfo(m1), .mapInfo(m2)): return m1 == m2
        case let (.createSuccess(i1), .createSuccess(i2)): return i1 == i2
        case let (.damage(t1, a1, b1), .damage(t2, a2, b2)): return t1 == t2 && a1 == a2 && b1 == b2
        case let (.enemyHit(t1), .enemyHit(t2)): return t1 == t2
        default: return false
        }
    }

    /// Message ids (RealmHound's protocol/packet_type.rs). Server to client, then client to server.
    enum ID {
        static let newTick: UInt8 = 10, update: UInt8 = 42, damage: UInt8 = 75, mapInfo: UInt8 = 92, createSuccess: UInt8 = 101
        static let enemyHit: UInt8 = 25
    }
    /// Stats sent as text, everything else as a compact int (RealmHound's StatType::is_string_stat).
    static let textStats: Set<Int> = [6, 31, 38, 54, 62, 71, 72, 78, 80, 82, 115, 121, 127, 128, 147, 155]

    /// Whether the loot rules read this packet, so a nil from `parse` means its layout changed.
    static func reads(type: UInt8, outgoing: Bool) -> Bool {
        outgoing ? type == ID.enemyHit : [ID.newTick, ID.update, ID.damage, ID.mapInfo, ID.createSuccess].contains(type)
    }

    /// The packets the loot rules read; nil for every other one, or one that doesn't parse.
    static func parse(type: UInt8, payload: [UInt8], outgoing: Bool) -> TrafficPacket? {
        var r = WireReader(payload)
        if outgoing {
            guard type == ID.enemyHit, r.i32() != nil, r.i16() != nil, r.i32() != nil, let target = r.i32(),
                  r.bool() != nil, r.i32() != nil, r.remaining == 0 else { return nil }
            return .enemyHit(target: Int(target))
        }
        switch type {
        case ID.update:
            guard r.f32() != nil, r.f32() != nil, r.u8() != nil, let tiles = r.count() else { return nil }
            for _ in 0..<tiles { guard r.i16() != nil, r.i16() != nil, r.u16() != nil else { return nil } }
            guard let n = r.count() else { return nil }
            var objects: [(type: Int, status: TrafficStatus)] = []
            for _ in 0..<n {
                guard let t = r.u16(), let s = status(&r) else { return nil }
                objects.append((Int(t), s))
            }
            guard let d = r.count() else { return nil }
            var drops: [Int] = []
            for _ in 0..<d { guard let id = r.compact() else { return nil }; drops.append(id) }
            return r.remaining == 0 ? .update(objects: objects, drops: drops) : nil   // no optional tail: extra bytes mean a new layout
        case ID.newTick:
            guard r.i32() != nil, r.i32() != nil, r.u32() != nil, r.u16() != nil, let n = r.i16(), (0...1000).contains(n) else { return nil }
            var statuses: [TrafficStatus] = []
            for _ in 0..<n { guard let s = status(&r) else { return nil }; statuses.append(s) }
            return .newTick(statuses: statuses)
        case ID.mapInfo:
            var m = TrafficMapInfo()
            guard let w = r.i32(), let h = r.i32(), let name = r.string(), let display = r.string(), let realm = r.string(),
                  let seed = r.i32(), let background = r.i32(), r.f32() != nil, r.bool() != nil, r.bool() != nil, r.bool() != nil,
                  let players = r.i16(), let opened = r.i32(), let version = r.string(), r.i16() != nil, r.i16() != nil,
                  r.bool() != nil, let unknown = r.i32(), let modifiers = r.string() else { return nil }
            (m.width, m.height, m.name, m.displayName, m.realmName) = (Int(w), Int(h), name, display, realm)
            (m.seed, m.background, m.maxPlayers, m.opened, m.version) = (Int(seed), Int(background), Int(players), Int(opened), version)
            (m.unknown, m.modifiers) = (Int(unknown), modifiers)
            return .mapInfo(m)
        case ID.createSuccess:
            return r.i32().map { .createSuccess(objectID: Int($0)) }
        case ID.damage:
            guard let target = r.i32(), let effects = r.u8() else { return nil }
            for _ in 0..<effects { guard r.u8() != nil else { return nil } }
            guard let amount = r.u16(), r.bool() != nil, r.u16() != nil, let attacker = r.i32() else { return nil }
            return .damage(target: Int(target), amount: Int(amount), attacker: Int(attacker))
        default: return nil
        }
    }

    static func status(_ r: inout WireReader) -> TrafficStatus? {
        guard let id = r.compact(), let x = r.f32(), let y = r.f32(), let n = r.count(max: 1024) else { return nil }
        var stats: [TrafficStat] = []
        for _ in 0..<n {
            guard let t = r.u8().map(Int.init) else { return nil }
            if textStats.contains(t) {
                guard let text = r.string(), r.compact() != nil else { return nil }
                stats.append(TrafficStat(type: t, value: 0, text: text))
            } else {
                guard let v = r.compact(), r.compact() != nil else { return nil }
                stats.append(TrafficStat(type: t, value: v, text: nil))
            }
        }
        return TrafficStatus(id: id, x: x, y: y, stats: stats)
    }
}

struct RC4 {
    private var s = [UInt8](0...255), i: UInt8 = 0, j: UInt8 = 0
    init(key: [UInt8]) {
        var j = 0
        for i in 0..<256 { j = (j + Int(s[i]) + Int(key[i % key.count])) & 255; s.swapAt(i, j) }
    }
    mutating func apply(_ data: inout [UInt8]) {
        for n in data.indices {
            i &+= 1; j &+= s[Int(i)]; s.swapAt(Int(i), Int(j))
            data[n] ^= s[Int(s[Int(i)] &+ s[Int(j)])]
        }
    }
    static func hex(_ text: String) -> [UInt8] {
        stride(from: 0, to: text.count, by: 2).map { UInt8(text.dropFirst($0).prefix(2), radix: 16)! }
    }
    static let incoming = hex("c91d9eec420160730d825604e0"), outgoing = hex("5a4d2016bc16dc64883194ffd9")
}

/// One direction of one TCP connection: puts segments in order, then cuts messages (a 4-byte size that counts the
/// 5-byte header, a type byte, and the payload, RC4 over payloads only, one cipher per direction from its first byte).
/// A connection caught mid-stream, a hole that never fills or a bad size breaks it for good: `broken` says why.
struct TrafficFlow {
    private(set) var broken: String?
    private var next: UInt32?
    private var pending: [UInt32: [UInt8]] = [:]
    private var buffer: [UInt8] = []
    private var cipher: RC4
    static let maxPending = 1 << 20, maxMessage = 1 << 24

    init(outgoing: Bool) { cipher = RC4(key: outgoing ? RC4.outgoing : RC4.incoming) }
    mutating func syn(seq: UInt32) { if next == nil && broken == nil { next = seq &+ 1 } }

    /// The messages this segment completes, in order.
    mutating func segment(seq: UInt32, payload: [UInt8]) -> [(type: UInt8, payload: [UInt8])] {
        guard broken == nil, !payload.isEmpty else { return [] }
        guard let expected = next else { broken = "mid_stream"; return [] }
        pending[seq] = payload
        var cursor = expected
        while true {   // take every pending segment that starts at or before the cursor
            guard let (start, data) = pending.first(where: { Int32(bitPattern: $0.key &- cursor) <= 0 }) else { break }
            pending[start] = nil
            let skip = Int(cursor &- start)
            if skip < data.count { buffer += data[skip...]; cursor = start &+ UInt32(data.count) }
        }
        next = cursor
        if pending.values.reduce(0, { $0 + $1.count }) > Self.maxPending { broken = "lost_segment"; return [] }
        var out: [(type: UInt8, payload: [UInt8])] = []
        while buffer.count >= 5 {
            let size = buffer[0..<4].reduce(0) { $0 << 8 | Int($1) }
            guard size >= 5, size <= Self.maxMessage else { broken = "bad_frame"; return out }
            guard buffer.count >= size else { break }
            var body = Array(buffer[5..<size])
            cipher.apply(&body)
            out.append((buffer[4], body))
            buffer.removeFirst(size)
        }
        return out
    }
}

/// The loot rules on decoded packets, as guard/loot_capture.h ran them on the game's calls. Lines go to `emit`.
final class TrafficLoot {
    static let format = 6   // 6: written from traffic (issue #61); same columns as 5
    static let bags: Set<Int> = [1280, 1286, 1287, 1288, 1289, 1291, 1292, 1294, 1295, 1296,
                                 1708, 1709, 1710, 1722, 1723, 1724, 1725, 1726, 1727, 1728]
    /// How long a kill waits for the guard's hit lines (it writes every 100 ms) before it is written.
    static let hold = 0.3

    let portals: Set<Int>
    private let sink: (String) -> Void
    /// Your projectile damage on an object between two times, from the guard's damage hook: (main, alt).
    var projectile: (_ object: Int, _ from: Double, _ to: Double) -> (Int, Int) = { _, _, _ in (0, 0) }

    private struct Object { var type: Int, x: Float, y: Float, maxHP: Int }
    private struct Hit { var ability = 0, others = 0, last = 0.0 }
    private struct Kill { var time: Double, map: Int, start: Double, id: Int, object: Object, hit: Hit, since: Double }
    private var objects: [Int: Object] = [:]   // never cleared within a connection's map, as the guard's type table
    private var hits: [Int: Hit] = [:]
    private var seen: Set<Int> = []
    private var tickBags: [[(id: Int, x: Float, y: Float)]] = [[], []], killed: [(id: Int, x: Float, y: Float)] = []
    private var toggle = 0
    /// Lines wait behind the oldest held kill, so a drop line never comes before its kill.
    private enum Out { case line(String), kill(Kill) }
    private var queue: [Out] = []
    private var failures: [UInt8: Int] = [:]
    private var map = 0, selfID = 0, mapStart = 0.0, named = -1, info: TrafficMapInfo?
    private var known: [Int: Int] = [:], texts: [Int: String] = [:]
    private(set) var kills = 0, bagCount = 0, portalCount = 0

    init(portals: Set<Int>, emit: @escaping (String) -> Void) { self.portals = portals; self.sink = emit }

    private func emit(_ line: String) { if queue.isEmpty { sink(line) } else { queue.append(.line(line)) } }

    /// A packet the rules read that didn't parse: its layout changed, so say so once per map and packet id.
    func failed(type: UInt8, time: Double) {
        failures[type, default: 0] += 1
        if failures[type] == 1 { emit("status\t\(t(time))\tparse_failed id=\(type) map=\(map)\n") }
    }

    private func t(_ time: Double) -> String { String(format: "%.3f", time) }
    private func f(_ v: Float) -> String { String(format: "%.2f", v) }

    func handle(_ packet: TrafficPacket, time: Double) {
        flush(now: time)
        switch packet {
        case let .mapInfo(m): info = m
        case let .createSuccess(id):
            // Each connection is one map and starts with your new id, before the map's objects.
            selfID = id; map += 1; mapStart = time
            hits = [:]; seen = []; tickBags = [[], []]; killed = []; known = [:]; texts = [:]; objects = [:]; failures = [:]
        case let .update(new, drops):
            // Yours first, so the map is named before anything on it is written.
            for (type, status) in new.filter({ $0.status.id == selfID }) + new.filter({ $0.status.id != selfID }) {
                arrive(type: type, status, time: time)
            }
            for id in drops { removed(id, time: time) }
        case let .newTick(statuses):
            for s in statuses { self.status(s, time: time) }
            tick(time: time)
        case let .damage(target, amount, attacker):
            // Someone else's hit counts only with damage; your abilities count as yours.
            if attacker == selfID && selfID != 0 { hit(target, time: time) { $0.ability += amount } }
            else if amount > 0 { hit(target, time: time) { $0.others += amount } }
        case let .enemyHit(target): hit(target, time: time) { _ in }
        }
    }

    private func hit(_ id: Int, time: Double, _ add: (inout Hit) -> Void) {
        guard id != 0 else { return }
        var h = hits[id] ?? Hit()
        add(&h); h.last = time
        hits[id] = h
    }

    private func arrive(type: Int, _ s: TrafficStatus, time: Double) {
        objects[s.id] = Object(type: type, x: s.x, y: s.y, maxHP: s.stats.first { $0.type == 0 }?.value ?? 0)
        if s.id == selfID { nameMap(time: time) }
        status(s, time: time)
        if portals.contains(type) {
            guard seen.insert(s.id).inserted else { return }
            emit("portal\t\(t(time))\t\(map)\t\(s.id)\t\(type)\t\(f(s.x))\t\(f(s.y))\n")
            tickBags[toggle].append((s.id, s.x, s.y)); portalCount += 1
            return
        }
        guard Self.bags.contains(type), seen.insert(s.id).inserted else { return }
        var items = [Int](repeating: -1, count: 8), extra: [TrafficStat] = []
        for stat in s.stats {
            if (8...15).contains(stat.type) { items[stat.type - 8] = stat.value } else if extra.count < 16 { extra.append(stat) }
        }
        emit("bag\t\(t(time))\t\(map)\t\(s.id)\t\(type)\t\(f(s.x))\t\(f(s.y))\t" + items.map(String.init).joined(separator: "\t") + "\n")
        for stat in extra {
            emit("bag_stat\t\(t(time))\t\(map)\t\(s.id)\t\(stat.type)\t\(stat.value)\t\(Self.clean(stat.text ?? ""))\n")
        }
        tickBags[toggle].append((s.id, s.x, s.y)); bagCount += 1
    }

    private func status(_ s: TrafficStatus, time: Double) {
        if var o = objects[s.id] {
            o.x = s.x; o.y = s.y
            if let max = s.stats.first(where: { $0.type == 0 }) { o.maxHP = max.value }
            objects[s.id] = o
        }
        guard s.id == selfID, selfID != 0 else { return }
        // Your own stats when they change (and all again on each map), not HP, MP or experience.
        for stat in s.stats where ![1, 4, 6].contains(stat.type) {
            if let text = stat.text, !text.isEmpty {
                var value = Self.clean(text)
                if stat.type == 80 { value = value.split(separator: ",", omittingEmptySubsequences: false).prefix(4).joined(separator: ",") }
                if texts[stat.type] == value { continue }
                texts[stat.type] = value; known[stat.type] = nil
                emit("player_stat\t\(t(time))\t\(map)\t\(stat.type)\t0\t\(value)\n")
                continue
            }
            let hadText = texts.removeValue(forKey: stat.type) != nil
            if !hadText, known[stat.type] == stat.value { continue }
            known[stat.type] = stat.value
            emit("player_stat\t\(t(time))\t\(map)\t\(stat.type)\t\(stat.value)\n")
        }
    }

    /// Once per map, when your object (and so your class) has arrived: the map's name and its info message.
    private func nameMap(time: Double) {
        guard named != map, let m = info, let me = objects[selfID] else { return }
        named = map; info = nil   // a MapInfo that fails to parse leaves the next map unnamed, not misnamed
        emit("map\t\(t(time))\t\(map)\t\(Self.clean(m.name))\n")
        // Same columns as the guard's raw read of the client's message (info_30 ... connection_110, then three texts).
        let values = [me.type, m.maxPlayers, m.seed, m.background, m.opened, m.unknown, m.width, m.height]
        emit("map_info\t\(t(time))\t\(map)\t" + values.map(String.init).joined(separator: "\t") +
             "\t\(Self.clean(m.realmName))\t\(Self.clean(m.version))\t\(Self.clean(m.modifiers))\n")
    }

    private func removed(_ id: Int, time: Double) {
        guard let h = hits.removeValue(forKey: id) else { return }
        // Where the server last put it; one it never sent can't be placed, so RealmHound skips it too.
        guard let o = objects[id] else { return }
        queue.append(.kill(Kill(time: time, map: map, start: mapStart, id: id, object: o, hit: h, since: time - h.last)))
        killed.append((id, o.x, o.y))
    }

    /// Each bag (and portal) of the tick before goes to the nearest kill since then, no distance limit.
    private func tick(time: Double) {
        toggle ^= 1
        for bag in tickBags[toggle] {
            let nearest = killed.min { pow($0.x - bag.x, 2) + pow($0.y - bag.y, 2) < pow($1.x - bag.x, 2) + pow($1.y - bag.y, 2) }
            emit("drop\t\(t(time))\t\(map)\t\(bag.id)\t\(nearest?.id ?? 0)\n")
        }
        tickBags[toggle] = []; killed = []
    }

    /// Writes the kills older than `hold`, with your projectile damage; `all` at the end of capture.
    func flush(now: Double, all: Bool = false) {
        while let first = queue.first {
            guard case let .kill(k) = first else { queue.removeFirst(); if case let .line(l) = first { sink(l) }; continue }
            guard all || now - k.time >= Self.hold else { break }
            queue.removeFirst()
            let (main, alt) = projectile(k.id, k.start, k.time)
            sink("kill\t\(t(k.time))\t\(k.map)\t\(k.id)\t\(k.object.type)\t\(f(k.object.x))\t\(f(k.object.y))\t0.00\t" +
                 "\(main)\t\(alt)\t\(k.hit.ability)\t\(k.object.maxHP)\tremoved\t\(Int(k.since * 1000))\t\(k.hit.others)\n")
            kills += 1
        }
    }

    /// Tabs and newlines would break the line format.
    static func clean(_ text: String) -> String {
        String(text.map { $0 == "\t" || $0 == "\n" || $0 == "\r" ? " " : $0 })
    }
}
