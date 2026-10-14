import Darwin
import Foundation

/// Where things live. The guard and the build check ship inside the app, so the app can be
/// moved anywhere; settings and logs go to ~/Library/Application Support/Exalt Client Mac.
enum GuardPaths {
    static func dataFolder(home: URL) -> URL { home.appendingPathComponent("Library/Application Support/Exalt Client Mac") }
    static func logs(data: URL) -> URL { data.appendingPathComponent("logs") }
    static func liveFile(data: URL) -> URL { logs(data: data).appendingPathComponent("guard-live.bin") }
    static func settingsFile(data: URL) -> URL { data.appendingPathComponent("guard-settings.conf") }
    static func resources(forApp bundle: URL) -> URL { bundle.standardizedFileURL.appendingPathComponent("Contents/Resources") }
}

/// The user-facing settings. Rules match guard_valid() in guard_core.h.
struct GuardSettings: Equatable {
    var armed: Bool
    var nexusOnDeath: Bool
    var potion: Int, ceiling: Int, nexus: Int

    static let standard = GuardSettings(armed: false, potion: 50, ceiling: 80, nexus: 25)

    /// Why these settings would be refused, or nil when they are valid.
    var problem: String? {
        for (name, value) in [("Potion", potion), ("Ceiling", ceiling), ("Nexus", nexus)] where !(0...100).contains(value) {
            return "\(name) must be between 0 and 100."
        }
        if potion > 0 && nexus > 0 && nexus >= potion { return "Nexus must be below the potion trigger." }
        if ceiling > 0 && potion == 0 { return "A ceiling needs a potion trigger." }
        if ceiling > 0 && ceiling <= potion { return "Ceiling must be above the potion trigger." }
        return nil
    }
    var text: String { "armed=\(armed ? 1 : 0),potion=\(potion),ceiling=\(ceiling),nexus=\(nexus)" + (nexusOnDeath ? ",death=1" : "") }

    init(armed: Bool, potion: Int, ceiling: Int, nexus: Int, nexusOnDeath: Bool = false) {
        self.armed = armed; self.potion = potion; self.ceiling = ceiling; self.nexus = nexus; self.nexusOnDeath = nexusOnDeath
    }
    /// Parses the launcher format; nil for anything the guard would reject.
    init?(text: String) {
        var values = ["armed": 0, "potion": 50, "ceiling": 0, "nexus": 25, "death": 0]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        for pair in trimmed.split(separator: ",") {
            let parts = pair.split(separator: "=", omittingEmptySubsequences: false)
            guard parts.count == 2, let key = Optional(String(parts[0])), values[key] != nil,
                  parts[1].count <= 3, let value = Int(parts[1]), value >= 0 else { return nil }
            values[key] = value
        }
        guard let armed = values["armed"], armed <= 1, values["death"]! <= 1 else { return nil }
        self.init(armed: armed == 1, potion: values["potion"]!, ceiling: values["ceiling"]!, nexus: values["nexus"]!, nexusOnDeath: values["death"]! == 1)
        if problem != nil { return nil }
    }
}

