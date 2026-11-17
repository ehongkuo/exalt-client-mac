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
        sqlite3_busy_timeout(db, 2000)
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

/// Today's capture at a glance: what the Today view shows, and how a staging run is checked.
/// Rates and the counting rules (a kill's top bag class) come with the rates view.
struct DropDay: Equatable {
    struct Mob: Hashable { var type: Int, map: String, kills: Int, bags: [DropBag: Int] }
    struct Notable: Hashable {
        var time: Double, bag: DropBag, mob: Int?, items: [Int]
        var enchants: [Int?] = []   // per item; nil where the bag's enchantment text is missing or cut short
    }
    var kills = 0, bags = 0, linked = 0, lost = 0
    var refused: String?
    var mobs: [Mob] = []
    var notable: [Notable] = []

    static let notableBags: Set<DropBag> = [.white, .orange, .red]

    /// A mob you damaged, removed soon after the last hit: a death. A later removal is usually a mob
    /// that left your view.
    // shortcut: 1 s is a guess from tick and round-trip time; set it from staging run 2's removals
    // that left a bag.
    static let died = """
        (k.damage_projectile + k.damage_projectile_alt + k.damage_ability > 0 \
        AND (k.landed_by <> 'removed' OR k.since_hit_ms <= 1000))
        """

