import Foundation
import SQLite3

/// Drop-rate capture (issue #38). The guard registers drops as RealmHound does, for every bag type:
/// each hit mob the server removes (a kill), each bag once per map, and which kill each bag came from, to
/// logs/loot-<started>-<pid>.tsv (guard/loot_core.h has the columns). This imports those lines into
/// drop_rates.db and removes each file once it is fully imported and its game has ended.
/// Nothing here computes a rate: the rows stay raw so any later question can be asked of them.

struct LootKill: Equatable {
    var time: Double, generation: Int, object: Int, type: Int
    var x: Double, y: Double, z: Double
    var projectile: Int, projectileAlt: Int, ability: Int, maxHP: Int
    var landedBy: String              // "removed": seen only as the server removing a mob you hit
    var sinceHitMs: Int? = nil        // from the last hit to the kill (format 2)
    var others: Int? = nil            // other players' damage, from Damage messages (format 3)
}
struct LootBag: Equatable {
    var time: Double, generation: Int, object: Int, type: Int
    var x: Double, y: Double
    var items: [Int]   // slots 0-7, -1 empty
}

enum LootLine: Equatable {
    case session(format: Int, build: String, started: Double, pid: Int)
    case map(time: Double, generation: Int, name: String)
    case kill(LootKill)
    case bag(LootBag)
    case bagStat(time: Double, generation: Int, object: Int, stat: Int, value: Int, text: String)
    /// The kill a bag came from (killer 0: none), decided by the guard one tick after the bag.
    case drop(time: Double, generation: Int, bag: Int, killer: Int)
    /// The map's info message, raw: your class, then its ints and strings in guard order.
    case mapInfo(time: Double, generation: Int, values: [Int], texts: [String])
    case playerStat(time: Double, generation: Int, stat: Int, value: Int)
    case gap(time: Double, lost: Int, reason: String)
    case status(time: Double, text: String)
    case summary(String)

    init?(_ line: Substring) {
        let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
        func d(_ i: Int) -> Double? { i < f.count ? Double(f[i]) : nil }
        func n(_ i: Int) -> Int? { i < f.count ? Int(f[i]) : nil }
        switch f.first {
        case "loot_session":
            guard let format = n(1), f.count > 2, let started = d(3), let pid = n(4) else { return nil }
            self = .session(format: format, build: f[2], started: started, pid: pid)
        case "map":
            guard let t = d(1), let g = n(2) else { return nil }
            self = .map(time: t, generation: g, name: f.count > 3 ? f[3] : "")
        case "kill":
            guard (13...15).contains(f.count), let t = d(1), let g = n(2), let o = n(3), let ty = n(4),
                  let x = d(5), let y = d(6), let z = d(7), let p = n(8), let pa = n(9), let a = n(10), let hp = n(11)
            else { return nil }
            self = .kill(LootKill(time: t, generation: g, object: o, type: ty, x: x, y: y, z: z,
                                  projectile: p, projectileAlt: pa, ability: a, maxHP: hp, landedBy: f[12], sinceHitMs: n(13), others: n(14)))
        case "bag":
            let items = (7..<15).compactMap(n)
            guard f.count == 15, items.count == 8, let t = d(1), let g = n(2), let o = n(3), let ty = n(4), let x = d(5), let y = d(6)
            else { return nil }
            self = .bag(LootBag(time: t, generation: g, object: o, type: ty, x: x, y: y, items: items))
        case "bag_stat":
            guard let t = d(1), let g = n(2), let o = n(3), let s = n(4), let v = n(5) else { return nil }
            self = .bagStat(time: t, generation: g, object: o, stat: s, value: v, text: f.count > 6 ? f[6] : "")
        case "drop":
            guard f.count == 5, let t = d(1), let g = n(2), let b = n(3), let k = n(4) else { return nil }
            self = .drop(time: t, generation: g, bag: b, killer: k)
        case "map_info":
            let values = (3..<11).compactMap(n)
            guard f.count == 14, values.count == 8, let t = d(1), let g = n(2) else { return nil }
            self = .mapInfo(time: t, generation: g, values: values, texts: Array(f[11...]))
        case "player_stat":
            guard f.count == 5, let t = d(1), let g = n(2), let s = n(3), let v = n(4) else { return nil }
            self = .playerStat(time: t, generation: g, stat: s, value: v)
        case "gap":
            guard let t = d(1), let lost = n(2) else { return nil }
            self = .gap(time: t, lost: lost, reason: f.count > 3 ? f[3] : "")
        case "status":
            guard let t = d(1), f.count > 2 else { return nil }
            self = .status(time: t, text: f[2...].joined(separator: "\t"))
        case "loot_summary":
            self = .summary(f.dropFirst().joined(separator: "\t"))
        default: return nil
        }
    }
}

