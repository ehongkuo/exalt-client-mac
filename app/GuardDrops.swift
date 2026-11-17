import CoreGraphics
import Foundation
import ImageIO
import SQLite3

/// Drop alerts read what RealmHound already logs: it sniffs the game's traffic and writes every
/// loot bag you see to a per-account SQLite file. This app only reads that file.

/// Loot bag colours from lowest to highest priority, as on RealmEye's Loot Containers page
/// (Exalt 5.12, June 2025), with RealmHound's object ids. Boosted bags count as their colour.
enum DropBag: String, CaseIterable {
    // Cyan keeps the saved name "teal" (RealmHound's name for it).
    case brown, pink, purple, egg, cyan = "teal", blue, gold, orange, red, white

    init?(id: Int) {
        switch id {
        case 1280, 1709: self = .brown
        case 1286, 1710: self = .pink
        case 1287, 1722: self = .purple
        case 1288, 1723: self = .egg
        case 1289, 1725: self = .cyan
        case 1291, 1726: self = .blue
        case 1292, 1296: self = .white
        case 1294, 1724: self = .gold
        case 1295, 1727: self = .orange
        case 1708, 1728: self = .red
        default: return nil
        }
    }
    var name: String { self == .egg ? "Egg basket" : "\(String(describing: self).capitalized) bag" }
    /// What the game puts in this bag: each item's <BagType> in the game XML (Nov 2026).
    var holds: String {
        switch self {
        case .brown: return "Minor potions"
        case .pink: return "Tiers 0–6"
        case .purple: return "Tiers 7–9, dyes, fragments"
        case .egg: return "Pet eggs"
        case .cyan: return "Tiers 10–12, common UTs"
        case .blue: return "Stat potions, Life and Mana"
        case .white: return "Untiered (UT), most shinies"
        case .gold: return "Skins, pet stones, keys, forge materials"
        case .orange: return "Set items (ST), quest chests"
        case .red: return "Tiers 13–14, top UTs"
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
        var parts = [bag?.name ?? "Bag"]
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

/// Which monitor the drop popup goes on: the one holding most of the game window.
enum PopupScreen {
    /// The index of the screen that overlaps `window` most, or nil when there is no window or no overlap.
    /// All rects must use the same coordinates (CGWindowList and CGDisplayBounds both use top-left global ones).
    static func index(window: CGRect?, screens: [CGRect]) -> Int? {
        guard let window else { return nil }
        let areas = screens.map { s -> CGFloat in let i = s.intersection(window); return i.isNull ? 0 : i.width * i.height }
        guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else { return nil }
        return best
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

/// Bag sprites, cut at run time from the game art RealmHound extracts. The art is DECA's, so this
/// repo carries none of it.
enum BagSprites {
    /// Each bag's index in the game's lofiObj4 sheet (the <Texture> in ObjectID.list).
    static func index(_ bag: DropBag) -> Int {
        switch bag {
        case .brown: return 0xd0
        case .pink: return 0xd1
        case .purple: return 0xd2
        case .egg: return 0xd3
        case .gold: return 0xd4
        case .cyan: return 0xd5
        case .blue: return 0xd6
        case .orange: return 0xd7
        case .red: return 0xd8
        case .white: return 0xd9
        }
    }

    static func load(assets: URL) -> [DropBag: CGImage] {
        GameSprites.load(assets: assets, Dictionary(uniqueKeysWithValues: DropBag.allCases.map { ($0, GameTexture(file: "lofiObj4", index: index($0))) }))
    }
}

/// A game object's sprite: its `<Texture>` (or `<AnimatedTexture>`) sheet and index in the game XML.
struct GameTexture: Hashable { var file: String, index: Int }

/// Mob and item sprites, cut at run time from the game art RealmHound extracts, like the bag sprites.
enum GameSprites {
    struct Sprite: Equatable { var atlas: Int, rect: CGRect }
    /// The atlas PNG of each atlas id in the sprite flatbuffer.
    static let atlases = [1: "groundTiles.png", 2: "characters.png", 4: "mapObjects.png"]

    /// Crops each texture from its atlas (each about 130 MB decoded, so call it off the main thread). Textures
    /// the flatbuffer lacks are left out; empty when RealmHound's assets are missing.
    static func load<Key: Hashable>(assets: URL, _ textures: [Key: GameTexture]) -> [Key: CGImage] {
        guard let data = try? Data(contentsOf: assets.appendingPathComponent("flatbuffer/spritesheetf")) else { return [:] }
        let sheets = rects(in: data)
        let wanted = textures.compactMapValues { sheets[$0.file]?[$0.index] }
        var out: [Key: CGImage] = [:]
        for (atlas, file) in atlases {
            let mine = wanted.filter { $0.value.atlas == atlas }
            guard !mine.isEmpty, let source = CGImageSourceCreateWithURL(assets.appendingPathComponent("sprites/\(file)") as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { continue }
            for (key, sprite) in mine {
                guard let crop = image.cropping(to: sprite.rect),
                      let ctx = CGContext(data: nil, width: crop.width, height: crop.height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
                else { continue }
                // Copied out, so the small sprite does not keep the whole atlas in memory.
                ctx.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
                out[key] = ctx.makeImage()
            }
        }
        return out
    }

    /// Sprite rectangles in the game's sprite flatbuffer, by sheet name and index, with the atlas each sits in.
    /// Layout as RealmHound reads it (sprite_atlas.rs): the root's field 0 lists sheets (name, -, sprites); a
    /// sprite has position {x, y, w, h} as floats (field 0), index (field 3) and atlas id (field 7). The root's
    /// field 1 lists animation frames (sheet name, index (1), action (4), sprite (5)); a mob's first standing
    /// frame (action 0) stands for it. Every read is bounds-checked: the file is not ours.
    // shortcut: an animated sheet that shares a name with a static one (only Rookie_16x16 and Rookie_24x24 in
    // Nov 2026) loses to it; keep <AnimatedTexture> apart in the catalog if those mobs show the wrong sprite.
    static func rects(in data: Data) -> [String: [Int: Sprite]] {
        let b = [UInt8](data)
        func int(_ p: Int, _ n: Int) -> Int? {
            guard p >= 0, p + n <= b.count else { return nil }
            return (0..<n).reduce(0) { $0 | Int(b[p + $1]) << (8 * $1) }
        }
        func field(_ table: Int, _ i: Int) -> Int? {
            guard let back = int(table, 4) else { return nil }
            let vtable = table - Int(Int32(truncatingIfNeeded: back))
            guard let size = int(vtable, 2), 4 + 2 * i < size, let offset = int(vtable + 4 + 2 * i, 2), offset != 0 else { return nil }
            return table + offset
        }
        func ref(_ p: Int?) -> Int? { p.flatMap { p in int(p, 4).map { p + $0 } } }
        func tables(_ p: Int?) -> [Int] {
            guard let v = ref(p), let n = int(v, 4), v + 4 + 4 * n <= b.count else { return [] }
            return (0..<n).compactMap { ref(v + 4 + 4 * $0) }
        }
        func name(_ table: Int) -> String? {
            guard let s = ref(field(table, 0)), let n = int(s, 4), s + 4 + n <= b.count else { return nil }
            return String(decoding: b[(s + 4)..<(s + 4 + n)], as: UTF8.self)
        }
        func number(_ table: Int, _ i: Int) -> Int { field(table, i).flatMap { int($0, 4) }.map { Int(Int32(truncatingIfNeeded: $0)) } ?? 0 }
        func float(_ p: Int) -> CGFloat { CGFloat(Float(bitPattern: UInt32(int(p, 4) ?? 0))) }
        func sprite(_ table: Int) -> Sprite? {
            guard let p = field(table, 0), p + 16 <= b.count else { return nil }
            return Sprite(atlas: number(table, 7), rect: CGRect(x: float(p), y: float(p + 4), width: float(p + 8), height: float(p + 12)))
        }
        guard let root = int(0, 4) else { return [:] }
        var out: [String: [Int: Sprite]] = [:]
        for sheet in tables(field(root, 0)) {
            guard let name = name(sheet) else { continue }
            for table in tables(field(sheet, 2)) { out[name, default: [:]][number(table, 3)] = sprite(table) }
        }
        for frame in tables(field(root, 1)) where number(frame, 4) == 0 {
            guard let name = name(frame), out[name]?[number(frame, 1)] == nil, let sprite = ref(field(frame, 5)).flatMap(sprite) else { continue }
            out[name, default: [:]][number(frame, 1)] = sprite
        }
        return out
    }
}

/// RealmHound's folders. Each account it has seen keeps databases/loot_history.db.
enum RealmHoundPaths {
    static let root = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/RealmHound")
    static var accounts: URL { root.appendingPathComponent("accounts") }
    static var assets: URL { root.appendingPathComponent("assets") }
    static var xml: URL { assets.appendingPathComponent("xml") }
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
