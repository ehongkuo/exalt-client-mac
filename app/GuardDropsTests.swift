import CoreGraphics
import Foundation
import ImageIO
import SQLite3

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAILED line \(line): \(message)") }
}

enum DropTests {
    static func run() {
        check(DropBag(id: 1708) == .red && DropBag(id: 1728) == .red && DropBag(id: 1296) == .white, "boosted bags count as their colour")
        check(DropBag(id: 1283) == nil, "soulbound is not a choosable bag")
        check(DropBag(id: 1289) == .cyan && DropBag(rawValue: "teal") == .cyan, "cyan keeps its saved name")
        check(DropBag.egg.name == "Egg basket" && DropBag.cyan.name == "Cyan bag", "bag names")
        check(DropRarity(enchants: 0) == .common && DropRarity(enchants: 3) == .legendary && DropRarity(enchants: 7) == .divine,
              "rarity from enchantment slots")

        let now: Int64 = 1_000_000_000
        func drop(_ bag: Int, _ items: [LootItem], age: Int64 = 0) -> LootDrop {
            LootDrop(id: 1, epochMs: now - age, dungeon: "Shatters", mob: "The Forgotten King", bag: bag, items: items)
        }
        let st = LootItem(id: 100, name: "Bulwark", enchants: 1), shiny = LootItem(id: 200, name: "Doom Bow", enchants: 0)
        let potion = LootItem(id: 300, name: "Potion of Life", enchants: 0)
        var s = DropAlertSettings(); s.bags = [.red]
        check(DropRules.alerts(for: drop(1708, [st]), settings: s, shiny: [], nowMs: now).first?.item == "Bulwark", "a chosen bag alerts")
        check(DropRules.alerts(for: drop(1292, [potion]), settings: s, shiny: [], nowMs: now).isEmpty, "an unchosen bag stays quiet")
        check(DropRules.alerts(for: drop(1708, [st], age: 200_000), settings: s, shiny: [], nowMs: now).isEmpty, "old drops stay quiet")
        s.minRarity = .rare
        check(DropRules.alerts(for: drop(1708, [st]), settings: s, shiny: [], nowMs: now).isEmpty, "below the chosen rarity")
        let shown = DropRules.alerts(for: drop(1291, [potion, shiny]), settings: s, shiny: [200], nowMs: now).first
        check(shown?.item == "Doom Bow" && shown?.shiny == true && shown?.bag == .blue, "a shiny alerts in any bag")
        s.shiny = false
        check(DropRules.alerts(for: drop(1291, [shiny]), settings: s, shiny: [200], nowMs: now).isEmpty, "shiny alerts can be off")
        s.enabled = false
        check(DropRules.alerts(for: drop(1708, [LootItem(id: 1, name: "x", enchants: 4)]), settings: s, shiny: [], nowMs: now).isEmpty, "off")
        // Item rules (issue #47): the three examples, each with near misses.
        let catalog = RuleCatalog(items: [1: .init(slot: 4, tier: 4), 2: .init(slot: 4, tier: 3), 3: .init(slot: 4, tier: nil),
                                          4: .init(slot: 9, tier: 4), 5: .init(slot: 1, tier: nil), 6: .init(slot: 1, tier: 12)],
                                  enchants: [0x639: "Lucky Streak", 0x107: "Attack Bonus I", 0x2a0: "Loot Bonus IV", 0x2a1: "Loot Bonus I"])
        func confirmed(_ rules: ItemRule...) -> [ItemRule] { rules.map { var x = $0; x.confirmed = true; return x } }
        var r = DropAlertSettings(); r.bags = []; r.shiny = false
        r.rules = confirmed(ItemRule(slot: 4, minTier: 4), ItemRule(slot: 9, enchants: [" lucky streak "]), ItemRule(slot: 1, minRarity: .divine))
        func fires(_ item: LootItem, bag: Int = 1280, _ settings: DropAlertSettings? = nil) -> String? {
            DropRules.alerts(for: drop(bag, [item]), settings: settings ?? r, shiny: [], catalog: catalog, nowMs: now).first?.item
        }
        check(fires(LootItem(id: 1, name: "T4 tome", enchants: 0)) == "T4 tome", "a T4 tome, in an unchosen bag")
        check(fires(LootItem(id: 2, name: "T3 tome", enchants: 0)) == nil, "a T3 tome")
        check(fires(LootItem(id: 3, name: "UT tome", enchants: 0)) == nil, "an untiered tome has no tier")
        check(fires(LootItem(id: 4, name: "T4 ring", enchants: 0)) == nil, "a T4 ring is not a tome")
        check(fires(LootItem(id: 999, name: "Unknown", enchants: 0)) == nil, "an item missing from the catalog")
        check(fires(LootItem(id: 4, name: "Lucky ring", enchants: 2, enchantIds: [0x107, 0x639])) == "Lucky ring", "a ring with Lucky Streak")
        check(fires(LootItem(id: 4, name: "Plain ring", enchants: 1, enchantIds: [0x107])) == nil, "a ring without Lucky Streak")
        check(fires(LootItem(id: 1, name: "Lucky tome", enchants: 1, enchantIds: [0x639]), bag: 0, { var x = r; x.rules = [r.rules[1]]; return x }())
              == nil, "Lucky Streak on a tome is not a ring")
        check(fires(LootItem(id: 5, name: "Divine UT sword", enchants: 4), bag: 0) == "Divine UT sword", "a Divine sword, in an unknown bag")
        check(fires(LootItem(id: 6, name: "Legendary sword", enchants: 3)) == nil, "a Legendary sword")
        check(fires(LootItem(id: 1, name: "T4 tome", enchants: 0), { var x = r; x.enabled = false; return x }()) == nil, "rules are off with alerts")
        var blank = r; blank.rules = confirmed(ItemRule(names: ["  "]))
        check(fires(LootItem(id: 1, name: "T4 tome", enchants: 0), blank) == nil, "a blank rule matches nothing")
        var byName = r; byName.rules = confirmed(ItemRule(names: ["tome"]))
        check(fires(LootItem(id: 3, name: "UT Tome", enchants: 0), byName) == "UT Tome", "part of a name, any case")
        // Issue #76: every matching item alerts, each with its own rarity and title.
        var mixed = r; mixed.bags = [.red]; mixed.rules = [{ var x = r.rules[0]; x.title = "Tomes"; return x }()]
        let three = DropRules.alerts(for: drop(1708, [LootItem(id: 6, name: "Divine T12 sword", enchants: 4), LootItem(id: 2, name: "T3 tome", enchants: 4),
                                                      LootItem(id: 1, name: "T4 tome", enchants: 0), potion]),
                                     settings: mixed, shiny: [], catalog: catalog, nowMs: now)
        check(three.map(\.item) == ["Divine T12 sword", "T3 tome", "T4 tome", "Potion of Life"], "one alert per matching item, in bag order")
        check(three.map(\.rarity) == [.divine, .divine, .common, .common], "each alert has its own rarity")
        check(three.map(\.title) == ["Divine T12 sword", "T3 tome", "Tomes", "Potion of Life"], "the title is the rule's, else the item's")
        check(three[2].detail == "T4 tome · Red bag · The Forgotten King" && three[0].detail == "Red bag · Divine · The Forgotten King",
              "a rule's popup names the item in its detail")
        var orange = DropAlertSettings(); orange.bags = [.orange]; orange.minRarity = .uncommon
        let ring = DropRules.alerts(for: drop(1295, [LootItem(id: 7, name: "T7 sword", enchants: 3), LootItem(id: 8, name: "ST ring", enchants: 1)]),
                                    settings: orange, shiny: [], nowMs: now)
        check(ring.map(\.rarity) == [.legendary, .uncommon] && ring[1].item == "ST ring", "an Uncommon ring next to a Legendary stays Uncommon")
        // A white bag alerts only for the item that made it white, not for lesser items riding along.
        let malphas = RuleCatalog(items: [7456: .init(slot: 7, tier: nil, bag: .white), 28684: .init(slot: 3, tier: nil, bag: .purple),
                                          2651: .init(slot: 4, tier: nil, bag: .cyan), 7719: .init(slot: 10, tier: nil, bag: .purple)])
        var white = DropAlertSettings(); white.bags = [.white]; white.shiny = false
        let whiteBag = drop(1296, [LootItem(id: 7456, name: "Berserker's Breastplate", enchants: 0), LootItem(id: 28684, name: "Gilded Longbow", enchants: 1),
                                   LootItem(id: 2651, name: "Tome of Divine Favor", enchants: 1), LootItem(id: 7719, name: "Mark of Malphas", enchants: 0)])
        check(DropRules.alerts(for: whiteBag, settings: white, shiny: [], catalog: malphas, nowMs: now).map(\.item) == ["Berserker's Breastplate"],
              "a chosen bag alerts for its own item only")
        white.bags = [.white, .purple]
        check(DropRules.alerts(for: whiteBag, settings: white, shiny: [], catalog: malphas, nowMs: now).map(\.item) == ["Berserker's Breastplate"],
              "a purple item in a white bag is not a purple bag")
        white.bags = []; white.shiny = true
        check(DropRules.alerts(for: whiteBag, settings: white, shiny: [2651], catalog: malphas, nowMs: now).map(\.item) == ["Tome of Divine Favor"],
              "a shiny alerts whatever bag it rides in")
        white.shiny = false; white.bags = [.white]; white.rules = confirmed(ItemRule(title: "Marks", names: ["mark of"]))
        let ruled = DropRules.alerts(for: whiteBag, settings: white, shiny: [], catalog: malphas, nowMs: now)
        check(ruled.map(\.title) == ["Berserker's Breastplate", "Marks"] && ruled.map(\.bag) == [.white, .purple],
              "a rule alerts whatever bag it rides in, each popup showing the item's own bag")
        // The stack: oldest on top, each up for its own time, a burst past the limit waits its turn.
        func alert(_ name: String) -> DropAlert { DropAlert(item: name, bag: .red, rarity: .common, shiny: false, mob: "", dungeon: "") }
        var stack = DropStack()
        stack.push([alert("a"), alert("b")], now: 0)
        stack.push([alert("c")], now: 4)
        check(stack.visible.map(\.alert.item) == ["a", "b", "c"] && stack.visible.map(\.shownAt) == [0, 0, 4], "new popups go below, oldest on top")
        stack.expire(now: 4.9)
        check(stack.visible.count == 3, "each stays up for the set time")
        stack.expire(now: 5)
        check(stack.visible.map(\.alert.item) == ["c"], "the oldest close at their time and the rest move up")
        stack.dismiss(stack.visible[0].id, now: 11); stack.dismiss(999, now: 11)
        check(stack.entries.isEmpty, "a click closes one; a gone id does nothing")
        stack.push((1...7).map { alert("\($0)") }, now: 20)
        check(stack.visible.map(\.alert.item) == ["1", "2", "3", "4", "5"] && stack.entries.count == 7, "past the limit, the rest wait")
        stack.dismiss(stack.visible[2].id, now: 22)
        check(stack.visible.map(\.alert.item) == ["1", "2", "4", "5", "6"] && stack.visible.last?.shownAt == 22,
              "a closed middle popup lets the next waiting one show, its time starting then")
        stack.expire(now: 25)
        check(stack.visible.map(\.alert.item) == ["6", "7"] && stack.visible.map(\.shownAt) == [22, 25], "expired ones make room for the rest")
        var both = r; both.rules = confirmed(ItemRule(slot: 9, enchants: ["Lucky Streak", "Loot Bonus IV"]))
        check(fires(LootItem(id: 4, name: "Both", enchants: 2, enchantIds: [0x639, 0x2a0]), both) == "Both", "a ring with both enchantments")
        check(fires(LootItem(id: 4, name: "One", enchants: 1, enchantIds: [0x639]), both) == nil, "all enchantments: one is not enough")
        both.rules[0].allEnchants = false
        check(fires(LootItem(id: 4, name: "One", enchants: 1, enchantIds: [0x2a0]), both) == "One", "any enchantment: one is enough")
        var lootI = r; lootI.rules = confirmed(ItemRule(slot: 9, enchants: ["loot bonus i"]))
        check(fires(LootItem(id: 4, name: "IV", enchants: 1, enchantIds: [0x2a0]), lootI) == nil
              && fires(LootItem(id: 4, name: "I", enchants: 1, enchantIds: [0x2a1]), lootI) == "I", "a whole enchantment name means only that one")
        var wizard = r; wizard.rules = confirmed(ItemRule(playerClass: "Wizard", enchants: ["Loot Bonus"]))
        check(fires(LootItem(id: 4, name: "Ring", enchants: 1, enchantIds: [0x2a0]), wizard) == "Ring"
              && fires(LootItem(id: 1, name: "Tome", enchants: 1, enchantIds: [0x2a0]), wizard) == nil
              && fires(LootItem(id: 4, name: "Plain", enchants: 0), wizard) == nil
              && fires(LootItem(id: 999, name: "Unknown", enchants: 1, enchantIds: [0x2a0]), wizard) == nil,
              "Wizard gear with Loot Bonus: a ring, not a tome, nothing missing from the catalog")
        check(ItemRule.classes.count == 19 && ItemRule.classes.values.allSatisfy { $0.count == 4 && $0.last == 9 }, "every class wears a ring")
        var twoNames = r; twoNames.rules = confirmed(ItemRule(names: ["fortune", "tome"]))
        check(fires(LootItem(id: 3, name: "UT Tome", enchants: 0), twoNames) == "UT Tome" && fires(LootItem(id: 4, name: "Ring", enchants: 0), twoNames) == nil,
              "any one of several names")
        var draft = r; draft.rules = [ItemRule(slot: 4, minTier: 4)]
        check(fires(LootItem(id: 1, name: "T4 tome", enchants: 0), draft) == nil, "a draft rule never alerts")
        // Alert me (issue #68): a confirmed rule for the item's name that alerts in any bag, with alerts on, added once.
        var me = DropAlertSettings(); me.enabled = false; me.bags = []
        me.alert(on: "Doom Bow"); me.alert(on: "Doom Bow")
        check(me.enabled && me.rules.count == 1 && me.rules[0].confirmed && me.alerts(on: "Doom Bow") && !me.alerts(on: "Bow"), "Alert me adds one confirmed rule")
        check(DropRules.alerts(for: drop(1292, [LootItem(id: 200, name: "Doom Bow", enchants: 0)]), settings: me, shiny: [], nowMs: now).first?.rule == "Doom Bow"
              && DropRules.alerts(for: drop(1292, [LootItem(id: 201, name: "Doom Bow Shiny", enchants: 0)]), settings: me, shiny: [], nowMs: now).count == 1
              && DropRules.alerts(for: drop(1292, [LootItem(id: 202, name: "Bow of Covert Havens", enchants: 0)]), settings: me, shiny: [], nowMs: now).isEmpty,
              "the rule matches the item and its shiny, not other items")
        var coin = DropAlertSettings(); coin.alert(on: "Divine Coin")   // a stack's page drops " x1" from the name
        check(coin.rules[0].matches(LootItem(id: 1, name: "Divine Coin x3", enchants: 0), catalog: RuleCatalog()), "a stack's rule matches every stack size")
        var titled = r; titled.rules = confirmed(ItemRule(title: " Tomes ", slot: 4, minTier: 4))
        check(DropRules.alerts(for: drop(1280, [LootItem(id: 1, name: "T4 tome", enchants: 0)]), settings: titled, shiny: [], catalog: catalog,
                              nowMs: now).first?.rule == "Tomes", "the alert names the rule")
        check(DropRules.alerts(for: drop(1280, [LootItem(id: 1, name: "T4 tome", enchants: 0)]), settings: r, shiny: [], catalog: catalog,
                              nowMs: now).first?.rule == "", "an untitled rule names no rule")
        let old = try! JSONDecoder().decode([ItemRule].self, from: Data(#"[{"id":"00000000-0000-0000-0000-000000000001","name":"","slot":9,"minRarity":0,"enchant":"Lucky"}]"#.utf8))
        check(old.count == 1 && old[0].confirmed && old[0].title == "" && old[0].slot == 9 && old[0].names == [] && old[0].enchants == ["Lucky"]
              && old[0].allEnchants && old[0].playerClass == nil, "rules saved before drafts and lists load confirmed, one name and enchantment as lists")
        check(ItemRule(names: ["staff", "wand"], slot: 4, minTier: 4, minRarity: .divine, enchants: ["Lucky Streak", " "]).summary
              == "“staff” or “wand” · Tome · Tier 4+ · Divine · Lucky Streak" && ItemRule().isBlank && !ItemRule(minTier: 1).isBlank, "rule summary")
        let options = ["Attack Bonus I", "Lucky Streak", "Plucky Charm", "Ring of Lucky Fortune", "Luck Charm"]
        check(RuleCatalog.suggest(" luck", from: options) == ["Luck Charm", "Lucky Streak", "Ring of Lucky Fortune", "Plucky Charm"],
              "suggestions: name starts, then a word starts, then contains")
        check(RuleCatalog.suggest("", from: options).isEmpty && RuleCatalog.suggest("lucky streak", from: options).isEmpty
              && RuleCatalog.suggest("a", from: options, limit: 2).count == 2, "no suggestions for nothing or an exact name; limit")
        check(RuleCatalog.enchantNames(inXML: """
            <Enchantments><Enchantment id="LUCKY_STREAK" type="0x639"><DisplayId>Lucky Streak</DisplayId></Enchantment>
            <Enchantment type="0x10" id="KEYED"><DisplayId>{enchant.keyed}</DisplayId></Enchantment></Enchantments>
            """) == [0x639: "Lucky Streak", 0x10: "KEYED"], "enchantment names from the XML")

        // Settings, rules included, are kept across restarts.
        let suite = "drop-tests-\(getpid())", defaults = UserDefaults(suiteName: suite)!
        r.minRarity = .rare
        r.save(to: defaults)
        check(DropAlertSettings(defaults: defaults) == r && DropAlertSettings(defaults: UserDefaults(suiteName: suite + "-empty")!) == DropAlertSettings(),
              "settings saved and loaded")
        defaults.removePersistentDomain(forName: suite)

        check(DropAlert(item: "x", bag: .red, rarity: .divine, shiny: false, mob: "Oryx", dungeon: "").detail == "Red bag · Divine · Oryx",
              "popup detail line")

        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080), right = CGRect(x: 1920, y: 0, width: 2560, height: 1440)
        check(PopupScreen.index(window: CGRect(x: 2000, y: 100, width: 800, height: 600), screens: [left, right]) == 1, "game on the second monitor")
        check(PopupScreen.index(window: CGRect(x: 1500, y: 0, width: 800, height: 600), screens: [left, right]) == 0, "most of the game wins")
        check(PopupScreen.index(window: nil, screens: [left, right]) == nil, "no game window")
        check(PopupScreen.index(window: CGRect(x: -5000, y: 0, width: 10, height: 10), screens: [left]) == nil, "off every screen")

        let xml = """
            <Objects>
              <Object type="0xa00" id="Short Sword"><Labels>EQUIPMENT,WEAPON</Labels></Object>
              <Object id="Doom Bow Shiny" type="0x1f4a"><Labels>EQUIPMENT,UT,SHINY</Labels></Object>
              <Object type="0x10" id="Not"><Labels>NOTSHINY</Labels></Object>
            </Objects>
            """
        check(ShinyIndex.ids(inXML: xml) == [0x1f4a], "shiny ids from labels")

        check(GameSprites.rects(in: Data([1, 2, 3])).isEmpty, "a broken sprite file reads as empty")
        // RealmHound's real assets, when installed: every bag has an 8×8 sprite.
        if FileManager.default.fileExists(atPath: RealmHoundPaths.assets.appendingPathComponent("flatbuffer/spritesheetf").path) {
            let sprites = BagSprites.load(assets: RealmHoundPaths.assets)
            check(sprites.count == DropBag.allCases.count && sprites.values.allSatisfy { $0.width == 8 && $0.height == 8 },
                  "bag sprites from RealmHound's assets")
            let mobAndItem = GameSprites.load(assets: RealmHoundPaths.assets, [
                "Malphas": GameTexture(file: "abyssOfDemonsChars16x16", index: 0), "Bow": GameTexture(file: "lostHallsObjects8x8", index: 0xa7)])
            check(mobAndItem["Malphas"]?.width == 16 && mobAndItem["Bow"]?.width == 8, "a mob's first frame and an item's sprite")
        }
        check(GameIcons.cell(0) == CGRect(x: 0, y: 0, width: 16, height: 16) && GameIcons.cell(133) == CGRect(x: 208, y: 96, width: 16, height: 16),
              "a dungeon icon's cell: 20 a row from the top left")
        check(GameIcons.rarity(.common) == nil, "common has no rarity mark")
        let iconCatalog = FileManager.default.temporaryDirectory.appendingPathComponent("icon-catalog-\(getpid()).json")
        try! Data(#"{"dungeons": [{"name": "Abyss of Demons", "icon": 133}, {"name": "Off the sheet", "icon": 999}, {"name": "No icon"}]}"#.utf8).write(to: iconCatalog)
        defer { try? FileManager.default.removeItem(at: iconCatalog) }
        check(GameIcons.dungeons(assets: URL(fileURLWithPath: "/nonexistent"), catalog: iconCatalog).isEmpty, "no icon sheet: no dungeon icons")
        // RealmEye's sprites: by the catalog's hex type → file map, from the app's sprites folder.
        let spriteFolder = FileManager.default.temporaryDirectory.appendingPathComponent("realmeye-sprites-\(getpid())")
        try? FileManager.default.createDirectory(at: spriteFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: spriteFolder) }
        let dot = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        let png = CGImageDestinationCreateWithURL(spriteFolder.appendingPathComponent("0x0d61.png") as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(png, dot, nil); _ = CGImageDestinationFinalize(png)
        let spriteCatalog = spriteFolder.appendingPathComponent("catalog.json")
        try! Data(#"{"sprites": {"0x0d61": "0x0d61.png", "0x0d62": "missing.png", "0x0d63": "../escape.png"}}"#.utf8).write(to: spriteCatalog)
        let fallback = GameIcons.realmEye(catalog: spriteCatalog, folder: spriteFolder)
        check(Set(fallback.keys) == [0x0d61] && fallback[0x0d61]?.width == 8, "RealmEye sprites by type; a missing file or a path out is skipped")
        check(GameIcons.realmEye(catalog: spriteCatalog, folder: nil).isEmpty, "no sprites folder: no RealmEye sprites")
        check(GameIcons.dungeons(assets: RealmHoundPaths.assets, catalog: nil).isEmpty, "no catalog: no dungeon icons")
        if FileManager.default.fileExists(atPath: RealmHoundPaths.assets.appendingPathComponent("sprites/CollectionIcon.png").path) {
            let icons = GameIcons.dungeons(assets: RealmHoundPaths.assets, catalog: iconCatalog)
            check(Set(icons.keys) == ["Abyss of Demons"] && icons["Abyss of Demons"]?.width == 16, "dungeon icons from RealmHound's sheet; a cell off it is skipped")
        }
        if FileManager.default.fileExists(atPath: RealmHoundPaths.xml.appendingPathComponent("enchantments.xml").path) {
            let names = RuleCatalog.enchantNames(inXML: try! String(contentsOf: RealmHoundPaths.xml.appendingPathComponent("enchantments.xml"), encoding: .utf8))
            check(names[0x639] == "Lucky Streak" && names.count > 500, "enchantment names from RealmHound's assets")
        }

        // The guard's bags (issue #75): the first look sets the start, later bags come back oldest first.
        var data = LiveBagsData()
        func put(_ n: UInt32, items: [Int32], enchants: String = "") {
            var b = LiveBag(); b.ns = UInt64(n) * 1_000_000; b.epoch = Double(n); b.id = Int32(n); b.type = 1708
            withUnsafeMutableBytes(of: &b.items) { raw in
                for (i, v) in (items + Array(repeating: -1, count: 8 - items.count)).enumerated() { raw.storeBytes(of: v, toByteOffset: 4 * i, as: Int32.self) }
            }
            withUnsafeMutableBytes(of: &b.enchants) { raw in for (i, c) in enchants.utf8.enumerated() { raw[i] = c } }
            withUnsafeMutableBytes(of: &data.bags) { $0.bindMemory(to: LiveBag.self)[Int((n - 1) % UInt32(LIVE_BAGS))] = b }
            data.count = n
        }
        var seen: GuardBags.Seen?
        put(1, items: [100])
        check(GuardBags.new(data, pid: 7, seen: &seen).isEmpty, "first look replays nothing")
        put(2, items: [100, 101], enchants: ",AAIBOQYFAA")   // slot 1: one enchantment, 0x639
        put(3, items: [])
        let fresh = GuardBags.new(data, pid: 7, seen: &seen)
        check(fresh.map(\.id) == [2, 3] && fresh[0].items.prefix(3) == [100, 101, -1], "new bags, oldest first")
        check(GuardBags.new(data, pid: 7, seen: &seen).isEmpty, "each bag once")
        for n in UInt32(4)...20 { put(n, items: [100]) }
        check(GuardBags.new(data, pid: 7, seen: &seen).map(\.id) == Array(9...20), "an overrun keeps the latest")
        put(21, items: [100])
        check(GuardBags.new(data, pid: 8, seen: &seen).isEmpty, "a new guard session starts over")
        var names = RuleCatalog(); names.itemNames = [101: "Second"]
        let drop = GuardBags.drop(fresh[0], catalog: names, dungeon: "Shatters")
        check(drop.items.map(\.name) == ["Item 100", "Second"] && drop.items[1].enchantIds == [0x639] && drop.items[1].enchants == 1
              && drop.items[0].enchants == 0 && drop.bag == 1708 && drop.dungeon == "Shatters" && drop.epochMs == 2000 && drop.mob.isEmpty,
              "a bag as the rules see it")
        let lines = DropDelayLog.lines(fresh, wakeNs: 3_500_000, mainNs: 4_000_000, shownNs: 4_300_000, panelNs: 5_000_000, tickGapMs: 100,
                                       popups: ["Second", ""])
        check(lines == "2000\t1.5\t2.0\t2.3\t3.0\t100\tSecond\t1708\n3000\t0.5\t1.0\t1.3\t2.0\t100\t\t1708\n", "delay log \(lines)")
        check(DropDelayLog.lines(fresh, wakeNs: nil, mainNs: 4_000_000, shownNs: 4_000_000, panelNs: 4_000_000, tickGapMs: 1400,
                                 popups: []).hasPrefix("2000\t\t2.0\t2.0\t2.0\t1400\t\t"),
              "a bag the timer found has no wake time")
        portals()
        print("Drop alert tests passed")
    }

    /// Portal alerts (issue #74): portals straight from the guard, the rule each must pass, and the catalog names.
    static func portals() {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("portal-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DropRateStore(path: folder.appendingPathComponent("drop_rates.db").path)!
        store.exec("""
            INSERT INTO dungeons(name, portal, texture_file, texture_index) VALUES ('Snake Pit', 1816, 'lofiEnvironment2', 5),
                ('Undead Lair', 1818, NULL, NULL), ('Pet Yard', NULL, NULL, NULL);
            INSERT INTO objects(type, name, display_name, class, boss, drop_source) VALUES (3340, 'Medusa', NULL, 'Character', 0, 1),
                (3341, 'Wall', NULL, 'Wall', 0, 0);
            """)
        let names = PortalNames.load(store)
        check(names.list == ["Snake Pit", "Undead Lair"] && names.textures == ["Snake Pit": GameTexture(file: "lofiEnvironment2", index: 5)]
              && names.dungeons == [1816: "Snake Pit", 1818: "Undead Lair"] && names.mobs == [3340: "Medusa"],
              "dungeons with a portal, their sprites, and mob names")

        // The ring: the first look sets the start, later portals come back oldest first, an overrun keeps the latest.
        var data = LivePortalsData()
        func put(_ n: UInt32) {
            var p = LivePortal(); p.id = Int32(n)
            withUnsafeMutableBytes(of: &data.portals) { $0.bindMemory(to: LivePortal.self)[Int((n - 1) % UInt32(LIVE_PORTALS))] = p }
            data.count = n
        }
        var seen: GuardBags.Seen?
        put(1)
        check(GuardPortals.new(data, pid: 7, seen: &seen).isEmpty, "first look replays nothing")
        put(2); put(3)
        check(GuardPortals.new(data, pid: 7, seen: &seen).map(\.id) == [2, 3], "new portals, oldest first")
        check(GuardPortals.new(data, pid: 7, seen: &seen).isEmpty, "each portal once")
        for n in UInt32(4)...20 { put(n) }
        check(GuardPortals.new(data, pid: 7, seen: &seen).map(\.id) == Array(13...20), "an overrun keeps the latest")
        put(21)
        check(GuardPortals.new(data, pid: 8, seen: &seen).isEmpty, "a new guard session starts over")

        // The rule: your kill died on the portal's spot, and its dungeon is chosen.
        let t = Date().timeIntervalSince1970, nowMs = Int64(t * 1000)
        func portal(_ type: Int32 = 1818, at x: Float = 10.5, damage: Int32 = 900, sinceHit: Int32 = 10, age: Double = 0) -> LivePortal {
            var p = LivePortal(); p.epoch = t - age; p.type = type; p.pos = (x, 20); p.mob = 3340; p.mob_pos = (10, 20)
            p.damage = damage; p.since_hit_ms = sinceHit
            return p
        }
        var s = DropAlertSettings()
        func fires(_ p: LivePortal, _ settings: DropAlertSettings? = nil) -> DropAlert? {
            DropRules.alert(for: p, names: names, settings: settings ?? s, nowMs: nowMs)
        }
        check(fires(portal()) == nil, "an unchosen dungeon stays quiet")
        s.portals = ["Undead Lair"]
        let alert = fires(portal())
        check(alert == DropAlert(item: "Undead Lair portal", bag: nil, rarity: .common, shiny: false, mob: "Medusa", dungeon: "Undead Lair", portal: true)
              && alert?.detail == "Portal · Medusa", "a chosen dungeon's portal alerts, naming the dungeon and the mob")
        check(fires(portal(1816)) == nil && fires(portal(9999)) == nil, "another dungeon, or a portal type with no dungeon")
        check(fires(portal(at: 11.4)) != nil && fires(portal(at: 11.6)) == nil, "within 1.5 tiles of the kill")
        check(fires(portal(damage: 0)) == nil && fires(portal(sinceHit: 1001)) == nil, "a kill that didn't die by your hits")
        check(fires(portal(age: 200)) == nil, "an old portal stays quiet")
        check(fires(portal(), { var x = s; x.enabled = false; return x }()) == nil, "off with drop alerts")

        let defaults = UserDefaults(suiteName: "portal-test-\(UUID().uuidString)")!
        var saved = DropAlertSettings(); saved.portals = ["Snake Pit"]; saved.save(to: defaults)
        check(DropAlertSettings(defaults: defaults).portals == ["Snake Pit"], "chosen dungeons are saved")
    }
}