enum SettingsFile {
    static func load(_ url: URL) -> GuardSettings? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(GuardSettings.init(text:))
    }
    static func save(_ settings: GuardSettings, to url: URL) throws {
        try (settings.text + "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}

/// What the settings panel tells the user about the last Apply.
enum ApplyState: Equatable {
    case idle, waiting, applied, rejected, savedForNextLaunch

    static func evaluate(sent: UInt32?, live: Bool, controlRequest: UInt32, controlResult: Int32) -> ApplyState {
        guard let sent else { return .idle }
        guard live else { return .savedForNextLaunch }
        guard controlRequest == sent else { return .waiting }
        return controlResult == Int32(CONTROL_APPLIED) ? .applied : .rejected
    }
}

enum GuardAction: Int32 { case none = 0, potion = 1, nexus = 2, nexusOnDeath = 3 }

struct GuardEvent: Equatable {
    var epoch: Double
    var action: GuardAction
    var result: Int32
    var slot: Int
    var hp: Int
    var maxHP: Int

    var title: String { action == .nexusOnDeath ? "Nexus on death" : action == .potion ? "Potion" : action == .nexus ? "Nexus" : "-" }
    var outcome: String {
        if action == .nexusOnDeath && result == -1 { return "game error" }
        if action == .nexusOnDeath && result == -2 { return "Nexus not confirmed" }
        switch result {
        case 0: return "dry run"
        case 1: return "sent"
        case -1: return "game error, disarmed"
        case -2: return "target unavailable"
        case -3: return "no potions"
        default: return "result \(result)"
        }
    }
    var succeeded: Bool { result == 1 }
}

/// One consistent copy of the guard's live state.
struct GuardSnapshot: Equatable {
    var pid: Int32
    var status: Int32            // 0 valid, 1 starting, 2 waiting for HUD, 3 waiting for player, 4 bad data
    var armed: Bool
    var potion: Int, ceiling: Int, nexus: Int
    var mapKnown: Bool, inNexus: Bool, drinking: Bool, settled: Bool
    var hp: Int, maxHP: Int
    var hudHP: Float
    var stacks: [Int]
    var cooling: [Bool]
    var nextSlot: Int
    var map: String
    var sampleNs: UInt64
    var sampleEpoch: Double
    var ticks: UInt64
    var lastGapUs: UInt32, maxGapUs: UInt32, workNs: UInt32
    var eventCount: UInt32
    var events: [GuardEvent]      // oldest first, at most 16
    var controlRequest: UInt32, controlResult: Int32
    var summary: SessionSummary
    var chatStatus: Int32         // CHAT_SEARCHING, CHAT_READING or CHAT_UNAVAILABLE
    var partyCalls: UInt32
    var lastCall: PartyCall?
    var nexusOnDeath: Bool, deathReady: Bool, deathBlocking: Bool
    var deathStatus: Int32
    var deathPending: Int64, deathPredicted: Int64
    var joinRequest: UInt32, joinResult: Int32

    init(_ d: LiveData) {
        pid = d.pid; status = d.status; armed = d.armed != 0
        potion = Int(d.potion); ceiling = Int(d.ceiling); nexus = Int(d.nexus)
        mapKnown = d.map_known != 0; inNexus = d.in_nexus != 0
        drinking = d.drinking != 0; settled = d.settled != 0
        hp = Int(d.hp); maxHP = Int(d.max_hp); hudHP = d.hud_hp
        let count = max(0, min(Int(d.slot_count), Int(LIVE_SLOTS)))
        let allStacks = withUnsafeBytes(of: d.stacks) { Array($0.bindMemory(to: Int32.self)) }
        let allCooling = withUnsafeBytes(of: d.cooldown) { Array($0.bindMemory(to: Int32.self)) }
        stacks = allStacks.prefix(count).map(Int.init)
        cooling = allCooling.prefix(count).map { $0 != 0 }
        nextSlot = Int(d.next_slot)
        map = withUnsafeBytes(of: d.map) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
        sampleNs = d.sample_ns; sampleEpoch = d.sample_epoch; ticks = d.ticks
        lastGapUs = d.last_gap_us; maxGapUs = d.max_gap_us; workNs = d.work_ns
        eventCount = d.event_count
        controlRequest = d.control_request; controlResult = d.control_result
        summary = SessionSummary(
            start: d.session_start_epoch, potionsSent: Int(d.potions_sent), nexusSent: Int(d.nexus_sent),
            potionsDry: Int(d.potions_dry), nexusDry: Int(d.nexus_dry),
            lowestHP: Int(d.lowest_hp), lowestMaxHP: Int(d.lowest_max_hp), lowestEpoch: d.lowest_epoch,
            logName: withUnsafeBytes(of: d.log_name) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) })
        nexusOnDeath = d.death != 0; deathStatus = d.death_status
        deathReady = d.death_status == 1; deathBlocking = d.death_blocking != 0
        deathPending = d.death_pending; deathPredicted = d.death_predicted
        joinRequest = d.join_request; joinResult = d.join_result
        chatStatus = d.chat_status
        partyCalls = d.party_calls
        let text = { (raw: UnsafeRawBufferPointer) in String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self) }
        lastCall = d.party_calls == 0 ? nil : PartyCall(
            caller: withUnsafeBytes(of: d.party_caller, text), text: withUnsafeBytes(of: d.party_text, text),
            epoch: d.party_call_epoch, count: d.party_calls)
        let ring = withUnsafeBytes(of: d.events) { Array($0.bindMemory(to: LiveEvent.self)) }
        let shown = Int(min(d.event_count, UInt32(LIVE_EVENTS)))
        events = (0..<shown).map { k in
            let e = ring[Int((d.event_count - UInt32(shown) + UInt32(k)) % UInt32(LIVE_EVENTS))]
            return GuardEvent(epoch: e.epoch, action: GuardAction(rawValue: e.action) ?? .none,
                              result: e.result, slot: Int(e.slot), hp: Int(e.hp), maxHP: Int(e.max_hp))
        }
    }

    var percent: Double? { maxHP > 0 && status == 0 ? Double(hp) * 100 / Double(maxHP) : nil }
    var totalPotions: Int { stacks.reduce(0, +) }
    /// Where drinking stops: the ceiling, or the potion threshold when there is none.
    var stopPercent: Int { ceiling > 0 ? ceiling : potion }
    var settings: GuardSettings { GuardSettings(armed: armed, potion: potion, ceiling: ceiling, nexus: nexus, nexusOnDeath: nexusOnDeath) }
}

