import Foundation

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAILED line \(line): \(message)") }
}

enum SettingsTests {
    static func run() {
        // Same rules as guard_valid in guard_core.h.
        check(GuardSettings(armed: true, potion: 50, ceiling: 80, nexus: 25).problem == nil, "default valid")
        check(GuardSettings(armed: true, potion: 0, ceiling: 0, nexus: 30).problem == nil, "potion off")
        check(GuardSettings(armed: true, potion: 60, ceiling: 0, nexus: 0).problem == nil, "nexus off")
        check(GuardSettings(armed: true, potion: 50, ceiling: 0, nexus: 50).problem != nil, "nexus must be below potion")
        check(GuardSettings(armed: true, potion: 50, ceiling: 40, nexus: 25).problem != nil, "ceiling above potion")
        check(GuardSettings(armed: true, potion: 50, ceiling: 50, nexus: 25).problem != nil, "ceiling strictly above")
        check(GuardSettings(armed: true, potion: 0, ceiling: 80, nexus: 25).problem != nil, "ceiling needs potion")
        check(GuardSettings(armed: true, potion: 101, ceiling: 0, nexus: 25).problem != nil, "range")

        // Text form, as the launcher passes it to the guard.
        let s = GuardSettings(armed: true, potion: 50, ceiling: 80, nexus: 25)
        check(s.text == "armed=1,potion=50,ceiling=80,nexus=25", "text \(s.text)")
        check(GuardSettings(text: s.text) == s, "round trip")
        check(GuardSettings(text: "armed=0,potion=40,nexus=20") == GuardSettings(armed: false, potion: 40, ceiling: 0, nexus: 20), "ceiling optional")
        check(GuardSettings(text: "  armed=1,potion=50,ceiling=80,nexus=25\n") == s, "whitespace")
        for bad in ["armed=2", "potion=abc", "bogus=1", "armed=1,potion=20,nexus=30", ""] {
            check(GuardSettings(text: bad) == nil, "rejects \(bad)")
        }

        // Saved file: written atomically, read back.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("guard-settings-\(getpid())")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("guard-settings.conf")
        check(SettingsFile.load(file) == nil, "missing file")
        try! SettingsFile.save(s, to: file)
        check(SettingsFile.load(file) == s, "saved and loaded")
        check((try? String(contentsOf: file, encoding: .utf8)) == "armed=1,potion=50,ceiling=80,nexus=25\n", "file contents")

        // Settings channel: what the app sends is what the guard reads.
        let live = folder.appendingPathComponent("guard-live.bin")
        FileManager.default.createFile(atPath: live.path, contents: Data(count: Int(LIVE_FILE_SIZE)))
        let feed = LiveFeed(url: live)
        check(feed.send(GuardSettings(armed: false, potion: 45, ceiling: 70, nexus: 20), request: 7), "send")
        var seen = LiveControlData()
        check(feed.peekControl(&seen) && seen.request == 7 && seen.armed == 0 && seen.potion == 45 &&
              seen.ceiling == 70 && seen.nexus == 20, "guard sees the change")
        check(!LiveFeed(url: folder.appendingPathComponent("missing.bin")).send(s, request: 1), "no file, no send")

        // Apply status shown to the user.
        check(ApplyState.evaluate(sent: nil, live: true, controlRequest: 0, controlResult: 0) == .idle, "idle")
        check(ApplyState.evaluate(sent: 3, live: true, controlRequest: 2, controlResult: 1) == .waiting, "waiting")
        check(ApplyState.evaluate(sent: 3, live: true, controlRequest: 3, controlResult: 1) == .applied, "applied")
        check(ApplyState.evaluate(sent: 3, live: true, controlRequest: 3, controlResult: 2) == .rejected, "rejected")
        check(ApplyState.evaluate(sent: 3, live: false, controlRequest: 0, controlResult: 0) == .savedForNextLaunch, "offline")
        try? FileManager.default.removeItem(at: folder)
        print("Guard settings tests passed")
    }
}