    static func load(_ store: DropRateStore, since: Double, mobLimit: Int = 20) -> DropDay {
        var day = DropDay()
        store.run("SELECT count(*) FROM kills k WHERE k.time >= ? AND \(died)", [since]) { day.kills = Int(sqlite3_column_int64($0, 0)) }
        store.run("SELECT count(*), count(kill) FROM bags WHERE time >= ?", [since]) {
            day.bags = Int(sqlite3_column_int64($0, 0)); day.linked = Int(sqlite3_column_int64($0, 1))
        }
        store.run("SELECT coalesce(sum(lost), 0) FROM capture_gaps WHERE time >= ?", [since]) { day.lost = Int(sqlite3_column_int64($0, 0)) }
        // Only the latest game counts: a refusal from an earlier game today is gone once a later one captures.
        store.run("SELECT status FROM (SELECT status FROM sessions WHERE started >= ? ORDER BY id DESC LIMIT 1) WHERE status LIKE 'refused%'", [since - 86400]) {
            day.refused = String(cString: sqlite3_column_text($0, 0))
        }
        store.run("""
            SELECT k.mob_type, coalesce(m.name, ''), count(*) FROM kills k JOIN maps m ON m.id = k.map
            WHERE k.time >= ? AND \(died) GROUP BY k.mob_type, m.name ORDER BY count(*) DESC LIMIT ?
            """, [since, mobLimit]) {
            day.mobs.append(Mob(type: Int(sqlite3_column_int64($0, 0)), map: String(cString: sqlite3_column_text($0, 1)),
                                kills: Int(sqlite3_column_int64($0, 2)), bags: [:]))
        }
        // Kills that left a bag of each colour (an overflow second bag of the same colour counts once).
        store.run("""
            SELECT k.mob_type, coalesce(m.name, ''), b.bag_type, count(DISTINCT k.id) FROM bags b
            JOIN kills k ON k.id = b.kill JOIN maps m ON m.id = k.map WHERE k.time >= ? GROUP BY 1, 2, 3
            """, [since]) {
            let type = Int(sqlite3_column_int64($0, 0)), map = String(cString: sqlite3_column_text($0, 1))
            guard let bag = DropBag(id: Int(sqlite3_column_int64($0, 2))),
                  let i = day.mobs.firstIndex(where: { $0.type == type && $0.map == map }) else { return }
            day.mobs[i].bags[bag, default: 0] += Int(sqlite3_column_int64($0, 3))
        }
        store.run("""
            SELECT b.time, b.bag_type, k.mob_type, group_concat(i.slot || ':' || i.item_type),
                (SELECT text FROM bag_stats s WHERE s.bag = b.id AND s.stat_type = 80) FROM bags b
            LEFT JOIN kills k ON k.id = b.kill LEFT JOIN bag_items i ON i.bag = b.id
            WHERE b.time >= ? GROUP BY b.id ORDER BY b.time DESC
            """, [since]) {
            guard day.notable.count < 10, let bag = DropBag(id: Int(sqlite3_column_int64($0, 1))), notableBags.contains(bag) else { return }
            let slots = (sqlite3_column_text($0, 3).map { String(cString: $0) } ?? "").split(separator: ",")
                .compactMap { pair -> (Int, Int)? in
                    let p = pair.split(separator: ":").compactMap { Int($0) }
                    return p.count == 2 ? (p[0], p[1]) : nil
                }.sorted { $0.0 < $1.0 }
            let enchants = Enchantments.counts(sqlite3_column_text($0, 4).map { String(cString: $0) } ?? "")
            day.notable.append(Notable(time: sqlite3_column_double($0, 0), bag: bag,
                                       mob: sqlite3_column_type($0, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64($0, 2)),
                                       items: slots.map(\.1), enchants: slots.map { $0.0 < enchants.count ? enchants[$0.0] : nil }))
        }
        return day
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
/// (Poisson, docs/drop-rates-investigation.md section 4). Under 10 drops it reads as rough.
struct DropRate: Equatable {
    var count: Int, of: Int
    var rate: Double { of > 0 ? Double(count) / Double(of) : 0 }
    var rough: Bool { count < 10 }
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
/// - A kill is `DropDay.died`; its drops are the items in bags linked to it (`bags.kill`).
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
    var runsWith: [String: [Int: Int]] = [:]        // dungeon → item → runs with at least one copy
    /// dungeon → boss type (nil: any boss) → runs whose best bag from it was that colour.
    var bossBags: [String: [Int?: [DropBag: Int]]] = [:]
    var itemBag: [Int: DropBag] = [:]               // the highest bag colour each item came in
    /// mob → item → copies by `DropRarity`. A copy with no rarity counts in none: the bag's stat 80 has no part for it
    /// (potions, stones and other items without enchantments) or the part was cut short.
    var rarity: [Mob: [Int: [Int]]] = [:]
    /// One copy from a kill, for Ask a question: the bag it came in, and its enchantments (nil: no rarity).
    struct Copy: Hashable { var mob: Mob, map: Int, item: Int, bag: DropBag?, enchants: Int? }
    var drops: [Copy] = []
    var runMaps: Set<Int> = []                      // the map visits that are runs
    var labels: [Int: String] = [:]                 // item labels from the catalog, wrapped in commas
    var names: [Int: String] = [:]
    var bosses: Set<Int> = []
    var textures: [Int: GameTexture] = [:]

    /// A bag object type's place in `DropBag.allCases` (higher is better), as SQL over `bags b`.
    static let rank = "CASE b.bag_type " + (1200...1800).compactMap { id in
        DropBag(id: id).map { "WHEN \(id) THEN \(DropBag.allCases.firstIndex(of: $0)!)" }
    }.joined(separator: " ") + " END"

    static func load(_ store: DropRateStore) -> DropReport {
        var r = DropReport()
        let died = DropDay.died, rank = Self.rank
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
            SELECT k.mob_type, coalesce(m.name, ''), i.item_type, i.slot, b.id, k.map, b.bag_type,
                (SELECT text FROM bag_stats s WHERE s.bag = b.id AND s.stat_type = 80) FROM bag_items i JOIN bags b ON b.id = i.bag
            JOIN kills k ON k.id = b.kill JOIN maps m ON m.id = k.map WHERE \(died)
            """) {
            let bag = int($0, 4), slot = int($0, 3)
            let counts = decoded[bag] ?? Enchantments.counts(text($0, 7))
            decoded[bag] = counts
            let mob = Mob(type: int($0, 0), dungeon: text($0, 1)), item = int($0, 2), n = slot < counts.count ? counts[slot] : nil
            r.drops.append(Copy(mob: mob, map: int($0, 5), item: item, bag: DropBag(id: int($0, 6)), enchants: n))
            if let n { r.rarity[mob, default: [:]][item, default: [0, 0, 0, 0, 0]][DropRarity(enchants: n).rawValue] += 1 }
        }
        store.run("\(runs) SELECT runs.map, coalesce(m.name, '') FROM runs JOIN maps m ON m.id = runs.map") {
            r.runMaps.insert(int($0, 0)); r.runs[text($0, 1), default: 0] += 1
        }
        store.run("""
            \(runs) SELECT coalesce(m.name, ''), i.item_type, count(DISTINCT k.map) FROM bag_items i JOIN bags b ON b.id = i.bag
            JOIN kills k ON k.id = b.kill JOIN maps m ON m.id = k.map WHERE \(died) AND k.map IN (SELECT map FROM runs) GROUP BY 1, 2
            """) { r.runsWith[text($0, 0), default: [:]][int($0, 1)] = int($0, 2) }
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
            SELECT type, coalesce(display_name, name), boss, texture_file, texture_index, NULL FROM objects
            WHERE type IN (SELECT mob_type FROM kills) UNION ALL
            SELECT type, coalesce(display_name, name), 0, texture_file, texture_index, labels FROM items
            WHERE type IN (SELECT item_type FROM bag_items)
            """) {
            let type = int($0, 0)
            r.names[type] = text($0, 1)
            if sqlite3_column_type($0, 5) != SQLITE_NULL { r.labels[type] = text($0, 5) }
            if int($0, 2) != 0 { r.bosses.insert(type) }
            if sqlite3_column_type($0, 3) != SQLITE_NULL { r.textures[type] = GameTexture(file: text($0, 3), index: int($0, 4)) }
        }
        return r
    }

    func name(_ type: Int) -> String { names[type] ?? String(format: "#0x%04x", type) }
    /// The best rarity (as an enchantment count) of any copy of an item, from every mob or one dungeon's; nil when none was read.
    func bestEnchants(_ item: Int, dungeon: String? = nil, mob: Mob? = nil) -> Int? {
        rarity.filter { (dungeon == nil || $0.key.dungeon == dungeon) && (mob == nil || $0.key == mob) }.compactMap { $0.value[item]?.lastIndex { $0 > 0 } }.max()
    }
    /// Copies of an item by rarity, from one mob or every mob.
    func rarityCounts(_ item: Int, mob: Mob? = nil) -> [Int] {
        rarity.filter { mob == nil || $0.key == mob }.compactMap { $0.value[item] }.reduce([0, 0, 0, 0, 0]) { zip($0, $1).map(+) }
    }

    /// Ask a question (issue #45): matching copies over kills, runs (runs with at least one) or white bags.
    /// `unread`: copies that matched all but a chosen rarity, and have no rarity. A white bag item is a copy that came in one.
    struct Answer: Equatable { var rate: DropRate, unit: String, unread: Int }
    func answer(_ q: DropQuestion) -> Answer {
        func matches(_ copy: Copy) -> Bool {
            let l = labels[copy.item] ?? ""
            switch q.item {
            case DropQuestion.anyUT: return l.contains(",UT,")
            case DropQuestion.anySTRobe: return l.contains(",ST,") && l.contains(",ROBE,")
            case DropQuestion.anyWhite: return copy.bag == .white
            default: return name(copy.item) == q.item
            }
        }
        func source(_ mob: Mob) -> Bool {
            (q.from == nil || mob.dungeon == q.from) && (q.mobs == .any || bosses.contains(mob.type) == (q.mobs == .bosses))
        }
        let found = drops.filter { source($0.mob) && matches($0) }
        let hits = q.rarity.map { r in found.filter { $0.enchants.map(DropRarity.init(enchants:)) == r } } ?? found
        let unread = q.rarity == nil ? 0 : found.filter { $0.enchants == nil }.count
        let mobs = kills.keys.filter(source)
        switch q.per {
        case .kill: return Answer(rate: DropRate(count: hits.count, of: mobs.reduce(0) { $0 + kills[$1]! }), unit: "kills", unread: unread)
        case .white:
            return Answer(rate: DropRate(count: hits.count, of: mobs.reduce(0) { $0 + (bestBag[$1]?[.white] ?? 0) }), unit: "white bags", unread: unread)
        case .run:
            return Answer(rate: DropRate(count: Set(hits.map(\.map)).intersection(runMaps).count,
                                         of: Set(mobs.map(\.dungeon)).reduce(0) { $0 + (runs[$1] ?? 0) }), unit: "runs", unread: unread)
        }
    }
    /// Copies of an item from every mob.
    func dropped(_ item: Int) -> Int { copies.values.reduce(0) { $0 + ($1[item] ?? 0) } }
    /// Every item dropped, by name.
    var items: [Int] { Set(copies.values.flatMap(\.keys)).sorted { name($0) < name($1) } }
    /// Dungeons with a run, most runs first.
    var dungeons: [String] { runs.keys.sorted { (runs[$0]!, $1) > (runs[$1]!, $0) } }
}

/// A question for Ask a question: what dropped (an item's name or a kind), its rarity, from where and which mobs, per what.
struct DropQuestion: Equatable {
    enum Mobs: String, CaseIterable { case any = "Any mob", bosses = "Bosses", minions = "Minions" }
    enum Per: String, CaseIterable { case kill = "Kill", run = "Run", white = "White bag" }
    static let anyUT = "Any UT", anySTRobe = "Any ST robe", anyWhite = "Any white bag item"
    var item: String
    var rarity: DropRarity? = nil   // nil: any
    var from: String? = nil         // a dungeon; nil: anywhere
    var mobs = Mobs.any
    var per = Per.kill

    static let presets: [(String, DropQuestion)] = [
        ("Chance of a Bow of the Void per Void run", DropQuestion(item: "Bow of the Void", from: "The Void", per: .run)),
        ("Chance a white bag is legendary", DropQuestion(item: anyWhite, rarity: .legendary, per: .white)),
        ("Legendary ST robe from an Abyss mob", DropQuestion(item: anySTRobe, rarity: .legendary, from: "Abyss of Demons")),
        ("Any UT from Lost Halls bosses", DropQuestion(item: anyUT, from: "Lost Halls", mobs: .bosses)),
    ]
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
                tier: element("Tier").flatMap { Int($0) }, texture: texture))
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
        for file in files {
            guard let data = try? Data(contentsOf: file) else { return false }   // half a catalog is worse than an old one
            for object in Self.objects(inXML: String(decoding: data, as: UTF8.self)) { objects[object.type] = object }
        }
        guard store.exec("BEGIN IMMEDIATE") else { store.failed = false; return false }
        store.failed = false
        store.exec("DELETE FROM objects; DELETE FROM items; DELETE FROM catalog_source")
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

    private static func xmlFiles(_ folder: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "xml" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
