import Foundation

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAILED line \(line): \(message)") }
}

private func sample() -> LiveData {
    var d = LiveData()
    d.pid = 4242; d.status = 0; d.armed = 1
    d.potion = 50; d.ceiling = 80; d.nexus = 25
    d.map_known = 1; d.in_nexus = 0; d.drinking = 1; d.settled = 1
    d.hp = 113; d.max_hp = 235; d.hud_hp = 113
    d.slot_count = 3; d.next_slot = 1
    withUnsafeMutableBytes(of: &d.stacks) { _ = $0.bindMemory(to: Int32.self).update(from: [0, 4, 2, 9, 9, 9, 9, 9]) }
    withUnsafeMutableBytes(of: &d.cooldown) { _ = $0.bindMemory(to: Int32.self).update(from: [0, 1, 0, 1, 1, 1, 1, 1]) }
    withUnsafeMutableBytes(of: &d.map) { raw in
        let name = Array("Realm of the Mad God".utf8)
        for (i, b) in name.enumerated() { raw[i] = b }
    }
    d.sample_ns = 5_000_000_000; d.ticks = 9000
    d.last_gap_us = 1000; d.max_gap_us = 4200; d.work_ns = 3100
    // 18 events: the ring keeps the newest 16 (numbers 3...18), stored modulo 16.
    d.event_count = 18
    withUnsafeMutableBytes(of: &d.events) { raw in
        let ring = raw.bindMemory(to: LiveEvent.self)
        for n in 1...18 {
            ring[(n - 1) % 16] = LiveEvent(epoch: Double(n), action: n == 18 ? 2 : 1, result: 1,
                                           slot: n == 18 ? -1 : 1, hp: Int32(100 + n), max_hp: 235, reserved: 0)
        }
    }
    return d
}

