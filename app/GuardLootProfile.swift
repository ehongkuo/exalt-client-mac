import Foundation
import SQLite3

/// Loot factors (issue #58). docs/loot-factors.md lists every factor found, its size and the evidence. This file turns
/// the captured stats into a multiplier: live for the Loot profile window and "yours" rates, and per kill for base rates.

/// The loot numbers the game's XML states: loot enchantments (`LootBonus`) and dungeon modifiers' `EntityDropMultiplier`s.
struct LootCatalog: Equatable {
    struct Enchant: Equatable { var name: String; var percent: Double }
    /// Applies to a mob with every `req` label and no `exclude` label; with `item`, only to that item's drop.
    struct DropMultiplier: Equatable {
        var amount: Double
        var req: Set<String> = [], exclude: Set<String> = []
        var item: String?
    }
    struct Modifier: Equatable { var name: String; var drops: [DropMultiplier] }
    var enchants: [Int: Enchant] = [:]       // loot enchantments only, by type
    var modifiers: [String: Modifier] = [:]  // every modifier, by id

    static func load(folder: URL) -> LootCatalog {
        func read(_ file: String) -> String { (try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8)) ?? "" }
        return LootCatalog(enchants: enchants(inXML: read("enchantments.xml")), modifiers: modifiers(inXML: read("mods.xml")))
    }
    /// `name="value"` in a tag's text.
    static func attribute(_ tag: String, _ name: String) -> String? {
        (" " + tag).components(separatedBy: " \(name)=\"").dropFirst().first?.components(separatedBy: "\"").first
    }
    static func element(_ body: String, _ name: String) -> String? {
        body.components(separatedBy: "<\(name)>").dropFirst().first?.components(separatedBy: "</\(name)>").first
    }
    static func enchants(inXML text: String) -> [Int: Enchant] {
        text.components(separatedBy: "<Enchantment ").dropFirst().reduce(into: [:]) { found, part in
            let body = part.components(separatedBy: "</Enchantment>")[0]
            let percent = body.components(separatedBy: "<ActivateOnEquip ").dropFirst()
                .filter { $0.hasPrefix("amount=") && $0.contains(">LootBonus</ActivateOnEquip>") }
                .compactMap { attribute($0, "amount").flatMap(Double.init) }.reduce(0, +)
            guard percent != 0, let hex = attribute(String(body.prefix { $0 != ">" }), "type"), hex.hasPrefix("0x"),
                  let type = Int(hex.dropFirst(2), radix: 16) else { return }
            found[type] = Enchant(name: element(body, "DisplayId") ?? attribute(body, "id") ?? hex, percent: percent)
        }
    }
    static func modifiers(inXML text: String) -> [String: Modifier] {
        text.components(separatedBy: "<DungeonModifier ").dropFirst().reduce(into: [:]) { found, part in
            let body = part.components(separatedBy: "</DungeonModifier>")[0]
            guard let id = attribute(String(body.prefix { $0 != ">" }), "id") else { return }
            func labels(_ tag: String, _ name: String) -> Set<String> {
                Set((attribute(tag, name) ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            }
            let drops = body.components(separatedBy: "<EntityDropMultiplier ").dropFirst().compactMap { rest -> DropMultiplier? in
                let tag = rest.components(separatedBy: ">")[0]
                guard let amount = attribute(tag, "amount").flatMap(Double.init) else { return nil }
                return DropMultiplier(amount: amount, req: labels(tag, "reqLabels"), exclude: labels(tag, "excludeLabels"),
                                      item: attribute(tag, "itemId"))
            }
            found[id] = Modifier(name: element(body, "DisplayId") ?? id, drops: drops)
        }
    }
}

enum LootMath {
    static let potion = 1.5      // the community figure; measured ×1.37 ±12% so far (docs/loot-factors.md)
    static let crucible = 1.10   // Season 31's crucible loot bonus
    /// Blood Ritual: ×1.1 at −10% HP, ×1.15 at −15%, ×1.25 at −20%.
    /// shortcut: assumes stat 155 is the tier n of −5n% HP (RealmHound issue 64 names the stat, not its scale);
    /// check it the first time a capture has the ritual on.
    static func ritual(_ tier: Int) -> Double { tier >= 4 ? 1.25 : tier == 3 ? 1.15 : tier == 2 ? 1.1 : 1 }
    /// A map's modifier ids from its map info list ("ELITEMINIONS_2;FEEBLEMINIONS_2;|D": the grade follows the bar).
    static func modifiers(_ list: String) -> [String] {
        list.split(separator: ";").compactMap { $0.split(separator: "|", omittingEmptySubsequences: false).first.map(String.init) }
            .filter { !$0.isEmpty }
    }
    /// The modifiers' drop multipliers that apply to every drop of a mob with these labels. Item-only ones (×2 potions,
    /// ×100 stat potions) change one item, not the rate of the others, so they're left out.
    static func dungeon(_ modifiers: [String], _ catalog: LootCatalog, labels: Set<String>) -> Double {
        modifiers.flatMap { catalog.modifiers[$0]?.drops ?? [] }
            .filter { $0.item == nil && $0.req.isSubset(of: labels) && $0.exclude.isDisjoint(with: labels) }
            .reduce(1) { $0 * $1.amount }
    }
    /// Your gear's loot enchantments, in percent.
    static func gear(_ enchants: [[Int]], _ catalog: LootCatalog) -> Double {
        enchants.joined().compactMap { catalog.enchants[$0]?.percent }.reduce(0, +)
    }
    /// How the factors make one multiplier. Nothing states it, so it multiplies them: the one place to change once
    /// kills that mix factors show otherwise (docs/loot-factors.md, Open).
    static func combine(_ factors: [Double]) -> Double { factors.reduce(1, *) }
    /// "1.5", "1.02", "4.5".
    static func times(_ x: Double) -> String { x.formatted(.number.precision(.fractionLength(0...2))) }
    /// "14:32", "1:12:05".
    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds.rounded(.up)), h = s / 3600, m = s / 60 % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s % 60) : String(format: "%d:%02d", m, s % 60)
    }
}