/// Counts for the current game session, kept by the guard.
struct SessionSummary: Equatable {
    var start: Double
    var potionsSent: Int, nexusSent: Int, potionsDry: Int, nexusDry: Int
    var lowestHP: Int, lowestMaxHP: Int, lowestEpoch: Double
    var logName: String

    var closestPercent: Double? { lowestMaxHP > 0 ? Double(lowestHP) * 100 / Double(lowestMaxHP) : nil }
    var closestText: String {
        guard let percent = closestPercent else { return "None yet" }
        return String(format: "%.0f%% (%d/%d)", percent, lowestHP, lowestMaxHP)
    }
}

/// The newest party "j" or "join" call from another player. `count` is the session's total so far.
struct PartyCall: Equatable {
    var caller: String
    var text: String
    var epoch: Double
    var count: UInt32
}

/// Where a Join click stands, from the guard's answer in the live file.
enum JoinStatus: Equatable {
    case idle, sending, sent
    case failed(String)

    static func evaluate(sent: UInt32?, snapshot: GuardSnapshot?, live: Bool) -> JoinStatus {
        guard let sent else { return .idle }
        guard let s = snapshot, live else { return .failed("Game not running") }
        guard s.joinRequest == sent else { return .sending }
        switch s.joinResult {
        case Int32(JOIN_SENT): return .sent
        case Int32(JOIN_ERROR): return .failed("The game refused the join")
        case Int32(JOIN_UNAVAILABLE): return .failed("No character or party to join with")
        default: return .failed("Join is not available in this game build")
        }
    }
    var text: String {
        switch self {
        case .idle: return ""
        case .sending: return "Joining..."
        case .sent: return "Join sent"
        case .failed(let why): return why
        }
    }
}

/// When the Join popup for a call goes away: once you are in a dungeon, a few seconds after a
/// join went through, or after `timeout` with no answer.
enum JoinPopupRules {
    static let timeout = 90.0
    static let afterJoin = 4.0
    static func shouldClose(shownAt: Double, now: Double, snapshot: GuardSnapshot?, live: Bool,
                            status: JoinStatus, statusSince: Double) -> Bool {
        if now - shownAt >= timeout || !live { return true }
        if let s = snapshot, !WaitingMaps.contains(s) { return true }
        return status == .sent && now - statusSince >= afterJoin
    }
}

/// Party alert preferences, kept by the app (the guard always reports calls).
struct PartyAlertSettings: Equatable {
    var enabled = true
    var sound = true
}

/// Maps where you wait for a dungeon. Calls alert only here: once you are in the dungeon, more
/// "j" calls for it are noise. Matched by how the game's map name starts ("Guild Hall 3").
enum WaitingMaps {
    static let prefixes = ["Nexus", "Vault", "Realm of the Mad God", "Guild Hall", "Pet Yard", "Daily Quest Room"]
    /// An unknown map counts as waiting, so a map-reading problem never hides a call.
    static func contains(_ snapshot: GuardSnapshot) -> Bool {
        guard snapshot.mapKnown, !snapshot.map.isEmpty else { return true }
        let name = snapshot.map.lowercased()
        return prefixes.contains { name.hasPrefix($0.lowercased()) }
    }
}

/// Decides when a party call should alert. The first snapshot of each guard session sets a
/// baseline, so calls counted before the app was watching are not replayed. After that, each
/// new call alerts, except that a burst (one player spamming "jjjj" ten times) alerts once per
/// `quiet` seconds, and calls made while you are in a dungeon (not a WaitingMaps map) are skipped.
struct PartyAlertTracker {
    var quiet: Double = 5
    private var pid: Int32 = 0
    private var seen: UInt32 = 0
    private var lastAlert = -Double.infinity

    /// `now`: seconds on any steadily increasing clock.
    mutating func update(_ snapshot: GuardSnapshot?, live: Bool, now: Double) -> PartyCall? {
        guard let s = snapshot, live else { return nil }
        if s.pid != pid { pid = s.pid; seen = s.partyCalls; return nil }
        guard s.partyCalls > seen, let call = s.lastCall else { seen = s.partyCalls; return nil }
        seen = s.partyCalls
        guard WaitingMaps.contains(s), now - lastAlert >= quiet else { return nil }
        lastAlert = now
        return call
    }
}

enum Link: Equatable {
    case offline(String)    // no file, no data, or the game has exited
    case stale(Double)      // data older than the limit (seconds)
    case live(Double)       // age of the data in seconds

    static let staleAfter = 0.25

