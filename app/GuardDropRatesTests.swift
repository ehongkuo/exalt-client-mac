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

        // Capture health, as the drop rates sidebar shows it.
        let health = CaptureHealth.load(store)
        check(health.kills == 2 && health.bags == 3 && health.linked == 2 && health.lost == 3 && health.refused == nil,
              "totals: not a removal 3 s after the last hit, nor a mob only others hit")
        _ = store.run("INSERT INTO sessions(file, started, status) VALUES ('r', 1763300040, 'refused\tentry_bytes')", [])
        check(CaptureHealth.load(store).refused == "refused\tentry_bytes", "the latest game's refusal shows")
        _ = store.run("INSERT INTO sessions(file, started) VALUES ('ok', 1763300050)", [])
        check(CaptureHealth.load(store).refused == nil, "an earlier game's refusal clears once a later one captures")
        // Enchantments: real stat 80 parts from staging run 1 (0, 1 and 2 enchantments), an empty slot, a cut-off part.
        check(Enchantments.counts("AAIE_f_9__3__f8FAA==,AAIEGgX9__3__f8FAA==,AAIEcAFcBf3__f8FAA==,,AAIE_f_9") == [0, 1, 2, nil, nil],
              "enchantments per slot")
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
                <AnimatedTexture><File>abyssOfDemonsChars16x16</File><Index>0</Index></AnimatedTexture>
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
                <Texture><File>lostHallsObjects8x8</File><Index>0xa7</Index></Texture>
                <SlotType>3</SlotType><BagType>6</BagType><Labels>EQUIPMENT,WEAPON,BOW,UT,TAB_UT,ORG_VOID</Labels></Object>
              <Object id="MoonWizardST" type="0x0c10"><DisplayId>Robe of the Moon Wizard</DisplayId><Class>Equipment</Class><Item />
                <SlotType>14</SlotType><BagType>2</BagType><Labels>EQUIPMENT,ARMOR,ROBE,ST,TAB_ST,ORG_MOONLIGHT,ORG_UMI</Labels></Object>
              <Object type="0x0a00" id="Robe of the Grand Sorcerer"><Class>Equipment</Class><Item />
                <Texture xOffset="-2" yOffset="0"><File>d2LofiObjEmbed</File><Index>0x214</Index></Texture>
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
        check(names("SELECT texture_file || ' ' || texture_index FROM items WHERE type = 588") == ["lostHallsObjects8x8 167"] &&
              names("SELECT texture_file || ' ' || texture_index FROM objects WHERE type = 2314") == ["abyssOfDemonsChars16x16 0"] &&
              names("SELECT count(*) FROM objects WHERE texture_file IS NULL") == ["3"] &&
              names("SELECT texture_index FROM items WHERE type = 2560") == ["532"], "sprite sheet and index, hex or decimal, attributes or not")
        check(names("SELECT count(*) FROM objects WHERE type IN (SELECT type FROM items)") == ["0"], "items are not objects")
        try! (abyss + "<Object type=\"0x0904\" id=\"Malphas Egg\"><Class>Character</Class></Object>")
            .write(to: xmlFolder.appendingPathComponent("abyssOfDemonsObjects.xml"), atomically: false, encoding: .utf8)
        check(GameNames.refreshCatalog(catalog, folder: xmlFolder) && names("SELECT name FROM objects WHERE type = 2308") == ["Malphas Egg"],
              "rebuilt when the XML changes")
        check(!GameNames.refreshCatalog(catalog, folder: folder.appendingPathComponent("none")) &&
              names("SELECT count(*) FROM items") == ["4"], "no XML keeps the last catalog")

        // Rates (issue #41): 1 in N, and a 95% range from the drop count (exact Poisson values).
        let ten = DropRate(count: 10, of: 1000)
        check(abs(ten.range.lowerBound - 0.0047954) < 1e-6 && abs(ten.range.upperBound - 0.0183904) < 1e-6,
              "exact range at 10 drops")
        let none = DropRate(count: 0, of: 100)
        check(none.range.lowerBound == 0 && abs(none.range.upperBound - 0.0368888) < 1e-6, "no drops still has a range")
        check(DropRate(count: 3, of: 9).precision == nil && abs(DropRate(count: 4, of: 9).precision! - 0.98) < 1e-9 &&
              abs(DropRate(count: 100, of: 900).precision! - 0.196) < 1e-9, "precision: ±1.96/√drops, none under 4 drops")
        check(abs(DropRate.poissonRange(1).0 - 0.0253178) < 1e-6 && abs(DropRate.poissonRange(400).0 - 361.756) < 0.01 &&
              abs(DropRate.poissonRange(400).1 - 441.187) < 0.01, "exact below 50 drops, Byar above")
        check(DropRate(count: 3, of: 0).range == 0...0 && DropRate(count: 3, of: 0).rate == 0, "no kills, no rate")
        check(DropRate.oneIn(3.0 / 123) == "1 in 41" && DropRate.oneIn(0) == "none yet" && DropRate.oneIn(1.5) == "every time", "1 in N")

        // The report: per-kill and per-run counts on fixture rows. A run is a map visit where a boss died.
        let rates = DropRateStore(path: folder.appendingPathComponent("rates.db").path)!
        check(rates.exec("""
            INSERT INTO objects(type, name, boss, drop_source) VALUES (1, 'Void Entity', 1, 1), (2, 'Void Minion', 0, 1);
            INSERT INTO items(type, name, texture_file, texture_index) VALUES (588, 'Bow of the Void', 'lostHallsObjects8x8', 167);
            INSERT INTO maps(id, session, generation, name) VALUES (1, 1, 1, 'The Void'), (2, 1, 2, 'The Void'), (3, 1, 3, 'The Void'),
                (4, 1, 4, 'The Void');
            -- 1: boss and minion die; 2: boss dies; 3: only a minion dies; 4: the boss left view 3 s after your last hit.
            INSERT INTO kills(id, map, time, mob_type, damage_projectile, damage_projectile_alt, damage_ability, landed_by, since_hit_ms)
                VALUES (1, 1, 1, 1, 100, 0, 0, 'removed', 100), (2, 1, 2, 2, 100, 0, 0, 'removed', 100),
                (3, 2, 3, 1, 100, 0, 0, 'removed', 100), (4, 3, 4, 2, 100, 0, 0, 'removed', 100), (5, 4, 5, 1, 100, 0, 0, 'removed', 3000);
            INSERT INTO bags(id, map, time, bag_type, kill) VALUES (1, 1, 1, 1292, 1), (2, 1, 1, 1287, 1), (3, 1, 2, 1296, 2),
                (4, 2, 3, 1295, 3), (5, 3, 4, 1292, 4), (6, 4, 5, 1292, 5);
            INSERT INTO bag_items(bag, slot, item_type) VALUES (1, 0, 588), (3, 0, 588), (4, 0, 9), (5, 0, 588), (6, 0, 588);
            -- The boss's Bow has 2 enchantments, the minion's 1.
            INSERT INTO bag_stats(bag, stat_type, value, text) VALUES (1, 80, 0, 'AAIEcAFcBf3__f8FAA=='), (3, 80, 0, 'AAIEGgX9__3__f8FAA==');
            """), "fixture rows")
        let report = DropReport.load(rates)
        let boss = DropReport.Mob(type: 1, dungeon: "The Void"), minion = DropReport.Mob(type: 2, dungeon: "The Void")
        check(report.runs == ["The Void": 2], "runs: visits where the boss died")
        check(report.runsWith("The Void", [588]) == 1, "Bows per Void run: two in one run count once, none from a run without the boss")
        check(report.kills == [boss: 2, minion: 2] && report.copies[minion]?[588] == 2, "kills and copies by mob")
        check(report.bossBags["The Void"]?[nil] == [.white: 1, .orange: 1] && report.bossBags["The Void"]?[1] == [.white: 1, .orange: 1],
              "best bag from the bosses, per run")
        check(report.itemBag[588] == .white && report.bosses == [1] && report.name(1) == "Void Entity" &&
              report.textures[588] == GameTexture(file: "lostHallsObjects8x8", index: 167), "names, bosses and sprites")
        check(report.dropped(588) == 3 && report.items == [9, 588], "lists for the tabs")
        check(report.rarity[boss]?[588] == [0, 0, 1, 0, 0] && report.rarity[minion]?[588] == [0, 1, 0, 0, 0] &&
              report.rarityCounts(588) == [0, 1, 1, 0, 0] && report.bestEnchants(588) == 2 &&
              report.bestEnchants(588, dungeon: "Lost Halls") == nil && report.bestEnchants(9) == nil, "rarity per mob and item; unread copies in none")
        // Dungeons (issue #45): templated ones and maps with kills; drop tags are template labels some item carries.
        check(rates.exec("""
            UPDATE items SET origin = ',VOID,', bag_type = 6 WHERE type = 588;
            INSERT INTO items(type, name, origin, bag_type) VALUES (700, 'Void Blade', ',VOID,', 6), (701, 'Shatters Robe', ',SHATTERS,', 8);
            INSERT INTO dungeons(name, portal, texture_file, texture_index, labels) VALUES
                ('The Void', 1500, 'portals', 3, ',ANY,VOID,'), ('Lost Halls', NULL, NULL, NULL, ',ANY,LH,'), ('Test Portal', 1501, 'portals', 4, NULL);
            """), "dungeon rows")
        let atlas = DropReport.load(rates)
        let void = atlas.dungeons.first { $0.name == "The Void" }
        check(atlas.dungeons.map(\.name) == ["Lost Halls", "The Void"] && void?.codes == ["VOID"] && void?.portal == 1500 &&
              atlas.textures[1500] == GameTexture(file: "portals", index: 3), "templated or killed in; a portal alone is not listed")
        check(void.map(atlas.possibleDrops) == [9, 588, 700], "possible drops: tagged, dropped or not, and anything that dropped there")
        check(atlas.bag(700) == .white && atlas.bag(9) == .orange && DropBag(bagType: 8) == .orange && DropBag(bagType: 10) == nil,
              "an item's bag: the catalog's, else the best it came in")
        check(atlas.mobs(in: "The Void") == [boss, minion], "bosses first")
        check(GameNames.dungeonTemplates(inXML: """
            <DungeonModTemplate id="Abyss of Demons">
              <IncludedLabels>ANY,ABYSS,SKIN_HUNTER</IncludedLabels></DungeonModTemplate>
            <DungeonModTemplate id="No Labels"><GradeOption id="D" /></DungeonModTemplate>
            """) == ["Abyss of Demons": ["ANY", "ABYSS", "SKIN_HUNTER"]], "template labels")
        check(GameNames.objects(inXML: "<Object type=\"0x071b\" id=\"Abyss of Demons Portal\"><Class>Portal</Class><DungeonName>Abyss of Demons</DungeonName></Object>")
              .first?.dungeon == "Abyss of Demons", "a portal's dungeon")

        // Tiles and sources (issue #45): shinies fold into their base, a tier and slot family share a tile, and any-of
        // counts a run once. Run 1 drops the sword, its shiny and the dagger; run 2 the dagger.
        check(rates.exec("""
            INSERT INTO items(type, name, origin, bag_type, tier, slot_type) VALUES (800, 'Test Sword', ',VOID,', 4, 12, 1),
                (801, 'Test Dagger', ',VOID,', 4, 12, 2), (802, 'Test Sword Shiny', NULL, 4, NULL, 1), (803, 'Test Robe', ',VOID,', 4, 12, 14);
            INSERT INTO bags(id, map, time, bag_type, kill) VALUES (7, 1, 1, 1292, 1), (8, 2, 3, 1292, 3);
            INSERT INTO bag_items(bag, slot, item_type) VALUES (7, 0, 800), (7, 1, 802), (7, 2, 801), (8, 0, 801);
            """), "tile rows")
        let tiled = DropReport.load(rates)
        let weapons = DropReport.Group(tier: 12, family: .weapons)
        check(tiled.base(802) == 800 && tiled.variants(800) == [800, 802] && tiled.group(802) == weapons && tiled.group(9) == nil,
              "a shiny's base, and its group")
        check(tiled.runsWith("The Void", tiled.variants(800)) == 1 && tiled.runsWith("The Void", [800, 801, 802]) == 2,
              "any-of: a run with the sword and its shiny, or with two of a group, counts once")
        let row = tiled.tiles([9, 800, 801, 802, 803])
        check(row[.cyan] == [.group(weapons, [800, 801]), .item(803)] && weapons.name == "T12 weapons",
              "one tile per tier group in rotation order (sword, dagger), shinies folded in, a lone member stays an item; weapons before armors")
        check(tiled.rotation(801)! == (1, 6) && tiled.rotation(803)! == (2, 3) && tiled.rotation(9) == nil, "rotation places: dagger 2nd of 6, robe 3rd of 3")
        check(tiled.kinds([803, 801, 802, 800, 9]) == [[800, 802], [801], [803], [9]],
              "kinds in rotation order; two items of one kind share a turn; unplaced last")
        var alt = tiled; alt.slots[801] = 1; alt.subtypes = [800]   // two swords, 800 the alternate
        check(alt.kinds([800, 801, 802]) == [[801], [800, 802]], "a slot's base type before its alternate, the shiny with its base")
        check(tiled.members[weapons] == [800, 801] && tiled.tierItems("We12 Ar12,13 Xx1") == [800, 801, 803],
              "a tier group holds every catalog item of it; RealmEye codes expand to their groups")
        let sources = tiled.sources(tiled.variants(800))
        check(sources.count == 1 && sources[0].runs == 2 && sources[0].runsWith == 1 && sources[0].mobs == [boss: 2],
              "an item's sources: per dungeon, runs with one, copies by mob")
        check(tiled.rarityCounts([588, 800]) == [0, 1, 1, 0, 0], "rarity over a set of items")
        // The mob page (issue #50): kills, runs it died in, and its drops by bag with copies per kill.
        check(tiled.kills[boss] == 2 && tiled.mobRuns[boss] == 2 && tiled.mobRuns[minion] == 1,
              "runs a mob died in: the minion's map-3 kill had no boss, so it is not a run")
        let mobTiles = tiled.tiles(of: boss)
        check(mobTiles[.cyan] == [.group(weapons, [800, 801]), .item(803)] && mobTiles[.white] == [.item(588), .item(700)] &&
              mobTiles[.orange] == [.item(9)] && mobTiles.count == 3,
              "a boss's tiles: its drops (the shiny folded into its sword) and its dungeon's tagged items not dropped yet")
        check(tiled.possibleDrops(minion) == [588] && tiled.killsWith(boss, [.item(700)]) == 0,
              "a minion gets only its own drops and RealmEye tiers, not the dungeon's tags; an undropped item has no kills")
        check(tiled.killsWith(boss, [.group(weapons, [800, 801])]) == 2 && tiled.killsWith(boss, [.item(800)]) == 1 &&
              tiled.killsWith(boss, [.item(588), .item(9)]) == 2 && tiled.killsWith(minion, [.item(588)]) == 2,
              "kills with at least one: the sword and its shiny in one kill count once; a bag or group counts a kill once")
        check(tiled.tiles(of: minion) == [.white: [.item(588)]] && tiled.tiles(of: DropReport.Mob(type: 9, dungeon: "x")).isEmpty,
              "a minion's own drops; an unknown mob has none")
        check(DropRate(count: 9, of: 20).percent == "45%" && DropRate(count: 1, of: 20).percent == "5%" &&
              DropRate(count: 9, of: 20).plusMinus == "±65%" && DropRate(count: 3, of: 20).plusMinus == nil, "percent and ±")
        // The mob page's navigation: a mob click closes an open item; Esc steps item → mob page → dungeon.
        let tab = DropRatesModel()
        tab.item = 588; tab.openGroups = [weapons]; tab.openBags = [.cyan, nil]; tab.pick(mob: boss)
        check(tab.mob == boss && tab.item == nil && tab.group == nil && tab.openGroups.isEmpty && tab.openBags.isEmpty,
              "a mob click opens its page over an open item, with its bags and groups closed")
        tab.item = 800; tab.back()
        check(tab.mob == boss && tab.item == nil, "esc from an item on the mob page goes back to the mob page")
        tab.group = weapons; tab.back()
        check(tab.mob == boss && tab.group == nil, "esc from a group goes back to the mob page")
        tab.back()
        check(tab.mob == nil, "esc from the mob page goes back to the dungeon")
        tab.pick(mob: minion); tab.pick(mob: minion)
        check(tab.mob == nil, "clicking the open mob again closes its page")
    }
}
