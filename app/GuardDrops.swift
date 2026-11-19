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
enum DropRarity: Int, CaseIterable, Codable {
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
    /// Item rules (issue #47) alert in any bag, alongside the filters above.
    var rules: [ItemRule] = []
}

extension DropAlertSettings {
    init(defaults: UserDefaults) {
        if let v = defaults.object(forKey: "dropAlerts") as? Bool { enabled = v }
        if let v = defaults.object(forKey: "dropAlertSound") as? Bool { sound = v }
        if let v = defaults.stringArray(forKey: "dropAlertBags") { bags = Set(v.compactMap(DropBag.init(rawValue:))) }
        if let v = defaults.object(forKey: "dropAlertRarity") as? Int, let r = DropRarity(rawValue: v) { minRarity = r }
        if let v = defaults.object(forKey: "dropAlertShiny") as? Bool { shiny = v }
        if let v = defaults.data(forKey: "dropAlertRules"), let r = try? JSONDecoder().decode([ItemRule].self, from: v) { rules = r }
    }
    func save(to defaults: UserDefaults) {
        defaults.set(enabled, forKey: "dropAlerts")
        defaults.set(sound, forKey: "dropAlertSound")
        defaults.set(bags.map(\.rawValue).sorted(), forKey: "dropAlertBags")
        defaults.set(minRarity.rawValue, forKey: "dropAlertRarity")
        defaults.set(shiny, forKey: "dropAlertShiny")
        defaults.set(try? JSONEncoder().encode(rules), forKey: "dropAlertRules")
    }
}

/// An item rule (issue #47): every part that is set must match. Blank text, nil and Common mean any part;
/// a rule with nothing set matches nothing, and a rule alerts only once it is confirmed.
struct ItemRule: Codable, Hashable, Identifiable {
    var id = UUID()
    /// What the alert calls the rule; blank shows no rule name.
    var title = ""
    /// A draft is still being edited and never alerts.
    var confirmed = false
    /// Parts of the item's name, any case: any one of them matches.
    var names: [String] = []
    /// The item's <SlotType>.
    var slot: Int? = nil
    /// A class that can equip the item: its weapon, ability, armor or ring.
    var playerClass: String? = nil
    /// Untiered items (UTs, STs) never reach a minimum tier.
    var minTier: Int? = nil
    var minRarity = DropRarity.common
    /// Parts of enchantment names, any case: "Attack Bonus" matches I, II and III.
    var enchants: [String] = []
    /// The item needs every enchantment in `enchants` (true) or any one of them.
    var allEnchants = true

    /// The item types to choose from: <SlotType> values in the game XML (Nov 2026). 10 is consumables, left out.
    static let types: [(slot: Int, name: String)] = [
        (1, "Sword"), (2, "Dagger"), (3, "Bow"), (4, "Tome"), (5, "Shield"), (6, "Leather armor"), (7, "Heavy armor"),
        (8, "Wand"), (9, "Ring"), (11, "Spell"), (12, "Seal"), (13, "Cloak"), (14, "Robe"), (15, "Quiver"), (16, "Helm"),
        (17, "Staff"), (18, "Poison"), (19, "Skull"), (20, "Trap"), (21, "Orb"), (22, "Prism"), (23, "Scepter"),
        (24, "Katana"), (25, "Star"), (26, "Pet egg"), (27, "Wakizashi"), (28, "Lute"), (29, "Mace"), (30, "Sheath"),
        (31, "Sigil"),
    ].sorted { $0.name < $1.name }