final class DropRateStore {
    let db: OpaquePointer
    static let schema = """
        PRAGMA journal_mode = WAL;
        CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY, file TEXT NOT NULL UNIQUE, started REAL, ended REAL,
            pid INTEGER, format INTEGER, game_build TEXT, app_version TEXT, status TEXT, summary TEXT,
            imported_bytes INTEGER NOT NULL DEFAULT 0);
        CREATE TABLE IF NOT EXISTS maps(id INTEGER PRIMARY KEY, session INTEGER NOT NULL, generation INTEGER NOT NULL,
            name TEXT, entered REAL, UNIQUE(session, generation));
        CREATE TABLE IF NOT EXISTS kills(id INTEGER PRIMARY KEY, map INTEGER NOT NULL, time REAL NOT NULL, object_id INTEGER,
            mob_type INTEGER, x REAL, y REAL, z REAL, damage_projectile INTEGER, damage_projectile_alt INTEGER,
            damage_ability INTEGER, max_hp INTEGER, landed_by TEXT);
        CREATE TABLE IF NOT EXISTS bags(id INTEGER PRIMARY KEY, map INTEGER NOT NULL, time REAL NOT NULL, object_id INTEGER,
            bag_type INTEGER, x REAL, y REAL, kill INTEGER);
        CREATE TABLE IF NOT EXISTS bag_items(bag INTEGER NOT NULL, slot INTEGER NOT NULL, item_type INTEGER NOT NULL);
        CREATE TABLE IF NOT EXISTS bag_stats(bag INTEGER NOT NULL, stat_type INTEGER, value INTEGER, text TEXT);
        CREATE TABLE IF NOT EXISTS capture_gaps(session INTEGER NOT NULL, time REAL, lost INTEGER, reason TEXT);
        -- Raw until a staging run names them: the map info message's fields by offset, and the two
        -- connection ints (character id?). class is your character's object type.
        CREATE TABLE IF NOT EXISTS map_info(map INTEGER PRIMARY KEY, class INTEGER, info_30 INTEGER, info_34 INTEGER,
            info_38 INTEGER, info_50 INTEGER, info_54 INTEGER, connection_10c INTEGER, connection_110 INTEGER,
            info_28 TEXT, info_48 TEXT, info_58 TEXT);
        -- Your own int stats (not HP, MP or experience), each time one changes and again on each map.
        CREATE TABLE IF NOT EXISTS player_stats(map INTEGER NOT NULL, time REAL NOT NULL, stat_type INTEGER, value INTEGER);
        CREATE INDEX IF NOT EXISTS player_stats_map ON player_stats(map, stat_type);
        -- Game catalog (issue #40), rebuilt from RealmHound's XML by GameNames.refreshCatalog. name is the
        -- XML id; display_name the in-game name when it differs (show coalesce(display_name, name)). Labels and
        -- origin are wrapped in commas (",UT,TAB_UT,"), so `labels LIKE '%,UT,%'` matches one label exactly.
        -- boss: <Quest/> or BOSSFIGHT. minion_class: WEAK, MID, STRONG, HIGH or LOW, from MINION_*.
        -- drop_source 0: an object of a class other than Character (wall, gate, pillar, portal), which
        -- RealmHound never credits a bag to. A type missing here counts as a source: join with
        -- coalesce(o.drop_source, 1), as RealmHound fails open on unknown types.
        CREATE TABLE IF NOT EXISTS objects(type INTEGER PRIMARY KEY, name TEXT, display_name TEXT, class TEXT, group_name TEXT,
            boss INTEGER NOT NULL, minion_class TEXT, drop_source INTEGER NOT NULL, labels TEXT);
        -- origin: the ORG_* labels without the prefix (",VOID,").
        CREATE TABLE IF NOT EXISTS items(type INTEGER PRIMARY KEY, name TEXT, display_name TEXT, bag_type INTEGER, slot_type INTEGER,
            tier INTEGER, labels TEXT, origin TEXT);
        CREATE TABLE IF NOT EXISTS catalog_source(signature TEXT NOT NULL);
        -- Dungeons (issue #45): each portal's <DungeonName> with the portal's type and sprite, and the labels of its
        -- <DungeonModTemplate> (its drop tag among them: ",ABYSS," for the Abyss); labels NULL when it has no template.
        CREATE TABLE IF NOT EXISTS dungeons(name TEXT PRIMARY KEY, portal INTEGER, texture_file TEXT, texture_index INTEGER, labels TEXT);
        CREATE INDEX IF NOT EXISTS kills_mob ON kills(mob_type);
        CREATE INDEX IF NOT EXISTS kills_map_time ON kills(map, time);
        CREATE INDEX IF NOT EXISTS bags_kill ON bags(kill);
        CREATE INDEX IF NOT EXISTS bags_map_object ON bags(map, object_id);
        CREATE INDEX IF NOT EXISTS bag_items_item ON bag_items(item_type);
        """

    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle); return nil
        }
        db = handle
        sqlite3_busy_timeout(db, 5000)   // the installed and staging apps share the file (issue #49)
        guard sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK else { return nil }
        var version = 0
        run("PRAGMA user_version") { version = Int(sqlite3_column_int64($0, 0)) }
        if version < 2 {
            guard sqlite3_exec(db, "ALTER TABLE kills ADD COLUMN since_hit_ms INTEGER; PRAGMA user_version = 2", nil, nil, nil)
                == SQLITE_OK else { return nil }
        }
        if version < 3 {
            guard sqlite3_exec(db, "ALTER TABLE kills ADD COLUMN damage_others INTEGER; PRAGMA user_version = 3", nil, nil, nil)
                == SQLITE_OK else { return nil }
        }
        if version < 4 {   // sprites (issue #41); clearing the signature rebuilds the catalog with them
            guard sqlite3_exec(db, """
                ALTER TABLE objects ADD COLUMN texture_file TEXT; ALTER TABLE objects ADD COLUMN texture_index INTEGER;
                ALTER TABLE items ADD COLUMN texture_file TEXT; ALTER TABLE items ADD COLUMN texture_index INTEGER;
                DELETE FROM catalog_source; PRAGMA user_version = 4
                """, nil, nil, nil) == SQLITE_OK else { return nil }
        }
        if version < 5 {   // textures written with attributes (<Texture xOffset=...>) were missed: rebuild
            guard sqlite3_exec(db, "DELETE FROM catalog_source; PRAGMA user_version = 5", nil, nil, nil) == SQLITE_OK else { return nil }
        }
        if version < 6 {   // the dungeons table (issue #45): rebuild the catalog to fill it
            guard sqlite3_exec(db, "DELETE FROM catalog_source; PRAGMA user_version = 6", nil, nil, nil) == SQLITE_OK else { return nil }
        }
    }
    deinit { sqlite3_close(db) }

    /// Set when any statement fails, so an import can roll back instead of skipping rows.
    var failed = false
    @discardableResult func exec(_ sql: String) -> Bool {
        let ok = sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK
        if !ok { failed = true }
        return ok
    }

    /// Runs one statement; calls `row` for each result row. Values are Int, Int64, Double, String or nil.
    @discardableResult
    func run(_ sql: String, _ values: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { failed = true; return false }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (i, value) in values.enumerated() {
            let index = Int32(i + 1)
            switch value {
            case let v as Int: sqlite3_bind_int64(statement, index, Int64(v))
            case let v as Int64: sqlite3_bind_int64(statement, index, v)
            case let v as Double: sqlite3_bind_double(statement, index, v)
            case let v as String: sqlite3_bind_text(statement, index, v, -1, transient)
            default: sqlite3_bind_null(statement, index)
            }
        }
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: row?(statement)
            case SQLITE_DONE: return true
            default: failed = true; return false
            }
        }
    }
    var lastID: Int64 { sqlite3_last_insert_rowid(db) }
}

enum LootImport {
    static func dbPath(data: URL) -> String { data.appendingPathComponent("drop_rates.db").path }

