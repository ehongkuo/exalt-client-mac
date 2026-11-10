import Foundation
import SQLite3

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAILED line \(line): \(message)") }
}

enum DropTests {
    static func run() {
        check(DropBag(id: 1708) == .red && DropBag(id: 1728) == .red && DropBag(id: 1296) == .white, "boosted bags count as their colour")
        check(DropBag(id: 1283) == nil, "soulbound is not a choosable bag")
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
        check(DropAlert(item: "x", bag: .red, rarity: .divine, shiny: false, mob: "Oryx", dungeon: "").detail == "Red (ST) bag · Divine · Oryx",
              "popup detail line")

        let xml = """
            <Objects>
              <Object type="0xa00" id="Short Sword"><Labels>EQUIPMENT,WEAPON</Labels></Object>
              <Object id="Doom Bow Shiny" type="0x1f4a"><Labels>EQUIPMENT,UT,SHINY</Labels></Object>
              <Object type="0x10" id="Not"><Labels>NOTSHINY</Labels></Object>
            </Objects>
            """
        check(ShinyIndex.ids(inXML: xml) == [0x1f4a], "shiny ids from labels")

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
                                     item_name TEXT, enchant_count INTEGER);
            INSERT INTO loot_drops VALUES (1, 5, 'Old', 1708, 'Old boss');
            """)
        let log = LootLog(accounts: folder)
        check(log.poll().isEmpty && log.logs == 1, "old drops are not replayed")
        exec("""
            INSERT INTO loot_drops VALUES (2, 9, 'Shatters', 1708, 'The Forgotten King');
            INSERT INTO loot_items VALUES (NULL, 2, 1, 101, 'Second', 0), (NULL, 2, 0, 100, 'First', 2);
            INSERT INTO loot_drops VALUES (3, 10, 'Shatters', 1292, 'Empty');
            """)
        let found = log.poll()
        check(found.map(\.id) == [2, 3] && found[0].items.map(\.name) == ["First", "Second"] && found[0].items[0].enchants == 2
              && found[1].items.isEmpty && found[0].mob == "The Forgotten King", "new drops with items")
        check(log.poll().isEmpty, "each drop once")
        sqlite3_close(db)
        try? FileManager.default.removeItem(at: folder)
        print("Drop alert tests passed")
    }
}