    /// What each class equips: the first four <SlotTypes> of its player object in players.xml (Nov 2026).
    static let classes: [String: [Int]] = [
        "Rogue": [2, 13, 6, 9], "Archer": [3, 15, 6, 9], "Wizard": [17, 11, 14, 9], "Priest": [8, 4, 14, 9],
        "Warrior": [1, 16, 7, 9], "Knight": [1, 5, 7, 9], "Paladin": [1, 12, 7, 9], "Assassin": [2, 18, 6, 9],
        "Necromancer": [17, 19, 14, 9], "Huntress": [3, 20, 6, 9], "Mystic": [17, 21, 14, 9], "Trickster": [2, 22, 6, 9],
        "Sorcerer": [8, 23, 14, 9], "Ninja": [24, 25, 6, 9], "Samurai": [24, 27, 7, 9], "Bard": [3, 28, 14, 9],
        "Summoner": [8, 29, 14, 9], "Kensei": [24, 30, 7, 9], "Druid": [8, 31, 6, 9],
    ]

    /// Nothing set: the rule would match nothing.
    var isBlank: Bool {
        Self.terms(names).isEmpty && slot == nil && playerClass == nil && minTier == nil && minRarity == .common && Self.terms(enchants).isEmpty
    }

    /// The set parts in one line, for a confirmed rule: "Tome · Tier 4+ · Lucky Streak".
    var summary: String {
        var parts: [String] = []
        let names = Self.terms(names), enchants = Self.terms(enchants)
        if !names.isEmpty { parts.append(names.map { "“\($0)”" }.joined(separator: " or ")) }
        if let slot { parts.append(Self.types.first { $0.slot == slot }?.name ?? "Type \(slot)") }
        if let playerClass { parts.append("\(playerClass) gear") }
        if let minTier { parts.append("Tier \(minTier)+") }
        if minRarity != .common { parts.append(minRarity.name) }
        if !enchants.isEmpty { parts.append(enchants.joined(separator: allEnchants ? " and " : " or ")) }
        return parts.joined(separator: " · ")
    }

    func matches(_ item: LootItem, catalog: RuleCatalog) -> Bool {
        guard confirmed, !isBlank else { return false }
        let names = Self.terms(names), enchants = Self.terms(enchants)
        let info = catalog.items[item.id]
        if !names.isEmpty, !names.contains(where: item.name.localizedCaseInsensitiveContains) { return false }
        if let slot, info?.slot != slot { return false }
        if let playerClass, !(info?.slot.map { Self.classes[playerClass]?.contains($0) == true } ?? false) { return false }
        if let minTier, (info?.tier ?? -1) < minTier { return false }
        if DropRarity(enchants: item.enchants).rawValue < minRarity.rawValue { return false }
        // A term that is a whole enchantment name ("Loot Bonus I") means that one, not II to IV as well.
        func has(_ term: String) -> Bool {
            let exact = catalog.enchants.values.contains { $0.caseInsensitiveCompare(term) == .orderedSame }
            return item.enchantIds.contains {
                guard let n = catalog.enchants[$0] else { return false }
                return exact ? n.caseInsensitiveCompare(term) == .orderedSame : n.localizedCaseInsensitiveContains(term)
            }
        }
        if !enchants.isEmpty, allEnchants ? !enchants.allSatisfy(has) : !enchants.contains(where: has) { return false }
        return true
    }
}