    /// Imports every loot file in `logs`. Returns the number of lines stored.
    @discardableResult
    static func run(logs: URL, store: DropRateStore, appVersion: String,
                    alive: (Int) -> Bool = { kill(pid_t($0), 0) == 0 || errno == EPERM }) -> Int {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: logs.path)) ?? []).sorted()
        var stored = 0
        for name in names where name.hasPrefix("loot-") && name.hasSuffix(".tsv") {
            let parts = name.dropFirst(5).dropLast(4).split(separator: "-")
            guard parts.count == 2, let pid = Int(parts[1]) else { continue }
            stored += importFile(logs.appendingPathComponent(name), name: name, pid: pid, store: store,
                                 appVersion: appVersion, alive: alive)
        }
        return stored
    }

    private static func importFile(_ url: URL, name: String, pid: Int, store: DropRateStore, appVersion: String,
                                   alive: (Int) -> Bool) -> Int {
        var session: Int64 = 0, offset = 0, status = ""
        store.run("SELECT id, imported_bytes, coalesce(status, '') FROM sessions WHERE file = ?", [name]) {
            session = sqlite3_column_int64($0, 0); offset = Int(sqlite3_column_int64($0, 1))
            status = String(cString: sqlite3_column_text($0, 2))
        }
        if session == 0 {
            guard store.run("INSERT INTO sessions(file, pid, app_version) VALUES (?, ?, ?)", [name, pid, appVersion]) else { return 0 }
            session = store.lastID
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }
        let size = Int((try? handle.seekToEnd()) ?? 0)
        guard size >= offset, (try? handle.seek(toOffset: UInt64(offset))) != nil else { return 0 }
        let data = (try? handle.readToEnd()) ?? Data()
        let complete = data.lastIndex(of: UInt8(ascii: "\n")).map { $0 - data.startIndex + 1 } ?? 0   // whole lines only

        var stored = 0, last: Double?
        if complete > 0 {
            var maps: [Int: Int64] = [:], bags: [String: Int64] = [:]
            func map(_ generation: Int, _ time: Double) -> Int64 {
                if let id = maps[generation] { return id }
                store.run("INSERT OR IGNORE INTO maps(session, generation, entered) VALUES (?, ?, ?)", [session, generation, time])
                var id: Int64 = 0
                store.run("SELECT id FROM maps WHERE session = ? AND generation = ?", [session, generation]) { id = sqlite3_column_int64($0, 0) }
                maps[generation] = id
                return id
            }
            guard store.exec("BEGIN IMMEDIATE") else { store.failed = false; return 0 }
            store.failed = false
            let text = String(decoding: data.prefix(complete), as: UTF8.self)
            for raw in text.split(separator: "\n") {
                guard let line = LootLine(raw) else { continue }
                stored += 1
                switch line {
                case let .session(format, build, started, pid):
                    store.run("UPDATE sessions SET format = ?, game_build = ?, started = ?, pid = ? WHERE id = ?",
                              [format, build, started, pid, session])
                case let .map(time, generation, name):
                    store.run("UPDATE maps SET name = ? WHERE id = ?", [name, map(generation, time)]); last = time
                case let .kill(k):
                    store.run("""
                        INSERT INTO kills(map, time, object_id, mob_type, x, y, z, damage_projectile, damage_projectile_alt,
                            damage_ability, max_hp, landed_by, since_hit_ms, damage_others) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [map(k.generation, k.time), k.time, k.object, k.type, k.x, k.y, k.z,
                              k.projectile, k.projectileAlt, k.ability, k.maxHP, k.landedBy, k.sinceHitMs, k.others])
                    last = k.time
                case let .bag(b):
                    let mapID = map(b.generation, b.time)
                    store.run("INSERT INTO bags(map, time, object_id, bag_type, x, y) VALUES (?, ?, ?, ?, ?, ?)",
                              [mapID, b.time, b.object, b.type, b.x, b.y])
                    let bag = store.lastID
                    bags["\(b.generation)/\(b.object)"] = bag
                    for (slot, item) in b.items.enumerated() where item >= 0 {
                        store.run("INSERT INTO bag_items(bag, slot, item_type) VALUES (?, ?, ?)", [bag, slot, item])
                    }
                    last = b.time
                case let .bagStat(time, generation, object, stat, value, text):
                    var bag = bags["\(generation)/\(object)"]
                    if bag == nil {
                        store.run("SELECT id FROM bags WHERE map = ? AND object_id = ? ORDER BY id DESC LIMIT 1",
                                  [map(generation, time), object]) { bag = sqlite3_column_int64($0, 0) }
                    }
                    if let bag { store.run("INSERT INTO bag_stats(bag, stat_type, value, text) VALUES (?, ?, ?, ?)", [bag, stat, value, text]) }
                case let .drop(time, generation, bag, killer) where killer != 0:
                    let mapID = map(generation, time)
                    store.run("""
                        UPDATE bags SET kill = (SELECT id FROM kills WHERE map = ?1 AND object_id = ?2 ORDER BY id DESC LIMIT 1)
                        WHERE id = (SELECT id FROM bags WHERE map = ?1 AND object_id = ?3 ORDER BY id DESC LIMIT 1)
                        """, [mapID, killer, bag])
                case .drop: break
                case let .mapInfo(time, generation, values, texts):
                    store.run("""
                        INSERT OR REPLACE INTO map_info(map, class, info_30, info_34, info_38, info_50, info_54, connection_10c,
                            connection_110, info_28, info_48, info_58) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [map(generation, time)] + values.map { $0 as Any? } + texts.map { $0 as Any? })
                case let .playerStat(time, generation, stat, value):
                    store.run("INSERT INTO player_stats(map, time, stat_type, value) VALUES (?, ?, ?, ?)",
                              [map(generation, time), time, stat, value])
                case let .gap(time, lost, reason):
                    store.run("INSERT INTO capture_gaps(session, time, lost, reason) VALUES (?, ?, ?, ?)", [session, time, lost, reason])
                case let .status(time, text):
                    status = text; last = time
                    store.run("UPDATE sessions SET status = ? WHERE id = ?", [text, session])
                    if text.hasPrefix("refused") {
                        store.run("INSERT INTO capture_gaps(session, time, lost, reason) VALUES (?, ?, 0, ?)", [session, time, text])
                    }
                case let .summary(text):
                    store.run("UPDATE sessions SET summary = ? WHERE id = ?", [text, session])
                }
            }
            store.run("UPDATE sessions SET imported_bytes = ?, ended = max(coalesce(ended, 0), ?) WHERE id = ?",
                      [offset + complete, last ?? 0, session])
            // Any failed write rolls the whole file back, so the next run retries it from the same place.
            guard !store.failed, store.exec("COMMIT") else { store.exec("ROLLBACK"); store.failed = false; return 0 }
        }
        // A file is done when its game has ended: every whole line is in, and a cut-off last line never completes.
        if status == "complete" || !alive(pid) {
            try? FileManager.default.removeItem(at: url)
        }
        return stored
    }
}

/// Capture health over all the data kept (issue #45): kills, bags and how many were linked to a kill, records lost,
/// and whether the latest game refused capture. The drop rates sidebar and the guard's Drop rates row show it.
struct CaptureHealth: Equatable {
    var kills = 0, bags = 0, linked = 0, lost = 0
    var refused: String?
    var lastKill: Double?   // seconds since 1970

    static func load(_ store: DropRateStore) -> CaptureHealth {
        var h = CaptureHealth()
        store.run("SELECT count(*), max(k.time) FROM kills k WHERE \(DropReport.died)") {
            h.kills = Int(sqlite3_column_int64($0, 0))
            if sqlite3_column_type($0, 1) != SQLITE_NULL { h.lastKill = sqlite3_column_double($0, 1) }
        }
        store.run("SELECT count(*), count(kill) FROM bags") {
            h.bags = Int(sqlite3_column_int64($0, 0)); h.linked = Int(sqlite3_column_int64($0, 1))
        }
        store.run("SELECT coalesce(sum(lost), 0) FROM capture_gaps") { h.lost = Int(sqlite3_column_int64($0, 0)) }
        // Only the latest game counts: an earlier refusal is gone once a later game captures.
        store.run("SELECT status FROM (SELECT status FROM sessions ORDER BY id DESC LIMIT 1) WHERE status LIKE 'refused%'") {
            h.refused = String(cString: sqlite3_column_text($0, 0))
        }
        return h
    }
}

/// Enchantments on the items of a bag, from its stat 80: one comma-separated part per slot, each base64url of
/// `00 02 n`, n 16-bit enchantment ids (fffd: an empty slot), then `05 00`. The counts match RealmHound's
/// enchant_count on staging run 1. A slot's count is nil where its part is empty or cut short (run 1's guard
/// kept only 64 characters).
enum Enchantments {
    static func counts(_ stat: String) -> [Int?] {
        stat.split(separator: ",", omittingEmptySubsequences: false).map { part -> Int? in
            var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while text.count % 4 != 0 { text += "=" }
            guard let data = Data(base64Encoded: text), data.count >= 3 else { return nil }
            let b = [UInt8](data), n = Int(b[2])
            guard b.count >= 3 + 2 * n else { return nil }
            return (0..<n).filter { Int16(bitPattern: UInt16(b[3 + 2 * $0]) | UInt16(b[4 + 2 * $0]) << 8) >= 0 }.count
        }
    }
}

/// A rate: `count` drops (or runs with one) in `of` kills (or runs), with a 95% range from the drop count
/// (Poisson, docs/drop-rates-investigation.md section 4).
struct DropRate: Equatable {
    var count: Int, of: Int
    var rate: Double { of > 0 ? Double(count) / Double(of) : 0 }
    /// How far off the rate may be, at 95%, as a fraction (0.44 reads ±44%): about 1.96 ÷ √drops. Nil under 4 drops,
    /// too few to say. It shrinks as data grows; there is no threshold where a rate becomes "solid".
    var precision: Double? { count >= 4 ? 1.96 / Double(count).squareRoot() : nil }
    var range: ClosedRange<Double> {
        guard of > 0 else { return 0...0 }
        let (low, high) = Self.poissonRange(count)
        return low / Double(of)...high / Double(of)
    }