    static func evaluate(_ snapshot: GuardSnapshot?, nowNs: UInt64, processAlive: Bool) -> Link {
        guard let s = snapshot, s.sampleNs > 0 else { return .offline("Waiting for the guard") }
        let age = nowNs > s.sampleNs ? Double(nowNs - s.sampleNs) / 1e9 : 0
        if !processAlive { return .offline("Game closed") }
        return age > staleAfter ? .stale(age) : .live(age)
    }
    var isLive: Bool { if case .live = self { return true } else { return false } }
}

/// Checks per second, measured from the guard's own counter over a sliding window.
struct RateMeter {
    private var samples: [(ns: UInt64, ticks: UInt64)] = []
    private let window: UInt64 = 1_000_000_000

    mutating func add(ns: UInt64, ticks: UInt64) -> Double? {
        if let last = samples.last, ticks < last.ticks { samples.removeAll() }   // guard restarted
        if samples.last?.ns != ns { samples.append((ns, ticks)) }
        while let first = samples.first, ns - first.ns > window, samples.count > 2 { samples.removeFirst() }
        guard let first = samples.first, let last = samples.last, last.ns > first.ns else { return nil }
        return Double(last.ticks - first.ticks) * 1e9 / Double(last.ns - first.ns)
    }
}

/// Maps the guard's live file, copies consistent snapshots, and sends settings changes.
final class LiveFeed {
    let url: URL
    private var map: UnsafeMutableRawPointer?
    private var inode: ino_t = 0
    private var writable = false

    init(url: URL) { self.url = url }
    deinit { unmap() }

    func read() -> GuardSnapshot? {
        remapIfNeeded()
        guard let map else { return nil }
        var data = LiveData()
        guard guard_live_copy(map, &data) != 0 else { return nil }
        return GuardSnapshot(data)
    }

    /// Writes a settings change for the guard to pick up on its next check.
    func send(_ settings: GuardSettings, request: UInt32) -> Bool {
        remapIfNeeded()
        guard let map, writable else { return false }
        var data = LiveControlData(request: request, armed: settings.armed ? 1 : 0, potion: Int32(settings.potion),
                                   ceiling: Int32(settings.ceiling), nexus: Int32(settings.nexus), death: settings.nexusOnDeath ? 1 : 0)
        guard_control_send(map, &data)
        return true
    }
    /// Asks the guard to join `name`'s dungeon, as the game's ctrl-click menu does.
    func sendJoin(_ name: String, request: UInt32) -> Bool {
        remapIfNeeded()
        guard let map, writable else { return false }
        var data = LiveJoinData()
        data.request = request
        withUnsafeMutableBytes(of: &data.name) { raw in
            for (i, b) in Array(name.utf8.prefix(raw.count - 1)).enumerated() { raw[i] = b }
        }
        guard_join_send(map, &data)
        return true
    }
    func peekControl(_ out: inout LiveControlData) -> Bool {
        remapIfNeeded()
        guard let map else { return false }
        return guard_control_peek(map, &out) != 0
    }

    /// The guard recreates the file each session; follow it when the inode changes.
    private func remapIfNeeded() {
        var info = stat()
        guard stat(url.path, &info) == 0, info.st_size >= Int64(LIVE_FILE_SIZE) else { unmap(); return }
        if map != nil && info.st_ino == inode { return }
        unmap()
        var fd = open(url.path, O_RDWR)
        let canWrite = fd >= 0
        if !canWrite { fd = open(url.path, O_RDONLY) }
        guard fd >= 0 else { return }
        defer { close(fd) }
        let pointer = mmap(nil, Int(LIVE_FILE_SIZE), canWrite ? PROT_READ | PROT_WRITE : PROT_READ, MAP_SHARED, fd, 0)
        guard let pointer, pointer != MAP_FAILED else { return }
        map = pointer; inode = info.st_ino; writable = canWrite
    }
    private func unmap() {
        if let map { munmap(map, Int(LIVE_FILE_SIZE)) }
        map = nil; inode = 0; writable = false
    }
}

enum Clock {
    static func monotonicNs() -> UInt64 { clock_gettime_nsec_np(CLOCK_MONOTONIC) }
}

enum Format {
    static func time(_ epoch: Double) -> String {
        let date = Date(timeIntervalSince1970: epoch)
        let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter.string(from: date)
    }
    /// h:mm:ss above an hour, otherwise m:ss.
    static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        let h = total / 3600, m = total / 60 % 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    static func ms(_ microseconds: UInt32) -> String { String(format: "%.1f ms", Double(microseconds) / 1000) }
    static func age(_ seconds: Double) -> String {
        seconds < 1 ? String(format: "%.0f ms", seconds * 1000) : String(format: "%.1f s", seconds)
    }
}
