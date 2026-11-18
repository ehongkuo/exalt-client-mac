import Foundation
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
        check(DropRules.alert(for: drop(1708, [st]), settings: s, shiny: [], nowMs: now)?.item == "Bulwark", "a chosen bag alerts")
        check(DropRules.alert(for: drop(1292, [potion]), settings: s, shiny: [], nowMs: now) == nil, "an unchosen bag stays quiet")
        check(DropRules.alert(for: drop(1708, [st], age: 200_000), settings: s, shiny: [], nowMs: now) == nil, "old drops stay quiet")
        s.minRarity = .rare
        check(DropRules.alert(for: drop(1708, [st]), settings: s, shiny: [], nowMs: now) == nil, "below the chosen rarity")
        let shown = DropRules.alert(for: drop(1291, [potion, shiny]), settings: s, shiny: [200], nowMs: now)
        check(shown?.item == "Doom Bow" && shown?.shiny == true && shown?.bag == .blue, "a shiny alerts in any bag")
        s.shiny = false
        check(DropRules.alert(for: drop(1291, [shiny]), settings: s, shiny: [200], nowMs: now) == nil, "shiny alerts can be off")
        s.enabled = false
        check(DropRules.alert(for: drop(1708, [LootItem(id: 1, name: "x", enchants: 4)]), settings: s, shiny: [], nowMs: now) == nil, "off")
        // Item rules (issue #47): the three examples, each with near misses.
        let catalog = RuleCatalog(items: [1: .init(slot: 4, tier: 4), 2: .init(slot: 4, tier: 3), 3: .init(slot: 4, tier: nil),
                                          4: .init(slot: 9, tier: 4), 5: .init(slot: 1, tier: nil), 6: .init(slot: 1, tier: 12)],
                                  enchants: [0x639: "Lucky Streak", 0x107: "Attack Bonus I"])
        var r = DropAlertSettings(); r.bags = []; r.shiny = false
        r.rules = [ItemRule(slot: 4, minTier: 4), ItemRule(slot: 9, enchant: " lucky streak "), ItemRule(slot: 1, minRarity: .divine)]
        func fires(_ item: LootItem, bag: Int = 1280, _ settings: DropAlertSettings? = nil) -> String? {
            DropRules.alert(for: drop(bag, [item]), settings: settings ?? r, shiny: [], catalog: catalog, nowMs: now)?.item
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
        var blank = r; blank.rules = [ItemRule(name: "  ")]
        check(fires(LootItem(id: 1, name: "T4 tome", enchants: 0), blank) == nil, "a blank rule matches nothing")
        var byName = r; byName.rules = [ItemRule(name: "tome")]
        check(fires(LootItem(id: 3, name: "UT Tome", enchants: 0), byName) == "UT Tome", "part of a name, any case")
        var mixed = r; mixed.bags = [.red]
        check(DropRules.alert(for: drop(1708, [LootItem(id: 6, name: "Divine T12 sword", enchants: 4), LootItem(id: 2, name: "T3 tome", enchants: 4),
                                               LootItem(id: 1, name: "T4 tome", enchants: 0)]),
                              settings: { var x = mixed; x.rules = [r.rules[0]]; return x }(), shiny: [], catalog: catalog, nowMs: now)?.item
              == "T4 tome", "the popup names the rule's item over a higher rarity")
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