    /// The 95% range of a Poisson mean given `x` events: exact below 50, Byar's approximation above (within 0.1% there).
    static func poissonRange(_ x: Int) -> (Double, Double) {
        let z = 1.96, n = Double(x)
        if x >= 50 {
            return (n * pow(1 - 1 / (9 * n) - z / (3 * n.squareRoot()), 3),
                    (n + 1) * pow(1 - 1 / (9 * (n + 1)) + z / (3 * (n + 1).squareRoot()), 3))
        }
        func cdf(_ k: Int, _ mean: Double) -> Double {   // P(X <= k)
            guard k >= 0 else { return 0 }
            var term = exp(-mean), sum = term
            for i in stride(from: 1, through: k, by: 1) { term *= mean / Double(i); sum += term }
            return sum
        }
        // The mean where P(X <= k) falls to `target`, by bisection (the cdf falls as the mean grows).
        func mean(_ k: Int, _ target: Double) -> Double {
            var low = 0.0, high = 100.0
            for _ in 0..<60 { let mid = (low + high) / 2; if cdf(k, mid) > target { low = mid } else { high = mid } }
            return (low + high) / 2
        }
        return (x == 0 ? 0 : mean(x - 1, 0.975), mean(x, 0.025))
    }

    /// "1 in 41"; "none yet" for 0 and "every time" from 1 up.
    static func oneIn(_ rate: Double) -> String {
        rate <= 0 ? "none yet" : rate >= 1 ? "every time" : "1 in \(Int((1 / rate).rounded()).formatted())"
    }
}

/// Everything the drop rates views show past Today (issues #41, #45), from all the data kept. Every query of the
/// views is here, so a change in the data's shape after a staging run changes this one place.
/// - A kill is `died`; its drops are the items in bags linked to it (`bags.kill`).
/// - A kill's best bag is the highest colour among its bags; it counts once per kill, so an overflow
///   second bag of the same colour adds nothing.
/// - A run is a map visit in which a boss (catalog `boss`) died; per-run rates count runs with at least one.
struct DropReport: Equatable {
    /// A mob type in one dungeon (the map name).
    struct Mob: Hashable { var type: Int, dungeon: String }
    var kills: [Mob: Int] = [:]
    var maxHP: [Mob: Int] = [:]
    var bestBag: [Mob: [DropBag: Int]] = [:]        // kills whose best bag was that colour
    var copies: [Mob: [Int: Int]] = [:]             // copies of each item from the mob's kills
    var runs: [String: Int] = [:]                   // by dungeon
    /// dungeon → item → the runs (map ids) with at least one copy. Sets, so any-of counts (base and shiny, a tier
    /// group) count a run once.
    var runMaps: [String: [Int: Set<Int>]] = [:]
    /// dungeon → boss type (nil: any boss) → runs whose best bag from it was that colour.
    var bossBags: [String: [Int?: [DropBag: Int]]] = [:]
    var itemBag: [Int: DropBag] = [:]               // the highest bag colour each item came in
    /// mob → item → copies by `DropRarity`. A copy with no rarity counts in none: the bag's stat 80 has no part for it
    /// (potions, stones and other items without enchantments) or the part was cut short.
    var rarity: [Mob: [Int: [Int]]] = [:]
    /// One copy from a kill, with its enchantments (nil: no rarity).
    struct Copy: Hashable { var mob: Mob, item: Int, enchants: Int? }
    var drops: [Copy] = []
    var origins: [Int: String] = [:]                // item → the catalog's origin codes (",ABYSS,"), for every tagged item
    var bags: [Int: DropBag] = [:]                  // item → the bag the catalog puts it in (<BagType>)
    var tiers: [Int: Int] = [:], slots: [Int: Int] = [:]   // item → <Tier>, <SlotType>
    var shinyOf: [Int: Int] = [:]                   // shiny item → its base item ("X Shiny" → "X", by the id)
    var subtypes: Set<Int> = []                     // a slot's alternate weapon (flail, blades, tachi, …): label SUBTYPE
    /// Every item of each tier group in the catalog, in rotation order: what a group tile cycles through, dropped or not.
    var members: [Group: [Int]] = [:]
    /// A dungeon to list: one with a template in the catalog, or a map with kills. `codes`: its drop tags.
    struct Dungeon: Hashable { var name: String, portal: Int?, codes: Set<String> }
    var dungeons: [Dungeon] = []                    // by name
    var names: [Int: String] = [:]
    var bosses: Set<Int> = []
    var textures: [Int: GameTexture] = [:]

    /// A mob you damaged, removed soon after the last hit: a death. A later removal is usually a mob
    /// that left your view.
    // shortcut: 1 s is a guess from tick and round-trip time; set it from staging run 2's removals
    // that left a bag.
    static let died = """
        (k.damage_projectile + k.damage_projectile_alt + k.damage_ability > 0 \
        AND (k.landed_by <> 'removed' OR k.since_hit_ms <= 1000))
        """

    /// Drop tags for dungeons whose template labels name them differently from the items' `ORG_*` tags (LOSTHALLS for
    /// LH; The Void reuses the Lost Halls template; Crystal Cavern's labels say FUNGAL), or that have no template.
    /// These replace the labels, and list the dungeon.
    // shortcut: by hand from the Nov 2026 game XML; a dungeon missing here and with no matching label shows only what dropped.
    static let dropTags: [String: Set<String>] = [
        "Lost Halls": ["LH"], "The Void": ["VOID"], "The Shatters": ["SHTT"], "Ocean Trench": ["OTRENCH"],
        "Spider Den": ["SPIDER"], "Toxic Sewers": ["SEWER"], "Kogbold Steamworks": ["KOGBOLD"],
        "Advanced Kogbold Steamworks": ["KOGBOLD"], "Cultist Hideout": ["CULT"], "Ice Cave": ["ICECAVE"],
        "Spectral Penitentiary": ["SPECTRAL"], "Legacy Heroic Abyss of Demons": ["ABYSS"], "Legacy Heroic Undead Lair": ["UDL"],
        "Crystal Cavern": ["CRYSTAL"], "Lair of Draconis": ["LOD"], "Oryx's Sanctuary": ["OSANC"], "Moonlight Village": ["MOONLIGHT"],
        "Oryx's Castle": ["CASTLE"],
    ]

