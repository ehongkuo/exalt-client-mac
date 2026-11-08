import Foundation

/// Bundles the session logs and saved settings into one zip for sharing or troubleshooting.
/// The live-state file is left out: it only holds the latest moment and is rewritten constantly.
enum LogExport {
    static func defaultName(date: Date = Date()) -> String {
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd HHmm"
        return "Exalt Client Mac logs \(formatter.string(from: date)).zip"
    }

    /// Returns the number of session logs included.
    @discardableResult
    static func export(data: URL, to zip: URL) throws -> Int {
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("exalt-export-\(UUID().uuidString)")
        let folder = staging.appendingPathComponent(zip.deletingPathExtension().lastPathComponent)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let logs = GuardPaths.logs(data: data)
        let sessions = ((try? fm.contentsOfDirectory(atPath: logs.path)) ?? [])
            .filter { $0.hasPrefix("guard-") && $0.hasSuffix(".tsv") }.sorted()
        for name in sessions {
            try fm.copyItem(at: logs.appendingPathComponent(name), to: folder.appendingPathComponent(name))
        }
        let settings = GuardPaths.settingsFile(data: data)
        if fm.fileExists(atPath: settings.path) {
            try fm.copyItem(at: settings, to: folder.appendingPathComponent(settings.lastPathComponent))
        }
        try? fm.removeItem(at: zip)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", folder.path, zip.path]
        try ditto.run(); ditto.waitUntilExit()
        guard ditto.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        return sessions.count
    }
}

/// Deletes session logs and diagnostic recordings not written to for `keepDays`, so one-off
/// sessions don't pile up. A running game's log is written every second, so it is never old.
enum LogCleanup {
    static let keepDays = 14.0

    /// Returns the number of files removed. The live file is never touched.
    @discardableResult
    static func removeOld(data: URL, now: Date = Date(), keepDays: Double = keepDays) -> Int {
        let fm = FileManager.default
        let logs = GuardPaths.logs(data: data)
        let cutoff = now.addingTimeInterval(-keepDays * 86400)
        var removed = 0
        for name in (try? fm.contentsOfDirectory(atPath: logs.path)) ?? []
        where (name.hasPrefix("guard-") && name.hasSuffix(".tsv")) || (name.hasPrefix("hit-flight-") && name.hasSuffix(".bin")) {
            let url = logs.appendingPathComponent(name)
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  modified < cutoff, (try? fm.removeItem(at: url)) != nil else { continue }
            removed += 1
        }
        return removed
    }
}
