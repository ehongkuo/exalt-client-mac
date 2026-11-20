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
        // The stack: oldest on top, each up for its own time, a burst past the limit waits its turn.
        func alert(_ name: String) -> DropAlert { DropAlert(item: name, bag: .red, rarity: .common, shiny: false, mob: "", dungeon: "") }
        var stack = DropStack()
        stack.push([alert("a"), alert("b")], now: 0)
        stack.push([alert("c")], now: 4)
        check(stack.visible.map(\.alert.item) == ["a", "b", "c"] && stack.visible.map(\.shownAt) == [0, 0, 4], "new popups go below, oldest on top")
        stack.expire(now: 9.9)
        check(stack.visible.count == 3, "each stays up for the set time")
        stack.expire(now: 10)
        check(stack.visible.map(\.alert.item) == ["c"], "the oldest close at their time and the rest move up")
        stack.dismiss(stack.visible[0].id, now: 11); stack.dismiss(999, now: 11)
        check(stack.entries.isEmpty, "a click closes one; a gone id does nothing")
        stack.push((1...7).map { alert("\($0)") }, now: 20)
        check(stack.visible.map(\.alert.item) == ["1", "2", "3", "4", "5"] && stack.entries.count == 7, "past the limit, the rest wait")
        stack.dismiss(stack.visible[2].id, now: 22)
        check(stack.visible.map(\.alert.item) == ["1", "2", "4", "5", "6"] && stack.visible.last?.shownAt == 22,
              "a closed middle popup lets the next waiting one show, its time starting then")
        stack.expire(now: 30)
        check(stack.visible.map(\.alert.item) == ["6", "7"] && stack.visible.map(\.shownAt) == [22, 30], "expired ones make room for the rest")
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

        // The log: first sight sets the start, later drops come back with their items in slot order.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("drop-tests-\(getpid())")
        let dbFolder = folder.appendingPathComponent("acct/databases")
        try? FileManager.default.removeItem(at: folder)
        try! FileManager.default.createDirectory(at: dbFolder, withIntermediateDirectories: true)
        var db: OpaquePointer?
        check(sqlite3_open(dbFolder.appendingPathComponent("loot_history.db").path, &db) == SQLITE_OK, "create test log")
        func exec(_ sql: String) { check(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, sql) }
        exec("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE loot_drops (id INTEGER PRIMARY KEY AUTOINCREMENT, timestamp INTEGER, dungeon TEXT, bag_type INTEGER, mob_name TEXT);
            CREATE TABLE loot_items (id INTEGER PRIMARY KEY AUTOINCREMENT, drop_id INTEGER, slot INTEGER, item_id INTEGER,
                                     item_name TEXT, enchant_count INTEGER, enchant_ids TEXT NOT NULL DEFAULT '');
            INSERT INTO loot_drops VALUES (1, 5, 'Old', 1708, 'Old boss');
            """)
        let log = LootLog(accounts: folder)
        check(log.poll().isEmpty && log.logs == 1, "old drops are not replayed")
        exec("""
            INSERT INTO loot_drops VALUES (2, 9, 'Shatters', 1708, 'The Forgotten King');
            INSERT INTO loot_items VALUES (NULL, 2, 1, 101, 'Second', 0, ''), (NULL, 2, 0, 100, 'First', 2, '1593,263');
            INSERT INTO loot_drops VALUES (3, 10, 'Shatters', 1292, 'Empty');
            """)
        let found = log.poll()
        check(found.map(\.id) == [2, 3] && found[0].items.map(\.name) == ["First", "Second"] && found[0].items[0].enchants == 2
              && found[0].items[0].enchantIds == [0x639, 0x107] && found[0].items[1].enchantIds.isEmpty
              && found[1].items.isEmpty && found[0].mob == "The Forgotten King", "new drops with items")
        check(log.poll().isEmpty, "each drop once")
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: folder)
        print("Drop alert tests passed")
    }
}