    /// Tiered loot by mob name, from each mob's RealmEye page ("We7,8" is T7 and T8 weapons; Ab abilities, Ar armor,
    /// Ri rings). The game data has no loot tables, so this is how a group that hasn't dropped yet still shows.
    // shortcut: by hand from RealmEye in Nov 2026, only for the mobs killed so far (the Realm and Abyss of Demons);
    // add a mob's line when a new dungeon shows only what dropped.
    static let realmEyeTiers: [String: String] = [
        "Abyss Idol": "We7,9 Ab3,4 Ar6,8 Ri3,4",
        "Archdemon Malphas": "We7,8,9,10 Ab3,4 Ar6,8,9 Ri3,4",
        "Banshee": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Beholder": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Blacksmith of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Brimstone Wyvern": "We7,8,9 Ab3,4 Ar7,8,9,10 Ri3,4",
        "Brute Warrior of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Brute of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Burning Bones": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Cerberus": "We7,8,9 Ab3,4 Ar7,8,9,10 Ri3,4",
        "Colossal Mantis": "We8,9,10 Ab4,5 Ar8,9,10 Ri4,5",
        "Corrupt Sprite": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Cosmic Sprite": "We7,8,9,10 Ab3,4 Ar7,8,9,10 Ri3,4",
        "Creepy Beholder": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Demon Mage of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Demon Warrior of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Demon of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Djinn": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Ent God": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Flying Brain": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Flying Vampire": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Ghastly Nun": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Ghost God": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Grand Dragonfly": "We8,9,10 Ab4,5 Ar8,9,10 Ri4,5",
        "Harrowed Fiend": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Hazardous Sprite": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Hunter Dragonfly": "We8,9,10 Ab4,5 Ar8,9,10 Ri4,5",
        "Imp of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Infernal Ironsmith": "We7,8,9,10 Ab3,4 Ar7,8,9,10 Ri3,4",
        "Legion Church Guardian": "We9,10 Ab4 Ar10,11 Ri4",
        "Legion City Guardian": "We9,10 Ab4 Ar10,11 Ri4",
        "Legion Excavator": "We8,9,10 Ab3,4 Ar8,9,10 Ri3,4",
        "Legion Fey Guardian": "We9,10 Ab4 Ar10,11 Ri4",
        "Legion Graveyard Guardian": "We9,10 Ab4 Ar10,11 Ri4",
        "Legion Hell Guardian": "We9,10 Ab4 Ar10,11 Ri4",
        "Man-Eating Flytrap": "We8,9,10 Ab4,5 Ar8,9,10 Ri4,5",
        "Nameless Gladiator": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Noxious Sprite": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Pumpkin Brute": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Raging Ifrit": "We7,8,9 Ab3,4 Ar7,8,9,10 Ri3,4",
        "Red Demon": "We7,8,9,10 Ab2,3,4 Ar6,7,8,9,10 Ri2,3,4",
        "Risen Hellhound": "We7,8,9 Ab3,4 Ar7,8,9,10 Ri3,4",
        "Skeleton Worshipper": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Skeleton of the Damned": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Slime God": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Spitting Arachnid": "We8,9,10 Ab4,5 Ar8,9,10 Ri4,5",
        "Sprite Beast": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Sprite God": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Tormented Soul": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Unsung Jester": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Vagabond Satyr": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Werewolf Berserker": "We7,8,9 Ab3,4 Ar7,8,9,10 Ri3,4",
        "White Demon": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "White Demon of the Abyss": "We7 Ab3 Ar7 Ri3",
        "Wraith": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4",
        "Zombie Cleric": "We6,7,8 Ab3,4 Ar6,7,8,9 Ri3,4"
    ]
    /// Catalog items with a <Tier> that RealmEye lists as no tier or has no page for (Nov 2026): test and event items,
    /// never tiered loot. Every other tiered item has a RealmEye page, and spot-checked sprites match.
    static let notLoot: Set<String> = [
        "Short Test Sword", "Testing Trap", "Test Trap ATT", "Test Trap DEF", "Test Trap SPD", "Test Trap DEX", "Test Trap WIS",
        "Test Trap VIT", "Test Trap DEX 2", "Magic Nova Spell BulletNova", "Magic Nova Spell DamageNova", "Trick Sheath",
        "Trick Star", "Trick Lute", "Ring of Minor Defense",
    ]
    /// Every item of the tier groups in a `realmEyeTiers` line.
    func tierItems(_ codes: String) -> Set<Int> {
        let families: [Substring: Group.Family] = ["We": .weapons, "Ab": .abilities, "Ar": .armors, "Ri": .rings]
        return Set(codes.split(separator: " ").flatMap { code -> [Int] in
            guard let family = families[code.prefix(2)] else { return [] }
            return code.dropFirst(2).split(separator: ",").flatMap { members[Group(tier: Int($0) ?? -1, family: family)] ?? [] }
        })
    }
    /// A mob's tiered loot by RealmEye.
    func tierItems(_ mob: Mob) -> Set<Int> { Self.realmEyeTiers[name(mob.type)].map(tierItems) ?? [] }

    /// A bag object type's place in `DropBag.allCases` (higher is better), as SQL over `bags b`.
    static let rank = "CASE b.bag_type " + (1200...1800).compactMap { id in
        DropBag(id: id).map { "WHEN \(id) THEN \(DropBag.allCases.firstIndex(of: $0)!)" }
    }.joined(separator: " ") + " END"