/// Every loot factor at one moment.
struct LootState: Equatable {
    var potion: Double = 0          // seconds left on the Loot Drop Potion (stat 67)
    var tier: Double = 0            // seconds left on the Loot Tier Potion (stat 68): better tiers, not more drops
    var enchants: [[Int]]?          // your four equipment slots' enchantment ids; nil before the capture had them
    var crucible = false            // stat 128
    var ritual = 0                  // stat 155, the Blood Ritual's tier
    var modifiers: [String] = []    // the map's dungeon modifiers

    func multiplier(_ catalog: LootCatalog, labels: Set<String>, inDungeon: Bool = true) -> Double {
        LootMath.combine([potion > 0 ? LootMath.potion : 1, 1 + LootMath.gear(enchants ?? [], catalog) / 100,
                          crucible ? LootMath.crucible : 1, LootMath.ritual(ritual),
                          inDungeon ? LootMath.dungeon(modifiers, catalog, labels: labels) : 1])
    }
}

/// One map's (or one session's) captured factors over time, in time order.
struct LootTimeline {
    var stats: [Int: [(time: Double, value: Int)]] = [:]
    var gear: [(time: Double, text: String)] = []   // your stat 80
    var modifiers: [String] = []

    func last(_ stat: Int, at time: Double) -> (time: Double, value: Int)? { stats[stat]?.last { $0.time <= time } }
    /// The state at `time`. A timer counts down from its last reading unless `ticking` is off (a safe zone pauses it).
    /// The game sends it on each map entry and when you drink, so a reading on the same map is never stale.
    func state(at time: Double, ticking: Bool = true) -> LootState {
        func left(_ stat: Int) -> Double {
            guard let r = last(stat, at: time) else { return 0 }
            return max(0, Double(r.value) - (ticking ? time - r.time : 0))
        }
        return LootState(potion: left(67), tier: left(68),
                         enchants: gear.last { $0.time <= time }.map { Enchantments.ids($0.text).prefix(4).map { $0 ?? [] } },
                         crucible: (last(128, at: time)?.value ?? 0) != 0, ritual: last(155, at: time)?.value ?? 0,
                         modifiers: modifiers)
    }
    static let statTypes = "67, 68, 128, 155"
}

/// What the Loot profile window shows: your character and its loot factors in the game running now.
struct LootNow: Equatable {
    var map = ""
    var classType = 0, level = 0
    var seasonal = false
    var equipment: [Int] = []       // item types in your four equipment slots (stats 8–11), -1 when empty
    var at = 0.0                    // when `state` was read
    var safe = false                // a safe zone: the timers don't count down
    var state = LootState()
    var names: [Int: String] = [:]
    var textures: [Int: GameTexture] = [:]   // class, equipment, and the fixed sprites below

