import Foundation

private func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition { fatalError("FAILED line \(line): \(message)") }
}

enum LaunchTests {
    static func run() {
        let home = URL(fileURLWithPath: "/Users/x")
        let install = GameInstall.standard(home: home)
        check(install.gameAssembly.path == "/Users/x/.local/share/RealmOfTheMadGod/Production/RotMGExalt.app/Contents/Frameworks/GameAssembly.dylib", "game path")
        check(install.launcher.path == "/Applications/RotMG Exalt Launcher/RotMG Exalt Launcher.app/Contents/MacOS/RotMG Exalt Launcher", "launcher path")
        // Self-contained app: the guard and the build check ship inside it; data lives in
        // Application Support so the app can sit anywhere (Applications, Dock).
        let app = URL(fileURLWithPath: "/Users/x/Applications/Exalt Client Mac.app")
        check(GuardPaths.dylib(forApp: app).path == "/Users/x/Applications/Exalt Client Mac.app/Contents/Resources/ExaltGuard.dylib", "dylib path")
        check(GuardPaths.buildHashFile(forApp: app).path == "/Users/x/Applications/Exalt Client Mac.app/Contents/Resources/game-build.sha256", "hash file")
        let data = GuardPaths.dataFolder(home: home)
        check(data.path == "/Users/x/Library/Application Support/Exalt Client Mac", "data folder")
        check(GuardPaths.logs(data: data).path == "/Users/x/Library/Application Support/Exalt Client Mac/logs", "logs")
        check(GuardPaths.liveFile(data: data).path == "/Users/x/Library/Application Support/Exalt Client Mac/logs/guard-live.bin", "live file")
        check(GuardPaths.settingsFile(data: data).path == "/Users/x/Library/Application Support/Exalt Client Mac/guard-settings.conf", "settings")

        let settings = GuardSettings(armed: true, potion: 50, ceiling: 80)
        let dylib = URL(fileURLWithPath: "/g/ExaltGuard.dylib")
        let all: (URL) -> Bool = { _ in true }
        func plan(expected: String? = "abc", actual: String? = "abc", running: [String] = [], exists: @escaping (URL) -> Bool = all) -> Result<LaunchPlan, LaunchProblem> {
            LaunchPlan.make(install: install, dylib: dylib, data: URL(fileURLWithPath: "/d"), settings: settings, expectedHash: expected,
                            actualHash: actual, running: running, exists: exists)
        }
        guard case .success(let ok) = plan() else { fatalError("expected a plan") }
        check(ok.executable == install.launcher, "runs DECA's launcher")
        check(ok.environment["EXALT_GUARD"] == "armed=1,potion=50,ceiling=80", "settings passed")
        check(ok.environment["DYLD_INSERT_LIBRARIES"] == "/g/ExaltGuard.dylib", "guard injected for this launch only")
        check(ok.environment["EXALT_GUARD_DIR"] == "/d", "guard writes to the app's data folder")

        guard case .success(let capture) = LaunchPlan.make(install: install, dylib: dylib, data: data,
                settings: settings, expectedHash: "abc", actualHash: "abc", running: [], observationOnly: true, exists: all)
        else { fatalError("expected capture plan") }
        check(capture.environment["EXALT_GUARD"] == "armed=0,potion=0,ceiling=0,death=0", "capture disables automation")
        check(capture.environment["EXALT_FATAL_INTERVENTION"] == "0" && capture.environment["EXALT_VERIFY_ONE_HP"] == "0", "capture overrides inherited intervention")
        check(settings.armed && settings.potion == 50, "capture preserves supplied settings")

        check(plan(exists: { $0 != install.launcher }) == .failure(.launcherMissing), "launcher missing")
        check(plan(exists: { $0 != install.gameAssembly }) == .failure(.gameMissing), "game missing")
        check(plan(exists: { $0 != dylib }) == .failure(.guardMissing), "guard missing")
        check(plan(expected: nil) == .failure(.buildUnknown), "no recorded build")
        check(plan(actual: "def") == .failure(.gameUpdated), "game updated")
        check(plan(running: ["Finder", "RotMGExalt"]) == .failure(.gameRunning), "game already running")
        check(plan(running: ["RotMG Exalt Launcher"]) == .failure(.launcherRunning), "launcher already running")
        check(LaunchProblem.gameUpdated.message.contains("updated"), "update message")
        for problem in [LaunchProblem.launcherMissing, .gameMissing, .guardMissing, .buildUnknown, .gameUpdated, .gameRunning, .launcherRunning] {
            check(!problem.message.isEmpty, "message for \(problem)")
        }

        // SHA-256 of a file, streamed (the real file is 84 MB).
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hash-\(getpid()).bin")
        try! Data("abc".utf8).write(to: file)
        check(FileHash.sha256(file) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "sha256")
        check(FileHash.sha256(URL(fileURLWithPath: "/nonexistent")) == nil, "missing file")
        try? FileManager.default.removeItem(at: file)
        check(FileHash.expected(from: "0D11BBB7  \n") == "0d11bbb7", "hash file trimmed and lowercased")
        check(FileHash.expected(from: "") == nil, "empty hash file")

        // Session summary text.
        var d = LiveData()
        d.potions_sent = 3; d.nexus_sent = 1; d.potions_dry = 0; d.nexus_dry = 0
        d.lowest_hp = 40; d.lowest_max_hp = 235; d.lowest_epoch = 100; d.session_start_epoch = 40
        withUnsafeMutableBytes(of: &d.log_name) { raw in for (i, b) in Array("guard-7.tsv".utf8).enumerated() { raw[i] = b } }
        let s = GuardSnapshot(d)
        check(s.summary.potionsSent == 3 && s.summary.nexusSent == 1 && s.summary.logName == "guard-7.tsv", "summary counts")
        check(s.summary.closestPercent.map { abs($0 - 17.02) < 0.01 } == true, "closest call percent")
        check(s.summary.closestText == "17% (40/235)", "closest text \(s.summary.closestText)")
        d.lowest_max_hp = 0
        check(GuardSnapshot(d).summary.closestText == "None yet", "no closest call yet")
        check(Format.duration(3725) == "1:02:05" && Format.duration(65) == "1:05", "durations")
        // Log export: session logs and settings in one zip; the live file stays out.
        let exportData = FileManager.default.temporaryDirectory.appendingPathComponent("export-data-\(getpid())")
        let exportLogs = GuardPaths.logs(data: exportData)
        try! FileManager.default.createDirectory(at: exportLogs, withIntermediateDirectories: true)
        try! Data("status\tguard_loaded\n".utf8).write(to: exportLogs.appendingPathComponent("guard-1.tsv"))
        try! Data("status\tguard_loaded\n".utf8).write(to: exportLogs.appendingPathComponent("guard-2.tsv"))
        try! Data(count: 4096).write(to: exportLogs.appendingPathComponent("guard-live.bin"))
        try! SettingsFile.save(GuardSettings(armed: true, potion: 50, ceiling: 80), to: GuardPaths.settingsFile(data: exportData))
        let zip = exportData.appendingPathComponent("export.zip")
        check((try? LogExport.export(data: exportData, to: zip)) == 2, "two session logs exported")
        let list = Process(); let pipe = Pipe()
        list.executableURL = URL(fileURLWithPath: "/usr/bin/unzip"); list.arguments = ["-Z1", zip.path]; list.standardOutput = pipe
        try! list.run(); list.waitUntilExit()
        let entries = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").map(String.init)
        check(entries.contains("export/guard-1.tsv") && entries.contains("export/guard-2.tsv"), "logs in zip \(entries)")
        check(entries.contains("export/guard-settings.conf"), "settings in zip")
        check(!entries.contains { $0.hasSuffix("guard-live.bin") }, "live file left out")
        check(LogExport.defaultName(date: Date(timeIntervalSince1970: 0)).hasPrefix("Exalt Client Mac logs 19"), "default name")
        try? FileManager.default.removeItem(at: exportData)
        print("Guard launch and summary tests passed")
    }
}