    static func load(_ store: DropRateStore) -> DropReport {
        var r = DropReport()
        let died = Self.died, rank = Self.rank
        let runs = "WITH runs AS (SELECT DISTINCT k.map FROM kills k JOIN objects o ON o.type = k.mob_type WHERE o.boss AND \(died))"
        func int(_ s: OpaquePointer, _ i: Int32) -> Int { Int(sqlite3_column_int64(s, i)) }
        func text(_ s: OpaquePointer, _ i: Int32) -> String { sqlite3_column_text(s, i).map { String(cString: $0) } ?? "" }
        func bag(_ s: OpaquePointer, _ i: Int32) -> DropBag? {
            sqlite3_column_type(s, i) == SQLITE_NULL ? nil : DropBag.allCases[int(s, i)]
        }
        func better(_ a: DropBag?, _ b: DropBag) -> DropBag {
            guard let a else { return b }
            return DropBag.allCases.firstIndex(of: a)! > DropBag.allCases.firstIndex(of: b)! ? a : b
        }
        store.run("""
            SELECT k.mob_type, coalesce(m.name, ''), count(*), max(k.max_hp) FROM kills k JOIN maps m ON m.id = k.map
            WHERE \(died) GROUP BY 1, 2
            """) {
            let mob = Mob(type: int($0, 0), dungeon: text($0, 1))
            r.kills[mob] = int($0, 2); r.maxHP[mob] = int($0, 3)
        }
        store.run("""
            SELECT mob_type, dungeon, top, count(*) FROM (
                SELECT k.mob_type, coalesce(m.name, '') dungeon, max(\(rank)) top FROM kills k JOIN maps m ON m.id = k.map
                JOIN bags b ON b.kill = k.id WHERE \(died) GROUP BY k.id)
            WHERE top IS NOT NULL GROUP BY 1, 2, 3
            """) { r.bestBag[Mob(type: int($0, 0), dungeon: text($0, 1)), default: [:]][DropBag.allCases[int($0, 2)]] = int($0, 3) }
        store.run("""
            SELECT k.mob_type, coalesce(m.name, ''), i.item_type, count(*), max(\(rank)) FROM bag_items i JOIN bags b ON b.id = i.bag
            JOIN kills k ON k.id = b.kill JOIN maps m ON m.id = k.map WHERE \(died) GROUP BY 1, 2, 3
            """) {
            let item = int($0, 2)
            r.copies[Mob(type: int($0, 0), dungeon: text($0, 1)), default: [:]][item] = int($0, 3)
            if let top = bag($0, 4) { r.itemBag[item] = better(r.itemBag[item], top) }
        }
        var decoded: [Int: [Int?]] = [:]   // by bag: one decode per bag, not per item
        store.run("""
            SELECT k.mob_type, coalesce(m.name, ''), i.item_type, i.slot, b.id,
                (SELECT text FROM bag_stats s WHERE s.bag = b.id AND s.stat_type = 80) FROM bag_items i JOIN bags b ON b.id = i.bag
            JOIN kills k ON k.id = b.kill JOIN maps m ON m.id = k.map WHERE \(died)
            """) {
            let bag = int($0, 4), slot = int($0, 3)
            let counts = decoded[bag] ?? Enchantments.counts(text($0, 5))
            decoded[bag] = counts
            let mob = Mob(type: int($0, 0), dungeon: text($0, 1)), item = int($0, 2), n = slot < counts.count ? counts[slot] : nil
            r.drops.append(Copy(mob: mob, item: item, enchants: n))
            if let n { r.rarity[mob, default: [:]][item, default: [0, 0, 0, 0, 0]][DropRarity(enchants: n).rawValue] += 1 }
        }
        store.run("\(runs) SELECT coalesce(m.name, ''), count(*) FROM runs JOIN maps m ON m.id = runs.map GROUP BY 1") {
            r.runs[text($0, 0)] = int($0, 1)
        }
        store.run("""
            \(runs) SELECT DISTINCT coalesce(m.name, ''), i.item_type, k.map FROM bag_items i JOIN bags b ON b.id = i.bag
            JOIN kills k ON k.id = b.kill JOIN maps m ON m.id = k.map WHERE \(died) AND k.map IN (SELECT map FROM runs)
            """) { r.runMaps[text($0, 0), default: [:]][int($0, 1), default: []].insert(int($0, 2)) }
        var anyBoss: [Int: (dungeon: String, bag: DropBag)] = [:]   // by map
        store.run("""
            SELECT k.map, coalesce(m.name, ''), k.mob_type, max(\(rank)) FROM kills k JOIN maps m ON m.id = k.map
            JOIN objects o ON o.type = k.mob_type JOIN bags b ON b.kill = k.id WHERE o.boss AND \(died) GROUP BY k.map, k.mob_type
            """) {
            guard let top = bag($0, 3) else { return }
            let map = int($0, 0), dungeon = text($0, 1)
            r.bossBags[dungeon, default: [:]][int($0, 2), default: [:]][top, default: 0] += 1
            anyBoss[map] = (dungeon, better(anyBoss[map]?.bag, top))
        }
        for (dungeon, top) in anyBoss.values { r.bossBags[dungeon, default: [:]][nil, default: [:]][top, default: 0] += 1 }
        store.run("""
            SELECT type, coalesce(display_name, name), boss, texture_file, texture_index, NULL, NULL, NULL, NULL FROM objects
            WHERE type IN (SELECT mob_type FROM kills) UNION ALL
            SELECT type, coalesce(display_name, name), 0, texture_file, texture_index, bag_type, origin, tier, slot_type FROM items
            WHERE type IN (SELECT item_type FROM bag_items) OR origin IS NOT NULL OR (tier IS NOT NULL AND name NOT LIKE '% (SB)')
                OR name || ' Shiny' IN (SELECT name FROM items WHERE type IN (SELECT item_type FROM bag_items) OR origin IS NOT NULL)
                OR name IN (SELECT name || ' Shiny' FROM items WHERE type IN (SELECT item_type FROM bag_items) OR origin IS NOT NULL)
            """) {
            let type = int($0, 0)
            r.names[type] = text($0, 1)
            if sqlite3_column_type($0, 5) != SQLITE_NULL, let bag = DropBag(bagType: int($0, 5)) { r.bags[type] = bag }
            if sqlite3_column_type($0, 6) != SQLITE_NULL { r.origins[type] = text($0, 6) }
            if int($0, 2) != 0 { r.bosses.insert(type) }
            if sqlite3_column_type($0, 3) != SQLITE_NULL { r.textures[type] = GameTexture(file: text($0, 3), index: int($0, 4)) }
            if sqlite3_column_type($0, 7) != SQLITE_NULL { r.tiers[type] = int($0, 7) }
            if sqlite3_column_type($0, 8) != SQLITE_NULL { r.slots[type] = int($0, 8) }
        }
        store.run("SELECT s.type, b.type FROM items s JOIN items b ON s.name = b.name || ' Shiny'") { r.shinyOf[int($0, 0)] = int($0, 1) }
        store.run("SELECT type FROM items WHERE labels LIKE '%,SUBTYPE,%'") { r.subtypes.insert(int($0, 0)) }
        for item in r.tiers.keys where r.shinyOf[item] == nil && !r.name(item).hasSuffix(" (SB)") && !Self.notLoot.contains(r.name(item)) {
            if let g = r.group(item) { r.members[g, default: []].append(item) }
        }
        r.members = r.members.mapValues { r.kinds($0).flatMap { $0 } }
        // Drop tags are the template labels that some item carries as its origin.
        let tags = Set(r.origins.values.flatMap { $0.split(separator: ",").map(String.init) })
        var listed: [String: Dungeon] = [:]
        store.run("SELECT name, portal, texture_file, texture_index, labels FROM dungeons") {
            let name = text($0, 0), portal = sqlite3_column_type($0, 1) == SQLITE_NULL ? nil : int($0, 1)
            if let portal, sqlite3_column_type($0, 2) != SQLITE_NULL { r.textures[portal] = GameTexture(file: text($0, 2), index: int($0, 3)) }
            let labels = sqlite3_column_type($0, 4) == SQLITE_NULL ? nil : Set(text($0, 4).split(separator: ",").map(String.init))
            if labels != nil || Self.dropTags[name] != nil || r.kills.keys.contains(where: { $0.dungeon == name }) {
                listed[name] = Dungeon(name: name, portal: portal, codes: Self.dropTags[name] ?? labels?.intersection(tags) ?? [])
            }
        }
        for mob in r.kills.keys where listed[mob.dungeon] == nil { listed[mob.dungeon] = Dungeon(name: mob.dungeon, portal: nil, codes: []) }
        r.dungeons = listed.values.sorted { $0.name < $1.name }
        return r
    }

    func name(_ type: Int) -> String { names[type] ?? String(format: "#0x%04x", type) }
    /// The best rarity (as an enchantment count) of any copy of an item, from every mob or one dungeon's; nil when none was read.
    func bestEnchants(_ item: Int, dungeon: String? = nil, mob: Mob? = nil) -> Int? {
        rarity.filter { (dungeon == nil || $0.key.dungeon == dungeon) && (mob == nil || $0.key == mob) }.compactMap { $0.value[item]?.lastIndex { $0 > 0 } }.max()
    }
    /// Copies of an item by rarity, from one mob or every mob.
    func rarityCounts(_ item: Int, mob: Mob? = nil) -> [Int] { rarityCounts([item], mob: mob) }
    func rarityCounts(_ items: Set<Int>, mob: Mob? = nil) -> [Int] {
        rarity.filter { mob == nil || $0.key == mob }.flatMap { r in items.compactMap { r.value[$0] } }.reduce([0, 0, 0, 0, 0]) { zip($0, $1).map(+) }
    }

    /// Copies of an item from every mob.
    func dropped(_ item: Int) -> Int { copies.values.reduce(0) { $0 + ($1[item] ?? 0) } }
    /// Every item dropped, by name.
    var items: [Int] { Set(copies.values.flatMap(\.keys)).sorted { name($0) < name($1) } }
    func bag(_ item: Int) -> DropBag? { bags[item] ?? itemBag[item] }

    /// A dungeon's possible drops: items the catalog tags with one of its drop tags, its mobs' tiered loot by RealmEye,
    /// and every item that dropped there.
    func possibleDrops(_ dungeon: Dungeon) -> Set<Int> {
        let tagged = origins.filter { item in dungeon.codes.contains { item.value.contains(",\($0),") } }.keys
        return Set(tagged).union(drops.filter { $0.mob.dungeon == dungeon.name }.map(\.item))
            .union(kills.keys.filter { $0.dungeon == dungeon.name }.flatMap(tierItems))
    }
    /// An item's base: a shiny's plain item, else the item itself. Shinies show as their base item's tile.
    func base(_ item: Int) -> Int { shinyOf[item] ?? item }
    /// An item and its shiny.
    func variants(_ item: Int) -> Set<Int> { Set(shinyOf.filter { $0.value == item }.keys).union([item]) }
    /// Runs in a dungeon with at least one copy of any of the items.
    func runsWith(_ dungeon: String, _ items: Set<Int>) -> Int {
        items.reduce(into: Set<Int>()) { $0.formUnion(runMaps[dungeon]?[$1] ?? []) }.count
    }
    /// Copies of any of the items from one mob.
    func copies(_ mob: Mob, _ items: Set<Int>) -> Int { items.reduce(0) { $0 + (copies[mob]?[$1] ?? 0) } }