extension ItemRule {
    /// Rules saved before titles and drafts existed load as confirmed, so their alerts keep working.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        confirmed = try c.decodeIfPresent(Bool.self, forKey: .confirmed) ?? true
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        slot = try c.decodeIfPresent(Int.self, forKey: .slot)
        playerClass = try c.decodeIfPresent(String.self, forKey: .playerClass)
        minTier = try c.decodeIfPresent(Int.self, forKey: .minTier)
        minRarity = try c.decodeIfPresent(DropRarity.self, forKey: .minRarity) ?? .common
        enchants = try c.decodeIfPresent([String].self, forKey: .enchants) ?? []
        allEnchants = try c.decodeIfPresent(Bool.self, forKey: .allEnchants) ?? true
        // Rules saved with one name and one enchantment.
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        if let v = try legacy.decodeIfPresent(String.self, forKey: .name), names.isEmpty { names = Self.terms([v]) }
        if let v = try legacy.decodeIfPresent(String.self, forKey: .enchant), enchants.isEmpty { enchants = Self.terms([v]) }
    }
    private enum LegacyKeys: String, CodingKey { case name, enchant }

    /// The non-blank terms, trimmed.
    static func terms(_ list: [String]) -> [String] {
        list.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

/// What item rules look up: each item's type and tier from the item catalog (issue #40), and enchantment names.
struct RuleCatalog: Equatable {
    struct Item: Equatable { var slot: Int?, tier: Int? }
    var items: [Int: Item] = [:]
    var enchants: [Int: String] = [:]
    /// Item names to suggest while typing a rule, sorted.
    var names: [String] = []

    /// Up to `limit` of `options` for what is typed: names starting with it first, then names with a word
    /// starting with it, then names containing it, each alphabetical. Nothing typed suggests nothing.
    static func suggest(_ typed: String, from options: [String], limit: Int = 8) -> [String] {
        let t = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return [] }
        var groups: [[String]] = [[], [], []]
        for o in options {
            let l = o.lowercased()
            guard l != t else { continue }
            if l.hasPrefix(t) { groups[0].append(o) }
            else if l.contains(" " + t) { groups[1].append(o) }
            else if l.contains(t) { groups[2].append(o) }
        }
        return Array(groups.flatMap { $0.sorted() }.prefix(limit))
    }

    /// Reads the catalog's items and RealmHound's enchantments.xml (call it off the main thread).
    static func load(_ store: DropRateStore, xml: URL) -> RuleCatalog {
        var catalog = RuleCatalog()
        store.run("SELECT type, slot_type, tier FROM items WHERE slot_type IS NOT NULL") { s in
            catalog.items[Int(sqlite3_column_int64(s, 0))] = Item(
                slot: Int(sqlite3_column_int64(s, 1)),
                tier: sqlite3_column_type(s, 2) == SQLITE_NULL ? nil : Int(sqlite3_column_int64(s, 2)))
        }
        store.run("SELECT DISTINCT coalesce(display_name, name) FROM items WHERE slot_type IS NOT NULL") { s in
            if let t = sqlite3_column_text(s, 0) { catalog.names.append(String(cString: t)) }
        }
        catalog.names.sort()
        if let data = try? Data(contentsOf: xml.appendingPathComponent("enchantments.xml")) {
            catalog.enchants = enchantNames(inXML: String(decoding: data, as: UTF8.self))
        }
        return catalog
    }
    /// `<Enchantment id="LUCKY_STREAK" type="0x639"><DisplayId>Lucky Streak</DisplayId>`: names by id, the
    /// DisplayId unless it is a {translation.key}.
    static func enchantNames(inXML text: String) -> [Int: String] {
        var names: [Int: String] = [:]
        for chunk in text.components(separatedBy: "<Enchantment ").dropFirst() {
            let tag = " " + chunk.prefix { $0 != ">" }   // the space lets the first attribute match " name="
            guard let type = attribute(tag, "type"), type.hasPrefix("0x"), let id = Int(type.dropFirst(2), radix: 16) else { continue }
            let display = chunk.components(separatedBy: "</Enchantment>")[0].components(separatedBy: "<DisplayId>").dropFirst().first?
                .components(separatedBy: "</DisplayId>").first
            names[id] = display.flatMap { $0.hasPrefix("{") ? nil : $0 } ?? attribute(tag, "id")
        }
        return names
    }
    private static func attribute(_ tag: String, _ name: String) -> String? {
        tag.components(separatedBy: " \(name)=\"").dropFirst().first?.components(separatedBy: "\"").first
    }
}

struct LootItem: Equatable {
    var id: Int
    var name: String
    var enchants: Int
    /// RealmHound's enchant_ids: one enchantment type per filled slot.
    var enchantIds: [Int] = []
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
    /// The title of the item rule that matched, if any.
    var rule = ""

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