@main struct Tests {
    static func main() {

        // Snapshot conversion.
        let s = GuardSnapshot(sample())
        check(s.map == "Realm of the Mad God", "map name \(s.map)")
        check(s.stacks == [0, 4, 2] && s.cooling == [false, true, false], "slots trimmed to slot_count")
        check(s.totalPotions == 6 && s.nextSlot == 1, "potion totals")
        check(s.armed && s.drinking && s.settled && !s.inNexus, "flags")
        check(abs((s.percent ?? 0) - 48.085) < 0.01, "percent")
        check(s.stopPercent == 80, "ceiling stop")
        check(s.events.count == 16, "ring shows 16")
        check(s.events.first?.epoch == 3 && s.events.last?.epoch == 18, "oldest first, newest last")
        check(s.events.last?.action == .nexus && s.events.last?.outcome == "sent", "newest is the Nexus")
        var noCeiling = sample(); noCeiling.ceiling = 0
        check(GuardSnapshot(noCeiling).stopPercent == 50, "stop at potion without ceiling")
        var waiting = sample(); waiting.status = 3
        check(GuardSnapshot(waiting).percent == nil, "no percent without valid data")
        var few = sample(); few.event_count = 2
        withUnsafeMutableBytes(of: &few.events) { raw in
            let ring = raw.bindMemory(to: LiveEvent.self)
            ring[0].epoch = 1; ring[1].epoch = 2
        }
        check(GuardSnapshot(few).events.map(\.epoch) == [1, 2], "partial ring")

        // Party calls.
        check(s.lastCall == nil && s.partyCalls == 0, "no call yet")
        func calls(_ n: UInt32, caller: String = "Teratopositor", text: String = "j cit \u{2192}", pid: Int32 = 4242) -> GuardSnapshot {
            var d = sample(); d.pid = pid; d.chat_status = 1; d.party_calls = n; d.party_call_epoch = 77
            withUnsafeMutableBytes(of: &d.party_caller) { raw in for (i, b) in Array(caller.utf8).enumerated() { raw[i] = b } }
            withUnsafeMutableBytes(of: &d.party_text) { raw in for (i, b) in Array(text.utf8).enumerated() { raw[i] = b } }
            return GuardSnapshot(d)
        }
        check(calls(3).lastCall == PartyCall(caller: "Teratopositor", text: "j cit \u{2192}", epoch: 77, count: 3), "call decoded")
        check(calls(3).chatStatus == 1, "chat status")
        var tracker = PartyAlertTracker()
        check(tracker.update(calls(2), live: true, now: 0) == nil, "calls before the app watched are not replayed")
        check(tracker.update(calls(2), live: true, now: 1) == nil, "nothing new")
        check(tracker.update(calls(3), live: true, now: 2)?.count == 3, "a new call alerts")
        check(tracker.update(calls(4), live: true, now: 3) == nil, "a burst alerts once")
        check(tracker.update(calls(5), live: true, now: 6.5) == nil, "still within 5 s of the last alert")
        check(tracker.update(calls(6), live: true, now: 7.5)?.count == 6, "alerts again after a quiet period")
        check(tracker.update(calls(7), live: false, now: 20) == nil, "never from stale data")
        check(tracker.update(calls(8), live: true, now: 21)?.count == 8, "catches up when live again")
        check(tracker.update(calls(0, pid: 5000), live: true, now: 30) == nil, "a new session sets a new baseline")
        check(tracker.update(calls(1, pid: 5000), live: true, now: 31)?.count == 1, "first call of the new session")
        check(tracker.update(nil, live: true, now: 40) == nil, "no data")

        // Calls alert only on waiting maps.
        func at(_ map: String, known: Bool = true, _ n: UInt32) -> GuardSnapshot {
            var s = calls(n, pid: 6000); s.map = map; s.mapKnown = known; return s
        }
        for name in ["Nexus", "Vault", "Realm of the Mad God", "Guild Hall 3", "Pet Yard", "Daily Quest Room", "nexus"] {
            check(WaitingMaps.contains(at(name, 0)), "waiting map \(name)")
        }
        for name in ["Fungal Cavern", "Ice Citadel", "Crystal Cavern", "Oryx's Castle"] {
            check(!WaitingMaps.contains(at(name, 0)), "dungeon \(name)")
        }
        check(WaitingMaps.contains(at("", 0)) && WaitingMaps.contains(at("Fungal Cavern", known: false, 0)), "unknown map still alerts")
        var trip = PartyAlertTracker()
        _ = trip.update(at("Nexus", 0), live: true, now: 50)
        check(trip.update(at("Nexus", 1), live: true, now: 51)?.count == 1, "call while waiting alerts")
        check(trip.update(at("Fungal Cavern", 2), live: true, now: 60) == nil, "joined: calls in the dungeon are quiet")
        check(trip.update(at("Fungal Cavern", 3), live: true, now: 70) == nil, "still quiet")
        check(trip.update(at("Nexus", 3), live: true, now: 80) == nil, "leaving the dungeon does not replay its calls")
        check(trip.update(at("Nexus", 4), live: true, now: 81)?.count == 4, "next dungeon's call alerts")

        // Join status and popup rules.
        func joined(_ request: UInt32, _ result: Int32, map: String = "Nexus") -> GuardSnapshot {
            var d = sample(); d.join_request = request; d.join_result = result
            var s = GuardSnapshot(d); s.map = map; return s
        }
        check(JoinStatus.evaluate(sent: nil, snapshot: joined(0, 0), live: true) == .idle, "no click")
        check(JoinStatus.evaluate(sent: 2, snapshot: joined(1, 1), live: true) == .sending, "guard has not answered yet")
        check(JoinStatus.evaluate(sent: 2, snapshot: joined(2, 1), live: true) == .sent, "sent")
        check(JoinStatus.evaluate(sent: 2, snapshot: joined(2, -1), live: true) == .failed("The game refused the join"), "game error")
        check(JoinStatus.evaluate(sent: 2, snapshot: joined(2, -2), live: true) == .failed("No character or party to join with"), "unavailable")
        check(JoinStatus.evaluate(sent: 2, snapshot: joined(2, -4), live: true) == .failed("Join is not available in this game build"), "unsupported")
        check(JoinStatus.evaluate(sent: 2, snapshot: joined(2, 1), live: false) == .failed("Game not running"), "game closed")
        let inHub = joined(0, 0, map: "Nexus"), dungeon = joined(0, 0, map: "Fungal Cavern")
        check(!JoinPopupRules.shouldClose(shownAt: 0, now: 30, snapshot: inHub, live: true, status: .idle, statusSince: 0), "stays while waiting")
        check(JoinPopupRules.shouldClose(shownAt: 0, now: 90, snapshot: inHub, live: true, status: .idle, statusSince: 0), "times out")
        check(JoinPopupRules.shouldClose(shownAt: 0, now: 5, snapshot: dungeon, live: true, status: .idle, statusSince: 0), "closes in a dungeon")
        check(JoinPopupRules.shouldClose(shownAt: 0, now: 5, snapshot: inHub, live: false, status: .idle, statusSince: 0), "closes when the game closes")
        check(!JoinPopupRules.shouldClose(shownAt: 0, now: 5, snapshot: inHub, live: true, status: .sent, statusSince: 3), "shows Join sent briefly")
        check(JoinPopupRules.shouldClose(shownAt: 0, now: 8, snapshot: inHub, live: true, status: .sent, statusSince: 3), "then closes")
        check(!JoinPopupRules.shouldClose(shownAt: 0, now: 30, snapshot: inHub, live: true, status: .failed("x"), statusSince: 3), "an error stays visible")

        // Outcome text.
        let texts = [0: "dry run", 1: "sent", -1: "game error, disarmed", -2: "target unavailable", -3: "no potions"]
        for (code, text) in texts {
            let e = GuardEvent(epoch: 0, action: .potion, result: Int32(code), slot: 0, hp: 1, maxHP: 1)
            check(e.outcome == text, "outcome \(code)")
        }

        // Connection state.
        check(Link.evaluate(nil, nowNs: 1, processAlive: true) == .offline("Waiting for the guard"), "no data")
        check(Link.evaluate(s, nowNs: 5_100_000_000, processAlive: true) == .live(0.1), "live")
        check(Link.evaluate(s, nowNs: 5_300_000_000, processAlive: true) == .stale(0.3), "stale after 250 ms")
        check(Link.evaluate(s, nowNs: 5_100_000_000, processAlive: false) == .offline("Game closed"), "game closed")

        // Check rate.
        var meter = RateMeter()
        check(meter.add(ns: 0, ticks: 0) == nil, "one sample has no rate")
        check(abs((meter.add(ns: 500_000_000, ticks: 500) ?? 0) - 1000) < 0.001, "1 kHz")
        check(abs((meter.add(ns: 1_000_000_000, ticks: 1000) ?? 0) - 1000) < 0.001, "steady")
        check(meter.add(ns: 1_100_000_000, ticks: 5) == nil, "restart resets")

        // Reading a real file: header, then LiveData, exactly as the guard lays it out.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-model-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("guard-live.bin")
        var bytes = Data(count: Int(LIVE_FILE_SIZE))
        bytes.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: UInt32(LIVE_MAGIC), toByteOffset: 0, as: UInt32.self)
            raw.storeBytes(of: UInt32(LIVE_VERSION), toByteOffset: 4, as: UInt32.self)
            raw.storeBytes(of: UInt32(2), toByteOffset: 8, as: UInt32.self)       // even: not mid-write
            var d = sample()
            withUnsafeBytes(of: &d) { src in
                UnsafeMutableRawBufferPointer(rebasing: raw[16..<(16 + src.count)]).copyMemory(from: src)
            }
        }
        try! bytes.write(to: file)
        let feed = LiveFeed(url: file)
        check(feed.read() == s, "file read matches")
        bytes.withUnsafeMutableBytes { $0.storeBytes(of: UInt32(3), toByteOffset: 8, as: UInt32.self) }  // odd: writing
        try! bytes.write(to: folder.appendingPathComponent("busy.bin"))
        check(LiveFeed(url: folder.appendingPathComponent("busy.bin")).read() == nil, "mid-write is rejected")
        check(LiveFeed(url: folder.appendingPathComponent("missing.bin")).read() == nil, "missing file")
        try? FileManager.default.removeItem(at: folder)
        print("Guard model tests passed")
        SettingsTests.run()
        LaunchTests.run()
    }
}
