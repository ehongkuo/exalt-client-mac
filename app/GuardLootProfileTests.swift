import Foundation
import SQLite3

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAILED line \(line): \(message)") }
}
private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

/// Loot factors (issue #58): the XML numbers, the multiplier, the timeline per kill, the live state and base rates.
enum LootProfileTests {
    /// One slot of stat 80 as the game writes it: `00 02 n`, n 16-bit ids (fffd: an empty enchantment slot), `05 00`.
    static func slot(_ ids: [Int]) -> String {
        let padded = ids + Array(repeating: 0xfffd, count: max(0, 4 - ids.count))
        let bytes: [UInt8] = [0, 2, UInt8(padded.count)] + padded.flatMap { [UInt8($0 & 0xff), UInt8($0 >> 8)] } + [5, 0]
        return Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
    }

    static func run() {
        let enchantXML = """
            <Enchantments><Enchantment id="Loot_Bonus_2" type="0x5B1"><DisplayId>Loot Bonus II</DisplayId>
            <Mutators><ActivateOnEquip amount="1.5">LootBonus</ActivateOnEquip></Mutators></Enchantment>
            <Enchantment id="Vitality" type="0x10"><Mutators><ActivateOnEquip amount="-4.8" stat="VIT">IncrementStat</ActivateOnEquip></Mutators></Enchantment>
            </Enchantments>
            """
        let modsXML = """
            <DungeonModifiers><DungeonModifier id="LOOTING" type="0x4d"><DisplayId>Looting</DisplayId>
            <Mutators><EntityDropMultiplier amount="1.5" /></Mutators></DungeonModifier>
            <DungeonModifier id="TOUGHBOSS_2" type="0x70"><DisplayId>Tough Boss II</DisplayId><Mutators>
            <EntityStatMultiplier amount="1.6" reqLabels="BOSSFIGHT" stat="Defense" /><EntityDropMultiplier amount="1.1" reqLabels="BOSSFIGHT" /></Mutators></DungeonModifier>
            <DungeonModifier id="POTIONS" type="0x71"><Mutators><EntityDropMultiplier amount="100.00" excludeLabels="SHORTMINIBOSS" itemId="Potion of Life" reqLabels="MINIBOSS" /></Mutators></DungeonModifier>
            <DungeonModifier id="ELITEMINIONS_2" type="0x72"><DisplayId>Elite Minions II</DisplayId><Mutators /></DungeonModifier>
            </DungeonModifiers>
            """
        let catalog = LootCatalog(enchants: LootCatalog.enchants(inXML: enchantXML), modifiers: LootCatalog.modifiers(inXML: modsXML))
        check(catalog.enchants == [0x5B1: .init(name: "Loot Bonus II", percent: 1.5)], "only loot enchantments, by type")
        check(catalog.modifiers["TOUGHBOSS_2"] == .init(name: "Tough Boss II", drops: [.init(amount: 1.1, req: ["BOSSFIGHT"])]),
              "a modifier's drop multipliers, not its stat multipliers")
        check(catalog.modifiers["POTIONS"]?.drops == [.init(amount: 100, req: ["MINIBOSS"], exclude: ["SHORTMINIBOSS"], item: "Potion of Life")]
              && catalog.modifiers["ELITEMINIONS_2"]?.drops == [], "item-only and no-effect modifiers")

        check(LootMath.modifiers("ELITEMINIONS_2;FEEBLEMINIONS_2;") == ["ELITEMINIONS_2", "FEEBLEMINIONS_2"] &&
              LootMath.modifiers("FEROCIOUSBOSS_1;|D") == ["FEROCIOUSBOSS_1"] && LootMath.modifiers("") == [], "map info's modifier list")
        let mods = ["LOOTING", "TOUGHBOSS_2", "POTIONS", "UNKNOWN"]
        check(near(LootMath.dungeon(mods, catalog, labels: ["MINION"]), 1.5) &&
              near(LootMath.dungeon(mods, catalog, labels: ["BOSSFIGHT", "MINIBOSS"]), 1.65), "scoped by labels; item-only left out")
        check(LootMath.ritual(0) == 1 && LootMath.ritual(1) == 1 && LootMath.ritual(2) == 1.1 && LootMath.ritual(3) == 1.15 && LootMath.ritual(4) == 1.25,
              "Blood Ritual tiers")
        let all = LootState(potion: 10, enchants: [[0x5B1], [], [], [0x5B1, 0x10]], crucible: true, ritual: 4, modifiers: ["LOOTING"])
        check(near(all.multiplier(catalog, labels: []), 1.5 * 1.03 * 1.1 * 1.25 * 1.5) &&
              near(all.multiplier(catalog, labels: [], inDungeon: false), 1.5 * 1.03 * 1.1 * 1.25), "every factor multiplies; the dungeon's only inside")
        check(LootState().multiplier(catalog, labels: []) == 1, "nothing on: ×1")

        let gear = [slot([0x5B1]), slot([]), "", slot([0x5B1, 0x22])].joined(separator: ",")
        check(Enchantments.ids(gear) == [[0x5B1], [], nil, [0x5B1, 0x22]] && Enchantments.counts(gear) == [1, 0, nil, 2], "ids per slot")
        var line = LootTimeline()
        line.stats[67] = [(100, 60), (300, 120)]
        line.gear = [(100, gear)]
        check(line.state(at: 130).potion == 30 && line.state(at: 200).potion == 0 && line.state(at: 310).potion == 110,
              "the potion counts down from its last reading")
        check(line.state(at: 130, ticking: false).potion == 60, "paused in a safe zone")
        check(line.state(at: 50).enchants == nil && line.state(at: 130).enchants == [[0x5B1], [], [], [0x5B1, 0x22]], "gear known from its reading")
        check(LootMath.clock(872) == "14:32" && LootMath.clock(4325) == "1:12:05" && LootMath.times(1.5) == "1.5",
              "timer and multiplier text")

        // Through the importer: a format 4 file with your gear, then base rates and the live state.
        check(LootLine("player_stat\t1.0\t4\t80\t0\tAAIB,AAIC") == .playerStat(time: 1, generation: 4, stat: 80, value: 0, text: "AAIB,AAIC") &&
              LootLine("player_stat\t1.0\t4\t39\t2500") == .playerStat(time: 1, generation: 4, stat: 39, value: 2500), "player stat lines, 5 or 6 columns")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("loot-profile-test-\(UUID().uuidString)")
        try! FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let tsv = """
            loot_session\t4\tabc\t100.000\t4242
            map\t100.000\t1\tAbyss of Demons
            map_info\t100.100\t1\t782\t0\t0\t0\t0\t0\t0\t0\tAbyss\tx\tLOOTING;|D
            player_stat\t100.100\t1\t67\t60
            player_stat\t100.100\t1\t7\t20
            player_stat\t100.100\t1\t24\t1
            player_stat\t100.100\t1\t8\t2712
            player_stat\t100.100\t1\t80\t0\t\(slot([]) + "," + slot([]) + "," + slot([]) + "," + slot([0x5B1]))
            kill\t110.000\t1\t500\t3340\t10.00\t20.00\t0.00\t900\t0\t120\t4000\tremoved\t100\t0
            bag\t110.100\t1\t600\t1295\t10.10\t20.10\t2856\t-1\t-1\t-1\t-1\t-1\t-1\t-1
            drop\t110.200\t1\t600\t500
            kill\t200.000\t1\t501\t3340\t10.00\t20.00\t0.00\t900\t0\t120\t4000\tremoved\t100\t0

            """
        try! tsv.write(to: folder.appendingPathComponent("loot-100-4242.tsv"), atomically: false, encoding: .utf8)
        let store = DropRateStore(path: folder.appendingPathComponent("drop_rates.db").path)!
        LootImport.run(logs: folder, store: store, appVersion: "t", alive: { _ in true })
        var texts = 0
        store.run("SELECT count(*) FROM player_texts WHERE stat_type = 80") { texts = Int(sqlite3_column_int64($0, 0)) }
        check(texts == 1, "your gear's enchantments kept as text")

        let report = DropReport.load(store, catalog: catalog)
        let mob = DropReport.Mob(type: 3340, dungeon: "Abyss of Demons")
        // Kill 1: potion on (×1.5), gear +1.5%, Looting ×1.5. Kill 2: the potion ran out at 160.
        let weight = 1.5 * 1.015 * 1.5 + 1.015 * 1.5
        check(report.kills[mob] == 2 && near(report.weight[mob] ?? 0, weight) && report.gearUnknown == 0, "each kill counts as its multiplier")
        let base = report.perKill(mob, 1)
        check(near(base.rate, 1 / weight) && base.precision == nil && near(base.range.upperBound, DropRate(count: 1, of: 2).range.upperBound * 2 / weight),
              "base rate: drops ÷ the kills' multipliers")
        check(DropReport.load(store).weight[mob].map { near($0, 2.5) } == true, "no game data: only the potion counts")

        let now = LootNow.load(store, now: 130, alive: { _ in true })
        check(now?.map == "Abyss of Demons" && now?.classType == 782 && now?.level == 20 && now?.seasonal == true && now?.safe == false &&
              now?.equipment == [2712, -1, -1, -1], "who you are, from your stats")
        check(now.map { near($0.state.potion, 30.1) && near($0.state(at: 140).potion, 20.1) } == true &&
              now?.state.enchants == [[], [], [], [0x5B1]] && now?.state.modifiers == ["LOOTING"], "your boosts now")
        check(now.map { near($0.state.multiplier(catalog, labels: []), 1.5 * 1.015 * 1.5) } == true, "your multiplier now")
        let json = """
            {"characters": {"characters": [
              {"char_id": 1, "class_id": 782, "level": 20, "seasonal": true, "crucible_active": true, "loot_boost_secs": 0,
               "equipment": [{"item_id": 2712, "enchant_ids": [1457]}, {"item_id": -1}, {"item_id": 7}, {"item_id": 8}], "last_live_update": 99000},
              {"char_id": 2, "class_id": 784, "level": 5, "seasonal": false, "crucible_active": false, "loot_boost_secs": 1192,
               "equipment": [{"item_id": 3}, {"item_id": 4, "enchant_ids": [1, 2]}, {"item_id": 5}, {"item_id": 6}], "last_live_update": 50000}]}}
            """
        let rh = RealmHoundLive.parse(Data(json.utf8))
        check(rh == RealmHoundLive(classType: 782, level: 20, seasonal: true, crucible: true, potion: 0, equipment: [2712, -1, 7, 8],
                                   enchants: [[1457], [], [], []], seen: 99), "RealmHound's live character: the newest live update")
        check(LootNow.load(store, now: 130, realmHound: rh, alive: { _ in true })?.state.crucible == true &&
              near(LootNow.load(store, now: 130, realmHound: rh, alive: { _ in true })!.state.potion, 30.1), "Crucible from RealmHound; the guard's own readings win")
        var other = rh!; other.classType = 784
        check(LootNow.load(store, now: 130, realmHound: other, alive: { _ in true })?.state.crucible == nil, "another class: not this character")
        var old = rh!; old.seen = 0
        check(LootNow.load(store, now: 130, realmHound: old, alive: { _ in true })?.state.crucible == nil, "seen before this game: stale")
        // The first map: the guard's hooks went in after you loaded, so RealmHound fills in everything.
        let first = folder.appendingPathComponent("first")
        try! FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
        try! "loot_session\t4\tabc\t90.000\t4243\nmap\t95.000\t1\tNexus\nmap_info\t95.000\t1\t0\t0\t0\t0\t0\t0\t0\t0\tNexus\tx\t\n"
            .write(to: first.appendingPathComponent("loot-90-4243.tsv"), atomically: false, encoding: .utf8)
        let firstStore = DropRateStore(path: first.appendingPathComponent("drop_rates.db").path)!
        LootImport.run(logs: first, store: firstStore, appVersion: "t", alive: { _ in true })
        var rh2 = rh!; rh2.potion = 1192
        let filled = LootNow.load(firstStore, now: 130, realmHound: rh2, alive: { _ in true })
        check(filled?.classType == 782 && filled?.level == 20 && filled?.seasonal == true && filled?.equipment == [2712, -1, 7, 8] &&
              filled?.state.enchants == [[1457], [], [], []] && filled?.state.potion == 1192 && filled?.state.crucible == true,
              "first map: class, gear, enchantments, potion and Crucible from RealmHound")
        check(LootNow.load(store, now: 130, alive: { _ in false }) == nil, "no game running: nothing live")
        store.run("UPDATE sessions SET status = 'complete'")
        check(LootNow.load(store, now: 130, alive: { _ in true }) == nil, "a finished game isn't live")
    }
}
