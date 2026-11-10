import Foundation
import SQLite3

/// Drop alerts read what RealmHound already logs: it sniffs the game's traffic and writes every
/// loot bag you see to a per-account SQLite file. This app only reads that file.

/// Loot bag colours, with RealmHound's object ids. Boosted bags count as their colour.
enum DropBag: String, CaseIterable {
    case brown, pink, purple, egg, teal, blue, gold, white, orange, red

    init?(id: Int) {
        switch id {
        case 1280, 1709: self = .brown
        case 1286, 1710: self = .pink
        case 1287, 1722: self = .purple
        case 1288, 1723: self = .egg
        case 1289, 1725: self = .teal
        case 1291, 1726: self = .blue
        case 1294, 1724: self = .gold
        case 1292, 1296: self = .white
        case 1295, 1727: self = .orange
        case 1708, 1728: self = .red
        default: return nil
        }
    }
    var name: String {
        switch self {
        case .egg: return "Egg basket"
        case .teal: return "Teal"
        case .orange: return "Orange (UT)"
        case .red: return "Red (ST)"
        default: return rawValue.capitalized
        }
    }
}

/// Item rarity is its number of enchantment slots, as RealmHound counts it (4 or more is Divine).
enum DropRarity: Int, CaseIterable {
    case common, uncommon, rare, legendary, divine
    init(enchants: Int) { self = DropRarity(rawValue: min(max(enchants, 0), 4))! }
    var name: String { ["Common", "Uncommon", "Rare", "Legendary", "Divine"][rawValue] }
}

struct DropAlertSettings: Equatable {
    var enabled = true
    var sound = true
    var bags: Set<DropBag> = [.white, .orange, .red]
    var minRarity = DropRarity.common
    /// Shiny items alert in any bag.
    var shiny = true
}

struct LootItem: Equatable {
    var id: Int
    var name: String
    var enchants: Int
}

struct LootDrop: Equatable {
    var id: Int64
    var epochMs: Int64
    var dungeon: String
    var mob: String
    var bag: Int
    var items: [LootItem]
}

/// What the drop popup shows.
struct DropAlert: Equatable {
    var item: String
    var bag: DropBag?
    var rarity: DropRarity
    var shiny: Bool
    var mob: String
    var dungeon: String

    var detail: String {
        var parts = [bag.map { "\($0.name) bag" } ?? "Bag"]
        if rarity != .common { parts.append(rarity.name) }
        if !mob.isEmpty { parts.append(mob) }
        return parts.joined(separator: " · ")
    }
}

enum DropRules {
    /// Drops older than this are not announced (an import or a catch-up after a pause, not a live drop).
    static let freshness: Int64 = 120_000
    /// How long the popup stays up.
    static let shown = 10.0

    /// An item alerts when its bag is chosen and it is at least the chosen rarity, or when it is
    /// shiny and shiny alerts are on. The popup names the best matching item.
    static func alert(for drop: LootDrop, settings: DropAlertSettings, shiny: Set<Int>, nowMs: Int64) -> DropAlert? {
        guard settings.enabled, nowMs - drop.epochMs <= freshness else { return nil }
        let bag = DropBag(id: drop.bag)
        let bagChosen = bag.map(settings.bags.contains) ?? false
        let matches = drop.items.compactMap { item -> DropAlert? in
            let rarity = DropRarity(enchants: item.enchants), isShiny = shiny.contains(item.id)
            guard (bagChosen && rarity.rawValue >= settings.minRarity.rawValue) || (settings.shiny && isShiny) else { return nil }
            return DropAlert(item: item.name, bag: bag, rarity: rarity, shiny: isShiny, mob: drop.mob, dungeon: drop.dungeon)
        }
        return matches.max { ($0.shiny ? 1 : 0, $0.rarity.rawValue) < ($1.shiny ? 1 : 0, $1.rarity.rawValue) }
    }
}