    /// An item alerts when its bag is chosen and it is at least the chosen rarity, when it is shiny and
    /// shiny alerts are on, or when an item rule matches it (in any bag). The popup names the best matching
    /// item, a rule's item first.
    static func alert(for drop: LootDrop, settings: DropAlertSettings, shiny: Set<Int>, catalog: RuleCatalog = RuleCatalog(),
                      nowMs: Int64) -> DropAlert? {
        guard settings.enabled, nowMs - drop.epochMs <= freshness else { return nil }
        let bag = DropBag(id: drop.bag)
        let bagChosen = bag.map(settings.bags.contains) ?? false
        let matches = drop.items.compactMap { item -> (ruled: Bool, alert: DropAlert)? in
            let rarity = DropRarity(enchants: item.enchants), isShiny = shiny.contains(item.id)
            let rule = settings.rules.first { $0.matches(item, catalog: catalog) }
            guard rule != nil || (bagChosen && rarity.rawValue >= settings.minRarity.rawValue) || (settings.shiny && isShiny) else { return nil }
            return (rule != nil, DropAlert(item: item.name, bag: bag, rarity: rarity, shiny: isShiny, mob: drop.mob, dungeon: drop.dungeon,
                                           rule: rule?.title.trimmingCharacters(in: .whitespaces) ?? ""))
        }
        func rank(_ m: (ruled: Bool, alert: DropAlert)) -> (Int, Int, Int) { (m.ruled ? 1 : 0, m.alert.shiny ? 1 : 0, m.alert.rarity.rawValue) }
        return matches.max { rank($0) < rank($1) }?.alert
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

/// The game's own marks (issue #51): rarity gems and the shiny sparkle ship with the app (data/icons); each dungeon's
/// item collection icon (not the dungeon's own sprite) is cut from CollectionIcon.png, which RealmHound extracts. nil or empty when the files are missing, so callers draw
/// their own.
enum GameIcons {
    private static func bundled(_ name: String) -> CGImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
    private static let rarities = DropRarity.allCases.map { $0 == .common ? nil : bundled("Enchants-\($0.name)") }
    static func rarity(_ r: DropRarity) -> CGImage? { rarities[r.rawValue] }
    static let shiny = bundled("Shiny")

    /// A cell of CollectionIcon.png: 16 px squares, 20 a row, numbered from the top left (the items' collectionIcon).
    static func cell(_ index: Int) -> CGRect { CGRect(x: index % 20 * 16, y: index / 20 * 16, width: 16, height: 16) }

    /// Each catalog dungeon's collection icon ("icon" in data/drop_catalog.json), by dungeon name.
    static func dungeons(assets: URL, catalog: URL?) -> [String: CGImage] {
        guard let catalog, let data = try? Data(contentsOf: catalog),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let list = root["dungeons"] as? [[String: Any]],
              let source = CGImageSourceCreateWithURL(assets.appendingPathComponent("sprites/CollectionIcon.png") as CFURL, nil),
              let sheet = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return [:] }
        var out: [String: CGImage] = [:]
        for d in list {
            guard let name = d["name"] as? String, let index = d["icon"] as? Int, index >= 0 else { continue }
            let rect = cell(index)
            // The sheet is not ours: a cell outside it is skipped, not cut short.
            guard rect.maxX <= CGFloat(sheet.width), rect.maxY <= CGFloat(sheet.height), let crop = sheet.cropping(to: rect) else { continue }
            out[name] = crop
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
            SELECT d.id, d.timestamp, d.dungeon, d.mob_name, d.bag_type, i.item_id, i.item_name, i.enchant_count, i.enchant_ids
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
                                                             enchants: Int(sqlite3_column_int(statement, 7)),
                                                             enchantIds: text(8).split(separator: ",").compactMap { Int($0) }))
            }
        }
        return drops
    }
}
