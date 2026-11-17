import Foundation
import SQLite3

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAILED line \(line): \(message)") }
}

enum DropRateTests {
    static func run() {
        // Lines exactly as guard/loot_core.h writes them (tests/loot_tests.c checks that side).
        check(LootLine("kill\t1763300000.123\t3\t1001\t3340\t12.50\t0.00\t30.25\t900\t0\t120\t4000\tability") ==
              .kill(LootKill(time: 1763300000.123, generation: 3, object: 1001, type: 3340, x: 12.5, y: 0, z: 30.25,
                             projectile: 900, projectileAlt: 0, ability: 120, maxHP: 4000, landedBy: "ability")), "kill line")
        check(LootLine("bag\t1763300000.500\t3\t1002\t1295\t12.50\t30.25\t2856\t2856\t-1\t-1\t-1\t-1\t-1\t-1") ==
              .bag(LootBag(time: 1763300000.5, generation: 3, object: 1002, type: 1295, x: 12.5, y: 30.25,
                           items: [2856, 2856, -1, -1, -1, -1, -1, -1])), "bag line")
        check(LootLine("map\t1.0\t4\tLost Halls") == .map(time: 1, generation: 4, name: "Lost Halls"), "map line")
        check(LootLine("status\t2.0\trefused\tentry_bytes") == .status(time: 2, text: "refused\tentry_bytes"), "refusal")
        check(LootLine("kill\t1.0\t3\t1001\t3340\t1.00\t0.00\t2.00\t0\t0\t0\t4000\tremoved\t240") ==
              .kill(LootKill(time: 1, generation: 3, object: 1001, type: 3340, x: 1, y: 0, z: 2, projectile: 0,
                             projectileAlt: 0, ability: 0, maxHP: 4000, landedBy: "removed", sinceHitMs: 240)), "removal kill line")
        check(LootLine("kill\t1.0\t3\t1001\t3340\t1.00\t2.00\t0.00\t0\t0\t0\t4000\tremoved\t240\t75") ==
              .kill(LootKill(time: 1, generation: 3, object: 1001, type: 3340, x: 1, y: 2, z: 0, projectile: 0, projectileAlt: 0,
                             ability: 0, maxHP: 4000, landedBy: "removed", sinceHitMs: 240, others: 75)), "others' damage (format 3)")
        check(LootLine("drop\t1.0\t3\t1002\t1001") == .drop(time: 1, generation: 3, bag: 1002, killer: 1001), "drop line")
        check(LootLine("kill\t1\t2\t3") == nil && LootLine("bag\tx") == nil && LootLine("guard_map\tNexus") == nil, "bad lines")

        // Import: resumes at the stored offset, links bags by the guard's drop lines, keeps a cut-off line,
        // removes the file once the game ends.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loot-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("loot-1763300000-4242.tsv")
        let first = """
            loot_session\t3\tabc\t1763300000.000\t4242
            map\t1763300001.000\t1\tNexus
            map\t1763300010.000\t2\tShatters
            bag\t1763300020.000\t2\t600\t1295\t10.10\t20.10\t2856\t2856\t-1\t-1\t-1\t-1\t-1\t-1
            bag_stat\t1763300020.000\t2\t600\t80\t0\tAQID
            bag\t1763300020.000\t2\t601\t1287\t50.00\t50.00\t-1\t-1\t-1\t-1\t-1\t-1\t-1\t-1
            kill\t1763300020.200\t2\t500\t3340\t10.00\t20.00\t0.00\t900\t0\t120\t4000\tremoved\t100\t0
            kill\t1763300020.200\t2\t501\t3341\t30.00\t20.00\t0.00\t0\t0\t0\t300\tremoved\t50\t700
            kill\t1763300020.200\t2\t503\t3341\t90.00\t90.00\t0.00\t50\t0\t0\t300\tremoved\t3000\t0
            drop\t1763300020.400\t2\t600\t500
            drop\t1763300020.400\t2\t601\t0
            map_info\t1763300010.100\t2\t782\t123456\t0\t1\t2\t3\t1463\t5\tZephyr\tDRAINED_3;|A\t
            player_stat\t1763300010.100\t2\t39\t2500
            gap\t1763300021.000\t3\tring_full
            bag\t1763300021.900\t2\t602\t1287\t1.00\t1.00\t-1\t-1\t-1\t-1\t-1\t-1\t-1\t-1
            kill\t1763300022
            """
        try! first.write(to: file, atomically: false, encoding: .utf8)
        let store = DropRateStore(path: folder.appendingPathComponent("drop_rates.db").path)!
        var running = true
        check(LootImport.run(logs: folder, store: store, appVersion: "t", alive: { _ in running }) == 15, "whole lines only")
        func int(_ sql: String) -> Int64 { var v: Int64 = -1; store.run(sql) { v = sqlite3_column_int64($0, 0) }; return v }
        check(int("SELECT count(*) FROM kills") == 3 && int("SELECT count(*) FROM maps") == 2, "kills and maps")
        check(int("SELECT since_hit_ms FROM kills WHERE object_id = 503") == 3000, "time since the last hit is kept")
        check(int("SELECT damage_others FROM kills WHERE object_id = 501") == 700, "others' damage is kept")
        check(int("SELECT b.kill = k.id FROM bags b JOIN kills k ON k.object_id = 500 WHERE b.object_id = 600") == 1, "bag linked to its kill")
        check(int("SELECT kill IS NULL FROM bags WHERE object_id = 601") == 1, "a bag with no kill stays unlinked")
        check(int("SELECT count(*) FROM bag_items WHERE item_type = 2856") == 2, "two copies count as two items")
        check(int("SELECT count(*) FROM bag_stats WHERE text = 'AQID'") == 1, "other bag stats are kept raw")
        check(int("SELECT lost FROM capture_gaps") == 3, "ring overflow is a gap")
        check(int("SELECT i.class FROM map_info i JOIN maps m ON m.id = i.map WHERE m.name = 'Shatters'") == 782 &&
              int("SELECT connection_10c FROM map_info") == 1463 && int("SELECT count(*) FROM map_info WHERE info_48 = 'DRAINED_3;|A'") == 1,
              "map info kept raw on its map")
        check(int("SELECT value FROM player_stats WHERE stat_type = 39") == 2500, "your stats kept")
        check(int("SELECT count(*) FROM maps m JOIN kills k ON k.map = m.id WHERE m.name = 'Shatters'") == 3, "kills carry their map")
        check(FileManager.default.fileExists(atPath: file.path), "a running game's file stays")

        let handle = try! FileHandle(forWritingTo: file)
        handle.seekToEndOfFile()
        handle.write(".000\t2\t502\t3340\t1.00\t1.00\t0.00\t10\t0\t0\t100\tremoved\t200\t0\ndrop\t1763300022.100\t2\t602\t502\nloot_summary\t1763300030.000\tkills=3\n".data(using: .utf8)!)
        try! handle.close()
        check(LootImport.run(logs: folder, store: store, appVersion: "t", alive: { _ in running }) == 3, "the cut line completes")
        check(int("SELECT count(*) FROM kills") == 4 && int("SELECT count(*) FROM sessions") == 1, "resumed, not re-read")
        check(int("SELECT k.object_id FROM bags b JOIN kills k ON k.id = b.kill WHERE b.object_id = 602") == 502,
              "a drop line in a later import still links its bag")
        running = false
        check(LootImport.run(logs: folder, store: store, appVersion: "t", alive: { _ in running }) == 0, "nothing new")
        check(!FileManager.default.fileExists(atPath: file.path), "an ended game's file is removed")
        check(int("SELECT ended > started FROM sessions") == 1, "session times")

        // Today's summary, as the Drop data panel shows it.
        let day = DropDay.load(store, since: 0)
        check(day.kills == 2 && day.bags == 3 && day.linked == 2 && day.lost == 3, "day totals: not a removal 3 s after the last hit, nor a mob only others hit")
        check(day.mobs.first == DropDay.Mob(type: 3340, map: "Shatters", kills: 2, bags: [.orange: 1, .purple: 1]), "kills by mob, with bag colours")
        check(day.notable == [DropDay.Notable(time: 1763300020.0, bag: .orange, mob: 3340, items: [2856, 2856])], "notable bags only")
        let xml = "<Object type=\"0x090a\" id=\"Archdemon Malphas\">\n<Group>Demons</Group></Object>" +
            "<Object type=\"0xb05\" id=\"Robe of the Grand Sorcerer\" x=\"1\"></Object><Objects type=\"0x1\" id=\"no\">"
        // A failed write rolls the file back and the next run retries it from the same place.
        let broken = folder.appendingPathComponent("broken")
        try! FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try! "kill\t5.000\t1\t9\t1\t0\t0\t0\t1\t0\t0\t10\tremoved\t0\t0\nbag\t5.100\t1\t10\t1295\t0\t0\t-1\t-1\t-1\t-1\t-1\t-1\t-1\t-1\nbag_stat\t5.100\t1\t10\t80\t0\tx\n"
            .write(to: broken.appendingPathComponent("loot-5-77.tsv"), atomically: false, encoding: .utf8)
        let other = DropRateStore(path: broken.appendingPathComponent("d.db").path)!
        other.exec("DROP TABLE bag_stats")
        check(LootImport.run(logs: broken, store: other, appVersion: "t", alive: { _ in true }) == 0, "a failed write stores nothing")
        func otherInt(_ sql: String) -> Int64 { var v: Int64 = -1; other.run(sql) { v = sqlite3_column_int64($0, 0) }; return v }
        check(otherInt("SELECT count(*) FROM kills") == 0 && otherInt("SELECT imported_bytes FROM sessions") == 0, "rolled back")
        check(other.exec(DropRateStore.schema), "table restored")
        check(LootImport.run(logs: broken, store: other, appVersion: "t", alive: { _ in true }) == 3, "retried")
        check(otherInt("SELECT count(*) FROM kills") == 1 && otherInt("SELECT count(*) FROM bag_stats") == 1, "stored on retry")
        check(GameNames.names(inXML: xml) == [0x090a: "Archdemon Malphas", 0xb05: "Robe of the Grand Sorcerer"], "names from XML")

        // Game catalog: the shapes RealmHound's assets/xml has, both attribute orders included.
        let xmlFolder = folder.appendingPathComponent("xml")
        try! FileManager.default.createDirectory(at: xmlFolder, withIntermediateDirectories: true)
        let abyss = """
            <Objects>
              <Object type="0x090a" id="Archdemon Malphas"><Group>Demons</Group><Class>Character</Class><Quest />
                <Projectile id="0"><ObjectId>Abyss Soul Shot Projectile</ObjectId></Projectile>
                <Labels>ENEMY,BOSS,BOSSFIGHT,QUEST,GOD</Labels></Object>
              <Object type="0x0901" id="Malphas Flamer"><Class>Character</Class><Labels>ENEMY,MINION,MINION_WEAK,ABYSSBASE</Labels></Object>
              <Object type="0x0902" id="Abyss Brute"><Class>Character</Class><Labels>ENEMY,MINIBOSS,BOSSFIGHT</Labels></Object>
              <Object id="Abyss Gate Wall" type="0x0903"><Class>Wall</Class></Object>
            </Objects>
            """
        let equip = """
            <Objects>
              <Object type="0x024c" id="Bow of the Void" collectionIcon="17"><Class>Equipment</Class><Item />
                <SlotType>3</SlotType><BagType>6</BagType><Labels>EQUIPMENT,WEAPON,BOW,UT,TAB_UT,ORG_VOID</Labels></Object>
              <Object id="MoonWizardST" type="0x0c10"><DisplayId>Robe of the Moon Wizard</DisplayId><Class>Equipment</Class><Item />
                <SlotType>14</SlotType><BagType>2</BagType><Labels>EQUIPMENT,ARMOR,ROBE,ST,TAB_ST,ORG_MOONLIGHT,ORG_UMI</Labels></Object>
              <Object type="0x0a00" id="Robe of the Grand Sorcerer"><Class>Equipment</Class><Item />
                <SlotType>14</SlotType><Tier>13</Tier><BagType>3</BagType><Labels>EQUIPMENT,ARMOR,ROBE,TIERED,T13</Labels></Object>
              <Object type="0x0a01" id="Void Blade Blueprint"><Class>Equipment</Class><Item /><BagType>7</BagType>
                <Labels>CONSUMABLE,ORG_VOID_S</Labels></Object>
            </Objects>
            """
        try! abyss.write(to: xmlFolder.appendingPathComponent("abyssOfDemonsObjects.xml"), atomically: false, encoding: .utf8)
        try! equip.write(to: xmlFolder.appendingPathComponent("equip.xml"), atomically: false, encoding: .utf8)
        let catalog = DropRateStore(path: folder.appendingPathComponent("catalog.db").path)!
        check(GameNames.refreshCatalog(catalog, folder: xmlFolder) && !GameNames.refreshCatalog(catalog, folder: xmlFolder),
              "built once, then kept while the XML is unchanged")
        func names(_ sql: String) -> [String] {
            var v: [String] = []; catalog.run(sql) { v.append(String(cString: sqlite3_column_text($0, 0))) }; return v
        }
        catalog.exec("""
            INSERT INTO maps(id, session, generation, name) VALUES (1, 1, 1, 'Abyss of Demons'), (2, 1, 2, 'Lost Halls');
            INSERT INTO kills(map, time, mob_type) VALUES (1, 1, 2314), (1, 2, 2305), (1, 3, 2306), (2, 4, 2314);
            """)
        check(names("""
            SELECT DISTINCT o.name FROM kills k JOIN maps m ON m.id = k.map JOIN objects o ON o.type = k.mob_type
            WHERE m.name = 'Abyss of Demons' AND o.boss ORDER BY 1
            """) == ["Abyss Brute", "Archdemon Malphas"], "Abyss bosses: <Quest/> or BOSSFIGHT")
        check(names("SELECT name FROM objects WHERE minion_class = 'WEAK'") == ["Malphas Flamer"], "minion strength")
        check(names("SELECT coalesce(display_name, name) FROM items WHERE labels LIKE '%,TAB_ST,%' AND labels LIKE '%,ROBE,%'")
              == ["Robe of the Moon Wizard"], "ST robes, by display name, id-first objects included")
        check(names("SELECT count(*) FROM items WHERE display_name IS NULL") == ["3"], "no display name when the XML has none")
        check(names("SELECT name FROM items WHERE origin LIKE '%,VOID,%'") == ["Bow of the Void"], "Void items, not the shiny origin")
        check(names("SELECT name FROM items WHERE tier = 13 AND slot_type = 14 AND bag_type = 3") == ["Robe of the Grand Sorcerer"],
              "item tier, slot and bag")
        check(names("SELECT name FROM objects WHERE drop_source = 0") == ["Abyss Gate Wall"], "a wall is not a drop source")
        check(names("SELECT count(*) FROM objects WHERE type IN (SELECT type FROM items)") == ["0"], "items are not objects")
        try! (abyss + "<Object type=\"0x0904\" id=\"Malphas Egg\"><Class>Character</Class></Object>")
            .write(to: xmlFolder.appendingPathComponent("abyssOfDemonsObjects.xml"), atomically: false, encoding: .utf8)
        check(GameNames.refreshCatalog(catalog, folder: xmlFolder) && names("SELECT name FROM objects WHERE type = 2308") == ["Malphas Egg"],
              "rebuilt when the XML changes")
        check(!GameNames.refreshCatalog(catalog, folder: folder.appendingPathComponent("none")) &&
              names("SELECT count(*) FROM items") == ["4"], "no XML keeps the last catalog")
    }
}