    /// Items of one tier and slot family, which share a tile: T12 weapons, T5 rings. Untiered items (UTs, STs,
    /// whites) have no group.
    struct Group: Hashable {
        enum Family: Int, CaseIterable { case weapons, abilities, armors, rings }
        var tier: Int, family: Family
        var name: String { "T\(tier) \(family)" }
    }
    /// The game's <SlotType> families; consumables (10) and eggs (26) have tiers but no group.
    static func family(slot: Int) -> Group.Family? {
        switch slot {
        case 1, 2, 3, 8, 17, 24: return .weapons
        case 6, 7, 14: return .armors
        case 9: return .rings
        case 10, 26: return nil
        default: return .abilities
        }
    }
    func group(_ item: Int) -> Group? {
        let b = base(item)
        guard let tier = tiers[b], let family = slots[b].flatMap(Self.family) else { return nil }
        return Group(tier: tier, family: family)
    }

    /// Each family's kinds in a fixed order: weapon, ability and armor slots, and ring stats (by the ring's name).
    static let weaponSlots = [1, 2, 3, 8, 17, 24], armorSlots = [6, 7, 14]
    static let abilitySlots = [4, 5, 11, 12, 13, 15, 16, 18, 19, 20, 21, 22, 23, 25, 27, 28, 29, 30, 31]
    static let ringStats = ["Attack", "Defense", "Speed", "Dexterity", "Vitality", "Wisdom", "Health", "Magic"]
    /// An item's place in its family's rotation, and the rotation's length; nil for an item with no group or an
    /// unknown kind.
    func rotation(_ item: Int) -> (position: Int, of: Int)? {
        let b = base(item)
        guard let family = group(b)?.family, let slot = slots[b] else { return nil }
        switch family {
        case .weapons: return Self.weaponSlots.firstIndex(of: slot).map { ($0, Self.weaponSlots.count) }
        case .armors: return Self.armorSlots.firstIndex(of: slot).map { ($0, Self.armorSlots.count) }
        case .abilities: return Self.abilitySlots.firstIndex(of: slot).map { ($0, Self.abilitySlots.count) }
        case .rings: return Self.ringStats.firstIndex { name(b).contains($0) }.map { ($0, Self.ringStats.count) }
        }
    }

    /// A group's members by kind, in its family's rotation order. A slot's base type comes before its alternate (sword,
    /// then flail), each its own kind. Items with no place go last, one kind each.
    func kinds(_ items: [Int]) -> [[Int]] {
        let placed = Dictionary(grouping: items.filter { rotation($0) != nil }) {
            rotation($0)!.position * 2 + (subtypes.contains(base($0)) ? 1 : 0)
        }
        return placed.keys.sorted().map { placed[$0]!.sorted { name($0) < name($1) } } + items.filter { rotation($0) == nil }.map { [$0] }
    }

    /// A tile in a bag row: one base item, or a tier group of two or more.
    enum Tile: Hashable {
        case item(Int)
        case group(Group, [Int])
        var items: [Int] { switch self { case .item(let i): return [i]; case .group(_, let items): return items } }
    }
    /// Items as tiles by bag (nil: no bag known). Shinies fold into their base. Sorted weapons, abilities, armors, rings,
    /// then everything else (potions, eggs, …); within each, untiered (UTs, STs) first, then best tier, then by name.
    func tiles(_ items: Set<Int>) -> [DropBag?: [Tile]] {
        let bases = Set(items.map(base))
        func key(_ tile: Tile) -> (Int, Int, String) {
            let first = tile.items[0], tier = tiers[first]
            let family = slots[first].flatMap(Self.family)?.rawValue ?? Group.Family.allCases.count
            return (family, tier.map { -$0 } ?? Int.min, name(first))
        }
        return Dictionary(grouping: bases) { bag($0) }.mapValues { inBag in
            let byGroup = Dictionary(grouping: inBag) { group($0) }
            var groups: [Tile] = [], singles: [Int] = []
            for (g, members) in byGroup {
                // A group tile holds the whole tier, so its rotation is the same wherever it shows.
                if let g, let all = self.members[g], all.count > 1 { groups.append(.group(g, all)) } else { singles += members }
            }
            return (groups + singles.map(Tile.item)).sorted { key($0) < key($1) }
        }
    }

    /// Where an item (or any of a set) dropped: one per dungeon, with its runs, runs with one, and copies per mob.
    struct Source: Hashable {
        var dungeon: String, runs: Int, runsWith: Int, mobs: [Mob: Int]
        var perRun: DropRate? { runs > 0 ? DropRate(count: runsWith, of: runs) : nil }
    }
    /// Sources, surest first: by the low end of the per-run 95% range, so a lucky 1 in 2 doesn't top a steady 1 in 7.
    /// Places with no runs (no boss died: the Realm, events) follow, by their best mob's per kill.
    func sources(_ items: Set<Int>) -> [Source] {
        var mobs: [String: [Mob: Int]] = [:]
        for mob in copies.keys { let n = copies(mob, items); if n > 0 { mobs[mob.dungeon, default: [:]][mob] = n } }
        let all = mobs.map { Source(dungeon: $0.key, runs: runs[$0.key] ?? 0, runsWith: runsWith($0.key, items), mobs: $0.value) }
        func key(_ s: Source) -> (Int, Double) {
            if let r = s.perRun { return (1, r.range.lowerBound) }
            return (0, s.mobs.map { DropRate(count: $0.value, of: kills[$0.key] ?? 0).range.lowerBound }.max() ?? 0)
        }
        return all.sorted { (key($0).0, key($0).1, $1.dungeon) > (key($1).0, key($1).1, $0.dungeon) }
    }

    /// The mobs killed in a dungeon, bosses first, then most kills.
    func mobs(in dungeon: String) -> [Mob] {
        kills.keys.filter { $0.dungeon == dungeon }
            .sorted { (bosses.contains($0.type) ? 1 : 0, kills[$0]!, $1.type) > (bosses.contains($1.type) ? 1 : 0, kills[$1]!, $0.type) }
    }
}

extension DropBag {
    /// An item's <BagType> in the game XML. 0-8 match the items looted in staging (Nov 2026).
    // shortcut: 9 (red) is inferred, no red bag item has dropped yet; correct it from the first one.
    init?(bagType: Int) {
        guard let bag = [DropBag.brown, .pink, .purple, .egg, .cyan, .blue, .white, .gold, .orange, .red].dropFirst(bagType).first,
              bagType >= 0 else { return nil }
        self = bag
    }
}

/// The game XML RealmHound extracts (assets/xml): names by type id, and the catalog the drop views
/// group mobs and items by (issue #40). Objects come in either attribute order: `type= id=` or `id= type=`.
enum GameNames {
    struct Object: Equatable {
        var type: Int, name: String
        var displayName: String? = nil   // <DisplayId>, unless it is a {translation.key}
        var objectClass: String? = nil, group: String? = nil
        var labels: [String] = []
        var quest = false, item = false
        var bagType: Int? = nil, slotType: Int? = nil, tier: Int? = nil
        var texture: GameTexture? = nil
        var dungeon: String? = nil   // a portal's <DungeonName>
    }