/// Item ids labelled SHINY in the game XML that RealmHound extracts (assets/xml/*.xml).
enum ShinyIndex {
    static func ids(inXML text: String) -> Set<Int> {
        guard text.contains("SHINY") else { return [] }
        var ids = Set<Int>()
        for chunk in text.components(separatedBy: "<Object ").dropFirst() {
            let object = chunk.components(separatedBy: "</Object>")[0]
            guard let labels = between(object, "<Labels>", "</Labels>"),
                  labels.split(separator: ",").contains(where: { $0.trimmingCharacters(in: .whitespaces) == "SHINY" }),
                  let tag = object.split(separator: ">", maxSplits: 1).first,
                  let hex = between(String(tag), "type=\"0x", "\""), let id = Int(hex, radix: 16)
            else { continue }
            ids.insert(id)
        }
        return ids
    }
    static func load(folder: URL) -> Set<Int> {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "xml" }.reduce(into: Set<Int>()) { ids, file in
            if let data = try? Data(contentsOf: file) { ids.formUnion(Self.ids(inXML: String(decoding: data, as: UTF8.self))) }
        }
    }
    private static func between(_ text: String, _ start: String, _ end: String) -> String? {
        guard let a = text.range(of: start), let b = text.range(of: end, range: a.upperBound..<text.endIndex) else { return nil }
        return String(text[a.upperBound..<b.lowerBound])
    }
}

/// RealmHound's folders. Each account it has seen keeps databases/loot_history.db.
enum RealmHoundPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RealmHound")
    static var accounts: URL { root.appendingPathComponent("accounts") }
    static var xml: URL { root.appendingPathComponent("assets/xml") }
}

/// Polls the loot logs for drops newer than the last one seen. A log seen for the first time only
/// sets the starting point, so old drops are never replayed.
final class LootLog {
    let accounts: URL
    private var last: [String: Int64] = [:]
    private(set) var logs = 0
    init(accounts: URL) { self.accounts = accounts }

    func poll() -> [LootDrop] {
        let folders = (try? FileManager.default.contentsOfDirectory(at: accounts, includingPropertiesForKeys: nil)) ?? []
        let paths = folders.map { $0.appendingPathComponent("databases/loot_history.db").path }
            .filter { FileManager.default.fileExists(atPath: $0) }
        logs = paths.count
        var found: [LootDrop] = []
        for path in paths {
            // Opened per poll and read-only: RealmHound writes in WAL mode, so reading never blocks it,
            // and a log it recreates is picked up.
            var db: OpaquePointer?
            defer { sqlite3_close(db) }
            guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { continue }
            sqlite3_busy_timeout(db, 200)
            guard let top = Self.maxID(db) else { continue }
            guard let seen = last[path], top >= seen else { last[path] = top; continue }  // first sight, or a reset log
            guard top > seen else { continue }
            found += Self.drops(db, after: seen, through: top)
            last[path] = top
        }
        return found
    }

    private static func maxID(_ db: OpaquePointer?) -> Int64? {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, "SELECT coalesce(max(id), 0) FROM loot_drops", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(statement, 0)
    }

    private static func drops(_ db: OpaquePointer?, after: Int64, through: Int64) -> [LootDrop] {
        let sql = """
            SELECT d.id, d.timestamp, d.dungeon, d.mob_name, d.bag_type, i.item_id, i.item_name, i.enchant_count
            FROM loot_drops d LEFT JOIN loot_items i ON i.drop_id = d.id
            WHERE d.id > ? AND d.id <= ? ORDER BY d.id, i.slot
            """
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_int64(statement, 1, after); sqlite3_bind_int64(statement, 2, through)
        func text(_ column: Int32) -> String { sqlite3_column_text(statement, column).map { String(cString: $0) } ?? "" }
        var drops: [LootDrop] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = sqlite3_column_int64(statement, 0)
            if drops.last?.id != id {
                drops.append(LootDrop(id: id, epochMs: sqlite3_column_int64(statement, 1), dungeon: text(2), mob: text(3),
                                      bag: Int(sqlite3_column_int(statement, 4)), items: []))
            }
            if sqlite3_column_type(statement, 5) != SQLITE_NULL {
                drops[drops.count - 1].items.append(LootItem(id: Int(sqlite3_column_int(statement, 5)), name: text(6),
                                                             enchants: Int(sqlite3_column_int(statement, 7))))
            }
        }
        return drops
    }
}