    /// Fixed sprites, under keys no game type uses.
    static let potionSprite = -10, tierSprite = -11, crucibleSprite = -12, ritualSprite = -13
    static let sprites: [Int: GameTexture] = [potionSprite: GameTexture(file: "d3LofiObjEmbed", index: 305),
                                              tierSprite: GameTexture(file: "d3LofiObjEmbed", index: 304),
                                              crucibleSprite: GameTexture(file: "lofiChar16x16", index: 107),
                                              ritualSprite: GameTexture(file: "entranceEffectsObjects", index: 584)]
    /// Where the loot timers pause.
    static let safeZones: Set<String> = ["Nexus", "Vault", "Guild Hall", "Pet Yard", "Daily Quest Room"]

    func state(at time: Double) -> LootState {
        var s = state
        if !safe { s.potion = max(0, s.potion - (time - at)); s.tier = max(0, s.tier - (time - at)) }
        return s
    }

    /// The newest session whose game still runs, or nil.
    static func load(_ store: DropRateStore, now: Double = Date().timeIntervalSince1970,
                     alive: (Int) -> Bool = { kill(pid_t($0), 0) == 0 || errno == EPERM }) -> LootNow? {
        var session: Int64 = 0, pid = 0, status = ""
        store.run("SELECT id, coalesce(pid, 0), coalesce(status, '') FROM sessions ORDER BY id DESC LIMIT 1") {
            session = sqlite3_column_int64($0, 0); pid = Int(sqlite3_column_int64($0, 1)); status = String(cString: sqlite3_column_text($0, 2))
        }
        guard session != 0, status != "complete", alive(pid) else { return nil }
        var n = LootNow(at: now)
        var map: Int64 = 0
        store.run("SELECT id, coalesce(name, '') FROM maps WHERE session = ? ORDER BY id DESC LIMIT 1", [session]) {
            map = sqlite3_column_int64($0, 0); n.map = String(cString: sqlite3_column_text($0, 1))
        }
        guard map != 0 else { return nil }
        n.safe = safeZones.contains(n.map)
        // shortcut: a session's readings all count, as the guard writes your stats again on each map; a timer read
        // before a safe zone keeps counting through it until the next map's reading.
        var line = LootTimeline()
        var latest: [Int: Int] = [:]
        store.run("""
            SELECT s.time, s.stat_type, s.value FROM player_stats s JOIN maps m ON m.id = s.map WHERE m.session = ? ORDER BY s.time
            """, [session]) {
            let stat = Int(sqlite3_column_int64($0, 1)), value = Int(sqlite3_column_int64($0, 2))
            line.stats[stat, default: []].append((sqlite3_column_double($0, 0), value)); latest[stat] = value
        }
        store.run("""
            SELECT t.time, t.text FROM player_texts t JOIN maps m ON m.id = t.map WHERE m.session = ? AND t.stat_type = 80 ORDER BY t.time
            """, [session]) { line.gear.append((sqlite3_column_double($0, 0), String(cString: sqlite3_column_text($0, 1)))) }
        store.run("SELECT coalesce(info_58, '') FROM map_info WHERE map = ?", [map]) { line.modifiers = LootMath.modifiers(String(cString: sqlite3_column_text($0, 0))) }
        store.run("""
            SELECT i.class FROM map_info i JOIN maps m ON m.id = i.map WHERE m.session = ? AND i.class <> 0 ORDER BY i.map DESC LIMIT 1
            """, [session]) { n.classType = Int(sqlite3_column_int64($0, 0)) }
        n.state = line.state(at: now, ticking: !n.safe)
        n.level = latest[7] ?? 0
        n.seasonal = (latest[24] ?? 0) != 0
        n.equipment = (8...11).map { latest[$0] ?? -1 }
        n.textures = sprites
        let types = ([n.classType] + n.equipment).filter { $0 > 0 }.map(String.init).joined(separator: ",")
        store.run("""
            SELECT type, coalesce(display_name, name), texture_file, texture_index FROM objects WHERE type IN (\(types))
            UNION ALL SELECT type, coalesce(display_name, name), texture_file, texture_index FROM items WHERE type IN (\(types))
            """) {
            let type = Int(sqlite3_column_int64($0, 0))
            n.names[type] = String(cString: sqlite3_column_text($0, 1))
            if sqlite3_column_type($0, 2) != SQLITE_NULL {
                n.textures[type] = GameTexture(file: String(cString: sqlite3_column_text($0, 2)), index: Int(sqlite3_column_int64($0, 3)))
            }
        }
        return n
    }
}