    static func objects(inXML text: String) -> [Object] {
        let xml = Array(text.utf8)
        // memmem over the bytes: Swift's string searches take seconds over RealmHound's 60 MB.
        func find(_ needle: String, _ from: Int, _ to: Int) -> Int? {
            guard from < to else { return nil }
            return xml.withUnsafeBytes { raw in
                let hit = needle.utf8CString.withUnsafeBytes { memmem(raw.baseAddress! + from, to - from, $0.baseAddress!, $0.count - 1) }
                return hit.map { raw.baseAddress!.distance(to: UnsafeRawPointer($0)) }
            }
        }
        func value(_ start: String, _ end: String, _ from: Int, _ to: Int) -> String? {
            guard let a = find(start, from, to), let b = find(end, a + start.utf8.count, to) else { return nil }
            return String(decoding: xml[(a + start.utf8.count)..<b], as: UTF8.self)
        }
        var objects: [Object] = []
        var next = find("<Object ", 0, xml.count)
        while let start = next {
            next = find("<Object ", start + 8, xml.count)
            let limit = next ?? xml.count
            guard let close = find(">", start, limit) else { continue }
            let end = find("</Object>", close, limit) ?? limit
            // From the space after "<Object", so " id=" also matches an id written first.
            guard let hex = value(" type=\"0x", "\"", start + 7, close), let type = Int(hex, radix: 16),
                  let name = value(" id=\"", "\"", start + 7, close) else { continue }
            func element(_ name: String) -> String? { value("<\(name)>", "</\(name)>", close, end) }
            func flag(_ name: String) -> Bool { find("<\(name) />", close, end) != nil || find("<\(name)/>", close, end) != nil }
            let display = element("DisplayId")
            // <Texture>, or the first frame of <AnimatedTexture>, either with attributes (xOffset=); Index is hex
            // (0xa7) or decimal.
            let texture = ["Texture", "AnimatedTexture"].lazy.compactMap { tag -> GameTexture? in
                guard let a = [find("<\(tag)>", close, end), find("<\(tag) ", close, end)].compactMap({ $0 }).min(),
                      let b = find("</\(tag)>", a, end),
                      let file = value("<File>", "</File>", a, b), let raw = value("<Index>", "</Index>", a, b) else { return nil }
                let index = raw.trimmingCharacters(in: .whitespaces)
                return (index.hasPrefix("0x") ? Int(index.dropFirst(2), radix: 16) : Int(index))
                    .map { GameTexture(file: file.trimmingCharacters(in: .whitespaces), index: $0) }
            }.first
            objects.append(Object(
                type: type, name: name, displayName: display?.hasPrefix("{") == true ? nil : display,
                objectClass: element("Class"), group: element("Group"),
                labels: element("Labels")?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } ?? [],
                quest: flag("Quest"), item: flag("Item"),
                bagType: element("BagType").flatMap { Int($0) }, slotType: element("SlotType").flatMap { Int($0) },
                tier: element("Tier").flatMap { Int($0) }, texture: texture, dungeon: element("DungeonName")))
        }
        return objects
    }
    static func names(inXML text: String) -> [Int: String] {
        objects(inXML: text).reduce(into: [:]) { $0[$1.type] = $1.name }
    }

    /// Rebuilds the `objects` and `items` tables when RealmHound's XML changed (a new game build).
    /// With no XML (RealmHound not installed) the last catalog stays. Returns whether it rebuilt.
    @discardableResult
    static func refreshCatalog(_ store: DropRateStore, folder: URL) -> Bool {
        let files = xmlFiles(folder)
        guard !files.isEmpty else { return false }
        let signature = files.map { file -> String in
            let v = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return "\(file.lastPathComponent) \(v?.fileSize ?? 0) \(v?.contentModificationDate?.timeIntervalSince1970 ?? 0)"
        }.joined(separator: "\n")
        var stored: String?
        store.run("SELECT signature FROM catalog_source") { stored = String(cString: sqlite3_column_text($0, 0)) }
        guard stored != signature else { return false }
        var objects: [Int: Object] = [:]   // a later file wins
        var templates: [String: [String]] = [:]
        for file in files {
            guard let data = try? Data(contentsOf: file) else { return false }   // half a catalog is worse than an old one
            let text = String(decoding: data, as: UTF8.self)
            for object in Self.objects(inXML: text) { objects[object.type] = object }
            // shortcut: templates are looked for only in dungeon*.xml (where the game keeps them), as a search of
            // every file costs seconds; widen it if a dungeon's drop tags go missing.
            if file.lastPathComponent.hasPrefix("dungeon") { templates.merge(dungeonTemplates(inXML: text)) { _, new in new } }
        }
        guard store.exec("BEGIN IMMEDIATE") else { store.failed = false; return false }
        store.failed = false
        store.exec("DELETE FROM objects; DELETE FROM items; DELETE FROM dungeons; DELETE FROM catalog_source")
        // A dungeon's portal: the lowest type whose <DungeonName> it is.
        var portals: [String: Object] = [:]
        for o in objects.values.sorted(by: { $0.type < $1.type }) where o.objectClass == "Portal" {
            if let name = o.dungeon, portals[name] == nil { portals[name] = o }
        }
        for name in Set(portals.keys).union(templates.keys) {
            let portal = portals[name]
            store.run("INSERT INTO dungeons(name, portal, texture_file, texture_index, labels) VALUES (?, ?, ?, ?, ?)",
                      [name, portal?.type, portal?.texture?.file, portal?.texture?.index, templates[name].map { "," + $0.joined(separator: ",") + "," }])
        }
        for o in objects.values {
            let labels = "," + o.labels.joined(separator: ",") + ","
            if o.item {
                let origins = o.labels.filter { $0.hasPrefix("ORG_") }.map { $0.dropFirst(4) }
                store.run("""
                    INSERT INTO items(type, name, display_name, bag_type, slot_type, tier, labels, origin, texture_file, texture_index)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [o.type, o.name, o.displayName, o.bagType, o.slotType, o.tier, labels,
                          origins.isEmpty ? nil : "," + origins.joined(separator: ",") + ",", o.texture?.file, o.texture?.index])
            } else {
                let minion = o.labels.first { $0.hasPrefix("MINION_") }?.dropFirst(7)
                store.run("""
                    INSERT INTO objects(type, name, display_name, class, group_name, boss, minion_class, drop_source, labels,
                        texture_file, texture_index) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """, [o.type, o.name, o.displayName, o.objectClass, o.group, o.quest || o.labels.contains("BOSSFIGHT") ? 1 : 0,
                          minion.map(String.init), o.objectClass == "Character" ? 1 : 0, labels, o.texture?.file, o.texture?.index])
            }
        }
        store.run("INSERT INTO catalog_source(signature) VALUES (?)", [signature])
        guard !store.failed, store.exec("COMMIT") else { store.exec("ROLLBACK"); store.failed = false; return false }
        return true
    }

    /// Each `<DungeonModTemplate id="name">`'s `<IncludedLabels>`, by dungeon name.
    static func dungeonTemplates(inXML text: String) -> [String: [String]] {
        text.components(separatedBy: "<DungeonModTemplate id=\"").dropFirst().reduce(into: [:]) { found, part in
            guard let name = part.components(separatedBy: "\"").first,
                  let body = part.components(separatedBy: "</DungeonModTemplate>").first,
                  let labels = body.components(separatedBy: "<IncludedLabels>").dropFirst().first?.components(separatedBy: "</IncludedLabels>").first
            else { return }
            found[name] = labels.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    private static func xmlFiles(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "xml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
