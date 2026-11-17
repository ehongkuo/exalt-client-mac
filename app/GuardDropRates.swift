import Foundation
import SQLite3

/// Drop-rate capture (issue #38). The guard writes every kill of a mob you damaged and every bag to
/// logs/loot-<started>-<pid>.tsv (guard/loot_core.h has the columns). This imports those lines into
/// drop_rates.db and removes each file once it is fully imported and its game has ended.
/// Nothing here computes a rate: the rows stay raw so any later question can be asked of them.

struct LootKill: Equatable {
    var time: Double, generation: Int, object: Int, type: Int
    var x: Double, y: Double, z: Double
    var projectile: Int, projectileAlt: Int, ability: Int, maxHP: Int
    var landedBy: String
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
            guard f.count == 13, let t = d(1), let g = n(2), let o = n(3), let ty = n(4), let x = d(5), let y = d(6), let z = d(7),
                  let p = n(8), let pa = n(9), let a = n(10), let hp = n(11) else { return nil }
            self = .kill(LootKill(time: t, generation: g, object: o, type: ty, x: x, y: y, z: z,
                                  projectile: p, projectileAlt: pa, ability: a, maxHP: hp, landedBy: f[12]))
        case "bag":
            let items = (7..<15).compactMap(n)
            guard f.count == 15, items.count == 8, let t = d(1), let g = n(2), let o = n(3), let ty = n(4), let x = d(5), let y = d(6)
            else { return nil }
            self = .bag(LootBag(time: t, generation: g, object: o, type: ty, x: x, y: y, items: items))
        case "bag_stat":
            guard let t = d(1), let g = n(2), let o = n(3), let s = n(4), let v = n(5) else { return nil }
            self = .bagStat(time: t, generation: g, object: o, stat: s, value: v, text: f.count > 6 ? f[6] : "")
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

enum LootLink {
    /// The kill a bag came from: same map, up to 2 s before the bag, nearest within one tile.
    /// Only position can tell which mob dropped what when one blast kills several at once.
    // shortcut: tries every candidate axis mapping of the kill's float3 (the bag is tile x, y);
    // narrow to the right one once a staging run shows which matches.
    static func nearest(_ bag: LootBag, among kills: [(id: Int64, time: Double, x: Double, y: Double, z: Double)]) -> Int64? {
        var best: (id: Int64, distance: Double)?
        for k in kills where k.time <= bag.time + 0.25 && k.time >= bag.time - 2 {
            let distance = [k.y, -k.y, k.z, -k.z].map { hypot(k.x - bag.x, $0 - bag.y) }.min()!
            if distance <= 1, distance < best?.distance ?? .infinity { best = (k.id, distance) }
        }
        return best?.id
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
        CREATE INDEX IF NOT EXISTS kills_mob ON kills(mob_type);
        CREATE INDEX IF NOT EXISTS kills_map_time ON kills(map, time);
        CREATE INDEX IF NOT EXISTS bags_kill ON bags(kill);
        CREATE INDEX IF NOT EXISTS bags_map_object ON bags(map, object_id);
        CREATE INDEX IF NOT EXISTS bag_items_item ON bag_items(item_type);
        PRAGMA user_version = 1;
        """

    init?(path: String) {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let handle else {
            sqlite3_close(handle); return nil
        }
        db = handle
        sqlite3_busy_timeout(db, 2000)
        guard sqlite3_exec(db, Self.schema, nil, nil, nil) == SQLITE_OK else { return nil }
    }
    deinit { sqlite3_close(db) }

    @discardableResult func exec(_ sql: String) -> Bool { sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK }

    /// Runs one statement; calls `row` for each result row. Values are Int, Int64, Double, String or nil.
    @discardableResult
    func run(_ sql: String, _ values: [Any?] = [], row: ((OpaquePointer) -> Void)? = nil) -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return false }
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
            default: return false
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
            store.exec("BEGIN")
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
                            damage_ability, max_hp, landed_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """, [map(k.generation, k.time), k.time, k.object, k.type, k.x, k.y, k.z,
                              k.projectile, k.projectileAlt, k.ability, k.maxHP, k.landedBy])
                    last = k.time
                case let .bag(b):
                    let mapID = map(b.generation, b.time)
                    var kills: [(id: Int64, time: Double, x: Double, y: Double, z: Double)] = []
                    store.run("SELECT id, time, x, y, z FROM kills WHERE map = ? AND time BETWEEN ? AND ?",
                              [mapID, b.time - 2, b.time + 0.25]) {
                        kills.append((sqlite3_column_int64($0, 0), sqlite3_column_double($0, 1), sqlite3_column_double($0, 2),
                                      sqlite3_column_double($0, 3), sqlite3_column_double($0, 4)))
                    }
                    let kill = LootLink.nearest(b, among: kills)
                    store.run("INSERT INTO bags(map, time, object_id, bag_type, x, y, kill) VALUES (?, ?, ?, ?, ?, ?, ?)",
                              [mapID, b.time, b.object, b.type, b.x, b.y, kill])
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
            guard store.exec("COMMIT") else { store.exec("ROLLBACK"); return 0 }
        }
        // A file is done when its game has ended: every whole line is in, and a cut-off last line never completes.
        if status == "complete" || !alive(pid) {
            try? FileManager.default.removeItem(at: url)
        }
        return stored
    }
}
