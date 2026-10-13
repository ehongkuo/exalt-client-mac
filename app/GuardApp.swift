import AppKit
import UniformTypeIdentifiers
import SwiftUI
import UserNotifications

private let mint = Color(red: 0.35, green: 0.88, blue: 0.72)
private let amber = Color(red: 0.98, green: 0.74, blue: 0.30)
private let coral = Color(red: 0.98, green: 0.42, blue: 0.40)

#if GUARD_UI_TEST
private let liveURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_LIVE_FILE"] ?? "/dev/null")
private let settingsURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_SETTINGS_FILE"] ?? "/dev/null")
private let dataURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_DATA_DIR"] ?? "/nonexistent")
#else
private let dataURL = GuardPaths.dataFolder(home: FileManager.default.homeDirectoryForCurrentUser)
private let liveURL = GuardPaths.liveFile(data: dataURL)
private let settingsURL = GuardPaths.settingsFile(data: dataURL)
#endif

/// Reads the live file once per screen refresh. Not observable: the TimelineView drives redraws.
final class LiveSource {
    let feed = LiveFeed(url: liveURL)
    private var meter = RateMeter()
    private(set) var snapshot: GuardSnapshot?
    private(set) var link: Link = .offline("Waiting for the guard")
    private(set) var rate: Double?

    func refresh() {
        if let fresh = feed.read() {
            snapshot = fresh
            rate = meter.add(ns: fresh.sampleNs, ticks: fresh.ticks)
        }
        let alive = snapshot.map { guard_process_alive($0.pid) != 0 } ?? false
        link = Link.evaluate(snapshot, nowNs: Clock.monotonicNs(), processAlive: alive)
    }
}

/// The settings panel: a draft the user edits, saved to guard-settings.conf and sent to the
/// running guard on Apply. The Armed switch applies immediately.
final class SettingsController: ObservableObject {
    @Published var draft: GuardSettings
    /// What Start uses: the settings last saved to guard-settings.conf.
    @Published private(set) var saved: GuardSettings
    @Published private(set) var sentRequest: UInt32?
    @Published private(set) var error: String?
    private var lastRequest: UInt32 = 0
    private var syncedPid: Int32 = 0

    init() { let loaded = SettingsFile.load(settingsURL) ?? .standard; saved = loaded; draft = loaded }

    /// When a new guard session goes live, show what it is actually running. A closed session's
    /// settings are not adopted: the panel then edits the saved settings for the next launch.
    func sync(with snapshot: GuardSnapshot?, live: Bool) {
        guard live, let s = snapshot, s.pid != syncedPid else { return }
        syncedPid = s.pid; draft = s.settings; sentRequest = nil; lastRequest = s.controlRequest
    }
    func apply(_ settings: GuardSettings, source: LiveSource) {
        draft = settings
        if let problem = settings.problem { error = problem; return }
        error = nil
        do { try SettingsFile.save(settings, to: settingsURL); saved = settings }
        catch { self.error = "Could not save settings: \(error.localizedDescription)" }
        lastRequest = max(lastRequest, source.snapshot?.controlRequest ?? 0) + 1
        sentRequest = source.link.isLive && source.feed.send(settings, request: lastRequest) ? lastRequest : 0
    }
    func state(_ source: LiveSource) -> ApplyState {
        ApplyState.evaluate(sent: sentRequest == 0 ? nil : sentRequest, live: source.link.isLive,
                            controlRequest: source.snapshot?.controlRequest ?? 0,
                            controlResult: source.snapshot?.controlResult ?? 0)
            .replacingIdle(savedOffline: sentRequest == 0)
    }
}

private extension ApplyState {
    func replacingIdle(savedOffline: Bool) -> ApplyState { self == .idle && savedOffline ? .savedForNextLaunch : self }
}

/// Runs the same checks as Start Guard.command, then starts DECA's launcher with the guard.
final class LaunchController: ObservableObject {
    enum State: Equatable { case idle, checking, launched(Date), failed(String) }
    @Published private(set) var state: State = .idle

    func start() {
        guard state != .checking else { return }
        state = .checking
        #if GUARD_UI_TEST
        let bundle = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_APP_BUNDLE"] ?? "/nonexistent/Exalt Client Mac.app")
        #else
        let bundle = Bundle.main.bundleURL
        #endif
        let settings = SettingsFile.load(settingsURL) ?? .standard
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.executableURL?.lastPathComponent }
        DispatchQueue.global(qos: .userInitiated).async {
            let install = GameInstall.standard(home: FileManager.default.homeDirectoryForCurrentUser)
            let dylib = GuardPaths.dylib(forApp: bundle)
            let expected = (try? String(contentsOf: GuardPaths.buildHashFile(forApp: bundle), encoding: .utf8)).flatMap(FileHash.expected)
            let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
            func plan(_ actual: String?) -> Result<LaunchPlan, LaunchProblem> {
                LaunchPlan.make(install: install, dylib: dylib, data: dataURL, settings: settings, expectedHash: expected,
                                actualHash: actual, running: running, exists: exists)
            }
            try? FileManager.default.createDirectory(at: GuardPaths.logs(data: dataURL), withIntermediateDirectories: true,
                                                     attributes: [.posixPermissions: 0o700])
            // Hash the 84 MB game file only once the cheap checks pass.
            var result = plan(nil)
            if result == .failure(.gameUpdated) { result = plan(FileHash.sha256(install.gameAssembly)) }
            let next: State
            switch result {
            case .failure(let problem): next = .failed(problem.message)
            case .success(let launch):
                do { try GameLauncher.start(launch); next = .launched(Date()) }
                catch { next = .failed("Could not start DECA's launcher: \(error.localizedDescription)") }
            }
            DispatchQueue.main.async { self.state = next }
        }
    }
}

/// Party call alerts: a notification banner, a sound and a flash on the compact strip. Checked
/// on a timer rather than by the views, which stop redrawing while hidden or behind a
/// full-screen game. Preferences are kept in the app's defaults.
final class PartyAlerts: ObservableObject {
    @Published var settings: PartyAlertSettings { didSet { save() } }
    @Published private(set) var flashUntil = Date.distantPast
    private var tracker = PartyAlertTracker()
    private let defaults = UserDefaults.standard
    /// Notifications need a bundled app; the test build runs without one.
    private var canNotify: Bool {
        #if GUARD_UI_TEST
        return false
        #else
        return Bundle.main.bundleIdentifier != nil
        #endif
    }

    init() {
        settings = PartyAlertSettings(enabled: defaults.object(forKey: "partyAlerts") as? Bool ?? true,
                                      sound: defaults.object(forKey: "partyAlertSound") as? Bool ?? true)
    }
    private func save() {
        defaults.set(settings.enabled, forKey: "partyAlerts")
        defaults.set(settings.sound, forKey: "partyAlertSound")
        if settings.enabled { requestPermission() }
    }
    func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
    func check(_ source: LiveSource) {
        // The tracker sees every snapshot even with alerts off, so turning them on never replays old calls.
        guard let call = tracker.update(source.snapshot, live: source.link.isLive, now: Double(Clock.monotonicNs()) / 1e9),
              settings.enabled else { return }
        alert(call)
    }
    func alert(_ call: PartyCall) {
        flashUntil = Date().addingTimeInterval(8)
        #if !GUARD_UI_TEST
        if settings.sound { NSSound(named: "Glass")?.play() }
        #endif
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "Party call from \(call.caller)"
        content.body = call.text
        // One notification at a time: a newer call replaces the previous banner.
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "party-call", content: content, trigger: nil))
    }
    func flashing(at date: Date) -> Bool { date < flashUntil }
}

final class WindowState: ObservableObject {
    @Published var floating = false
    var window: NSWindow?
    var showCompact: () -> Void = {}
    func setFloating(_ value: Bool) { floating = value; window?.level = value ? .floating : .normal }
}

struct Card<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Color.white.opacity(0.045))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.07)))
    }
}

struct Pill: View {
    var text: String
    var color: Color
    var body: some View {
        Text(text).font(.system(size: 11, weight: .bold))
            .lineLimit(1).fixedSize()
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(color.opacity(0.18)).foregroundStyle(color)
            .clipShape(Capsule())
    }
}

/// HP bar with markers at the Nexus, potion and ceiling thresholds.
struct HPBar: View {
    var fraction: Double
    var nexus: Int, potion: Int, ceiling: Int
    var color: Color
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: 6).fill(color).frame(width: max(0, min(1, fraction)) * w)
                ForEach([(nexus, coral), (potion, amber), (ceiling, mint)], id: \.0) { value, tint in
                    if value > 0 {
                        Rectangle().fill(tint).frame(width: 2).offset(x: w * Double(value) / 100 - 1)
                    }
                }
            }
        }
        .frame(height: 18)
    }
}

struct GuardView: View {
    let source: LiveSource
    @ObservedObject var window: WindowState
    @ObservedObject var settings: SettingsController
    @ObservedObject var launch: LaunchController
    @ObservedObject var alerts: PartyAlerts

    var body: some View {
        TimelineView(.animation) { _ in
            let _ = source.refresh()
            let _ = settings.sync(with: source.snapshot, live: source.link.isLive)
            MainLayout {
                GuardPanel(window: window, settings: settings, launch: launch, alerts: alerts, source: source).content(source.snapshot, source.link, source.rate)
            }
        }
        .frame(minWidth: 420, minHeight: 360)
        .preferredColorScheme(.dark)
    }
}

/// Window body: scrolls when the window is shorter than the content (the live layout is
/// taller than most laptop screens), always starting at the top so the header stays reachable.
struct MainLayout<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView(.vertical) {
            content.padding(16).frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
    }
}

/// The window's contents for one snapshot; separate from the timeline so it can be rendered offscreen.
struct GuardPanel {
    @ObservedObject var window: WindowState
    @ObservedObject var settings: SettingsController
    @ObservedObject var launch: LaunchController
    @ObservedObject var alerts: PartyAlerts
    let source: LiveSource

    @ViewBuilder func content(_ s: GuardSnapshot?, _ link: Link, _ rate: Double?) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            header(s, link)
            if case .offline = link {
                // No game running (never started, or it closed): offer Start, keep the last
                // session's summary visible, and edit settings for the next launch.
                startCard(link)
                if let s, link == .offline("Game closed") { summaryCard(s, title: "Last session") }
                settingsCard(nil)
                partyCard(nil)
            } else if let s {
                mapCard(s)
                hpCard(s)
                summaryCard(s)
                partyCard(s)
                settingsCard(s)
                potionCard(s)
                eventsCard(s)
                latencyCard(s, link, rate)
            }
            Spacer(minLength: 0)
        }
    }

    private func header(_ s: GuardSnapshot?, _ link: Link) -> some View {
        // Live or stale: what the guard is running. Not running: what Start will use.
        let running: Bool = { switch link { case .live, .stale: return true; case .offline: return false } }()
        let armed = running ? (s?.armed ?? settings.saved.armed) : settings.saved.armed
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Exalt Client Mac").font(.system(size: 18, weight: .semibold)).lineLimit(1).fixedSize()
                Spacer()
                switch link {
                case .live: Pill(text: "LIVE", color: mint)
                case .stale(let age): Pill(text: "STALE \(Format.age(age))", color: amber)
                case .offline(let why): Pill(text: why == "Game closed" ? "GAME CLOSED" : "OFFLINE", color: coral)
                }
                Pill(text: armed ? "ARMED" : "DRY RUN", color: armed ? mint : .gray)
            }
            HStack(spacing: 12) {
                Spacer()
                Toggle("Keep on top", isOn: Binding(get: { window.floating }, set: { window.setFloating($0) }))
                    .toggleStyle(.checkbox).font(.system(size: 11)).fixedSize()
                Button("Export logs...") { exportLogs() }.font(.system(size: 11)).fixedSize()
                Button("Compact view") { window.showCompact() }.font(.system(size: 11)).fixedSize()
            }
        }
    }

    private func mapCard(_ s: GuardSnapshot) -> some View {
        Card(title: "Map") {
            HStack {
                Text(s.mapKnown ? (s.map.isEmpty ? "-" : s.map) : "Unknown map")
                    .font(.system(size: 15, weight: .medium))
                Spacer()
                if s.inNexus { Pill(text: "NEXUS: ACTIONS OFF", color: amber) }
                else if !s.settled && s.status == 0 { Pill(text: "SETTLING", color: amber) }
                else if s.status == 0 { Pill(text: "ACTIONS ON", color: mint) }
                else { Pill(text: statusText(s.status), color: .gray) }
            }
        }
    }

    private func hpCard(_ s: GuardSnapshot) -> some View {
        let percent = s.percent ?? 0
        let color = percent <= Double(s.nexus) ? coral : percent <= Double(s.potion) ? amber : mint
        return Card(title: "Health") {
            HStack(alignment: .firstTextBaseline) {
                Text(s.percent == nil ? "-" : "\(s.hp)").font(.system(size: 34, weight: .semibold, design: .rounded))
                Text("/ \(s.maxHP)").font(.system(size: 16)).foregroundStyle(.secondary)
                Spacer()
                Text(s.percent.map { String(format: "%.0f%%", $0) } ?? "").font(.system(size: 22, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
            }
            HPBar(fraction: percent / 100, nexus: s.nexus, potion: s.potion, ceiling: s.ceiling, color: color)
            HStack(spacing: 14) {
                legend("Nexus \(s.nexus)%", coral)
                legend("Potion \(s.potion)%", amber)
                if s.ceiling > 0 { legend("Ceiling \(s.ceiling)%", mint) }
                Spacer()
                if s.drinking { Text("Drinking until over \(s.stopPercent)%").font(.system(size: 11, weight: .semibold)).foregroundStyle(amber) }
            }
        }
    }

    private func startCard(_ link: Link) -> some View {
        Card(title: "Start") {
            switch launch.state {
            case .checking:
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the game files...").font(.system(size: 13)) }
            case .launched(let when) where Date().timeIntervalSince(when) < 120:
                Text("DECA's launcher is opening with the guard. Click Play; this window goes live when the game loads.")
                    .font(.system(size: 13)).foregroundStyle(.secondary)
            default:
                if case .offline("Game closed") = link {
                    Text("The game closed. Start it again here.").font(.system(size: 13)).foregroundStyle(.secondary)
                } else {
                    Text("Start the game with the guard. Uses the saved settings below.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                if case .failed(let message) = launch.state {
                    Text(message).font(.system(size: 12, weight: .semibold)).foregroundStyle(coral)
                }
                Button(settings.saved.armed ? "Start game (armed)" : "Start game (dry run)") { launch.start() }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
    }

    private func summaryCard(_ s: GuardSnapshot, title: String = "This session") -> some View {
        let summary = s.summary
        let dry = !s.armed && summary.potionsSent == 0 && summary.nexusSent == 0
        return Card(title: title) {
            HStack(spacing: 18) {
                metric("Length", summary.start > 0 ? Format.duration((title == "This session" ? Date().timeIntervalSince1970 : s.sampleEpoch) - summary.start) : "-")
                metric(dry ? "Potions (would)" : "Potions used", "\(dry ? summary.potionsDry : summary.potionsSent)")
                metric(dry ? "Nexus (would)" : "Nexus", "\(dry ? summary.nexusDry : summary.nexusSent)")
                metric("Closest call", summary.closestText)
                Spacer()
            }
            HStack {
                if summary.closestPercent != nil {
                    Text("Lowest HP outside the Nexus at \(Format.time(summary.lowestEpoch))")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Show log") { showLog(summary.logName) }.font(.system(size: 11)).disabled(summary.logName.isEmpty)
            }
        }
    }
    /// Saves every session log plus the settings as one zip, then shows it in Finder.
    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LogExport.defaultName()
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try LogExport.export(data: dataURL, to: url)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            let alert = NSAlert(); alert.messageText = "Could not export the logs"
            alert.informativeText = error.localizedDescription; alert.runModal()
        }
    }
    private func showLog(_ name: String) {
        let log = liveURL.deletingLastPathComponent().appendingPathComponent(name)
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    private func settingsCard(_ s: GuardSnapshot?) -> some View {
        let running = s?.settings
        let changed = running != nil && settings.draft != running
        return Card(title: "Settings") {
            HStack {
                Toggle(isOn: Binding(get: { settings.draft.armed }, set: { value in
                    var next = running ?? settings.draft; next.armed = value
                    settings.apply(next, source: source)
                })) {
                    Text(settings.draft.armed ? "Armed: drinks and Nexuses for you" : "Dry run: only shows what it would do")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                Spacer()
            }
            thresholdRow("Potion trigger", value: $settings.draft.potion, tint: amber,
                         help: "Start drinking at or below this HP.")
            thresholdRow("Ceiling", value: $settings.draft.ceiling, tint: mint,
                         help: "Keep drinking until HP is over this. Off: stop once above the trigger.")
            thresholdRow("Nexus", value: $settings.draft.nexus, tint: coral,
                         help: "Return to the Nexus at or below this HP.")
            if let problem = settings.draft.problem {
                Text(problem).font(.system(size: 11, weight: .semibold)).foregroundStyle(coral)
            } else if let error = settings.error {
                Text(error).font(.system(size: 11, weight: .semibold)).foregroundStyle(coral)
            }
            HStack(spacing: 10) {
                Button("Apply") { settings.apply(settings.draft, source: source) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.draft.problem != nil || (running != nil && !changed))
                Button("Revert") { settings.draft = running ?? settings.saved }
                    .disabled(running != nil && !changed)
                Spacer()
                Text(running == nil && settings.state(source) == .idle
                     ? "Game not running. Apply saves for the next launch."
                     : applyText(settings.state(source), changed: changed))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }
    private func thresholdRow(_ title: String, value: Binding<Int>, tint: Color, help: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text(value.wrappedValue == 0 ? "Off" : "\(value.wrappedValue)%")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(tint)
            }
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: 0...100, step: 1)
                .tint(tint)
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
    private func applyText(_ state: ApplyState, changed: Bool) -> String {
        switch state {
        case .waiting: return "Sending to the guard..."
        case .applied: return changed ? "Edited, not applied" : "Applied to the running guard"
        case .rejected: return "The guard refused these settings"
        case .savedForNextLaunch: return "Saved. Used next time you start the game."
        case .idle: return changed ? "Edited, not applied" : "Matches the running guard"
        }
    }

    private func partyCard(_ s: GuardSnapshot?) -> some View {
        Card(title: "Party calls") {
            HStack {
                Toggle(isOn: $alerts.settings.enabled) {
                    Text("Alert me when someone calls j in party chat").font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                Spacer()
            }
            HStack(spacing: 14) {
                Toggle("Play a sound", isOn: $alerts.settings.sound).toggleStyle(.checkbox).font(.system(size: 11))
                    .disabled(!alerts.settings.enabled)
                Spacer()
                Button("Test alert") {
                    alerts.requestPermission()
                    alerts.alert(PartyCall(caller: "Test", text: "j cit", epoch: Date().timeIntervalSince1970, count: 0))
                }
                .font(.system(size: 11)).disabled(!alerts.settings.enabled)
            }
            Text("Counts \"j\", \"jjjj\", \"j cit\" and \"join\" as the first word, from other players in party chat only. A burst alerts once every 5 s.")
                .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let s {
                HStack(spacing: 8) {
                    switch s.chatStatus {
                    case Int32(CHAT_READING): Pill(text: "READING PARTY CHAT", color: mint)
                    case Int32(CHAT_UNAVAILABLE): Pill(text: "CHAT NOT SUPPORTED IN THIS BUILD", color: coral)
                    default: Pill(text: "LOOKING FOR CHAT", color: .gray)
                    }
                    Spacer()
                    Text("\(s.partyCalls) this session").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                if let call = s.lastCall {
                    HStack(spacing: 8) {
                        Text(Format.time(call.epoch)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        Text(call.caller).font(.system(size: 12, weight: .semibold)).foregroundStyle(amber)
                        Text(call.text).font(.system(size: 12)).lineLimit(1)
                        Spacer()
                    }
                }
            }
        }
    }

    private func potionCard(_ s: GuardSnapshot) -> some View {
        Card(title: "Quickslots (used in order)") {
            if s.stacks.isEmpty {
                Text("No quickslots read yet").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 10) {
                    ForEach(Array(s.stacks.enumerated()), id: \.offset) { index, count in
                        let next = index == s.nextSlot
                        VStack(spacing: 4) {
                            Text("\(count)").font(.system(size: 22, weight: .semibold, design: .rounded))
                                .foregroundStyle(count == 0 ? .secondary : .primary)
                            Text("Slot \(index + 1)").font(.system(size: 10)).foregroundStyle(.secondary)
                            Text(s.cooling[index] ? "cooldown" : next ? "next" : " ")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(s.cooling[index] ? amber : mint)
                        }
                        .frame(maxWidth: .infinity).padding(.vertical, 8)
                        .background(next ? mint.opacity(0.10) : Color.white.opacity(0.03))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                }
                if s.totalPotions == 0 { Text("Out of potions: only the Nexus threshold applies").font(.system(size: 11)).foregroundStyle(amber) }
            }
        }
    }

    private func eventsCard(_ s: GuardSnapshot) -> some View {
        Card(title: "Actions (newest first)") {
            if s.events.isEmpty {
                Text("None yet").font(.system(size: 12)).foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(s.events.reversed().enumerated()), id: \.offset) { _, e in
                        HStack(spacing: 8) {
                            Text(Format.time(e.epoch)).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            Text(e.title).font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(e.action == .nexus ? coral : amber).frame(width: 48, alignment: .leading)
                            Text("\(e.hp)/\(e.maxHP)").font(.system(size: 11, design: .monospaced))
                            if e.action == .potion && e.slot >= 0 { Text("slot \(e.slot + 1)").font(.system(size: 11)).foregroundStyle(.secondary) }
                            Spacer()
                            Text(e.outcome).font(.system(size: 11)).foregroundStyle(e.succeeded ? mint : e.result == 0 ? .secondary : coral)
                        }
                    }
                }
            }
        }
    }

    private func latencyCard(_ s: GuardSnapshot, _ link: Link, _ rate: Double?) -> some View {
        Card(title: "Latency") {
            HStack(spacing: 18) {
                metric("Checks/s", rate.map { String(format: "%.0f", $0) } ?? "-")
                metric("Last gap", Format.ms(s.lastGapUs))
                metric("Worst gap (1 s)", Format.ms(s.maxGapUs))
                metric("Check work", String(format: "%.1f µs", Double(s.workNs) / 1000))
                metric("Data age", ageText(link))
            }
        }
    }

    private func ageText(_ link: Link) -> String {
        switch link {
        case .live(let age), .stale(let age): return Format.age(age)
        case .offline: return "-"
        }
    }
    private func statusText(_ status: Int32) -> String {
        switch status {
        case 1: return "STARTING"
        case 2: return "WAITING FOR HUD"
        case 3: return "WAITING FOR PLAYER"
        default: return "NO DATA"
        }
    }
    private func legend(_ text: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Rectangle().fill(color).frame(width: 8, height: 8); Text(text).font(.system(size: 10)).foregroundStyle(.secondary) }
    }
    private func metric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            Text(value).font(.system(size: 13, weight: .medium, design: .monospaced))
        }
    }
}

/// Small always-on-top strip: HP, potions and guard state. Never takes focus from the game.
struct CompactView: View {
    let source: LiveSource
    @ObservedObject var alerts: PartyAlerts
    var expand: () -> Void

    var body: some View {
        TimelineView(.animation) { context in
            let _ = source.refresh()
            CompactContent(snapshot: source.snapshot, link: source.link, expand: expand,
                           flash: alerts.flashing(at: context.date) ? context.date.timeIntervalSinceReferenceDate : nil)
        }
    }
}

struct CompactContent: View {
    var snapshot: GuardSnapshot?
    var link: Link
    var expand: () -> Void
    /// While a party call is fresh: the current time, which drives the pulse. nil otherwise.
    var flash: Double? = nil

    var body: some View {
        HStack(spacing: 10) {
            Circle().fill(link.isLive ? mint : link == .offline("Waiting for the guard") ? Color.gray : coral).frame(width: 8, height: 8)
            if let s = snapshot, link.isLive || { if case .stale = link { return true } else { return false } }() {
                let percent = s.percent ?? 0
                let color = percent <= Double(s.nexus) ? coral : percent <= Double(s.potion) ? amber : mint
                Text(s.armed ? "ARMED" : "DRY").font(.system(size: 10, weight: .bold)).foregroundStyle(s.armed ? mint : .gray)
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        if flash != nil, let call = s.lastCall {
                            Text("J  \(call.caller)").font(.system(size: 12, weight: .bold, design: .rounded))
                                .foregroundStyle(amber).lineLimit(1)
                        } else {
                            Text(s.percent == nil ? "-" : "\(s.hp)/\(s.maxHP)").font(.system(size: 12, weight: .semibold, design: .rounded))
                        }
                        Spacer()
                        Text(s.inNexus ? "NEXUS" : s.percent.map { String(format: "%.0f%%", $0) } ?? "")
                            .font(.system(size: 12, weight: .bold, design: .rounded)).foregroundStyle(s.inNexus ? amber : color)
                    }
                    HPBar(fraction: percent / 100, nexus: s.nexus, potion: s.potion, ceiling: s.ceiling, color: color)
                        .frame(height: 8)
                }
                VStack(spacing: 0) {
                    Text("\(s.totalPotions)").font(.system(size: 14, weight: .semibold, design: .rounded))
                    Text(s.nextSlot >= 0 ? "slot \(s.nextSlot + 1)" : "none").font(.system(size: 9)).foregroundStyle(.secondary)
                }
            } else {
                Text(link == .offline("Game closed") ? "Game closed" : "Waiting for the guard")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Back to the full window")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(width: 340, height: 52)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.92))
        .overlay {
            if let flash {
                RoundedRectangle(cornerRadius: 10).strokeBorder(amber, lineWidth: 3)
                    .opacity(0.55 + 0.45 * sin(flash * 2 * .pi * 1.5))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}

#if GUARD_UI_TEST
/// Test mode: render the live file's current state to a PNG and exit (no screen recording needed).
@MainActor func renderSnapshot(to path: String) {
    let source = LiveSource(); source.refresh()
    let settings = SettingsController(); settings.sync(with: source.snapshot, live: source.link.isLive)
    // GUARD_RENDER_DRAFT="armed,potion,ceiling,nexus" shows an edited (possibly invalid) draft.
    if let edit = ProcessInfo.processInfo.environment["GUARD_RENDER_DRAFT"] {
        let v = edit.split(separator: ",").compactMap { Int($0) }
        if v.count == 4 { settings.draft = GuardSettings(armed: v[0] == 1, potion: v[1], ceiling: v[2], nexus: v[3]) }
    }
    if ProcessInfo.processInfo.environment["GUARD_RENDER_COMPACT"] != nil {
        let compact = CompactContent(snapshot: source.snapshot, link: source.link, expand: {},
                                     flash: ProcessInfo.processInfo.environment["GUARD_RENDER_FLASH"] != nil ? 0.1 : nil)
        let renderer = ImageRenderer(content: compact); renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
        try! png.write(to: URL(fileURLWithPath: path)); exit(0)
    }
    let launch = LaunchController()
    if ProcessInfo.processInfo.environment["GUARD_RENDER_LAUNCH"] != nil {
        launch.start()
        let deadline = Date().addingTimeInterval(20)
        while launch.state == .checking && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    }
    let view = GuardPanel(window: WindowState(), settings: settings, launch: launch, alerts: PartyAlerts(), source: source).content(source.snapshot, source.link, source.rate)
        .padding(16).frame(width: 460, alignment: .top)
        .background(Color(red: 0.07, green: 0.08, blue: 0.10))
        .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: view); renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
          let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { exit(1) }
    try! png.write(to: URL(fileURLWithPath: path)); exit(0)
}
#endif

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var compact: NSPanel!
    let source = LiveSource()
    let state = WindowState()
    let settings = SettingsController()
    let launch = LaunchController()
    let alerts = PartyAlerts()
    private var alertTimer: Timer?
    private var activity: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Party calls are checked 10 times a second whatever the windows are doing. Without the
        // activity, App Nap slows timers while the game is in front.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching party chat")
        alertTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.source.refresh(); self.alerts.check(self.source)
        }
        #if !GUARD_UI_TEST
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            if alerts.settings.enabled { alerts.requestPermission() }
        }
        #endif
        try? FileManager.default.createDirectory(at: GuardPaths.logs(data: dataURL), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit Exalt Client Mac", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 1000), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Exalt Client Mac"
        window.delegate = self
        window.contentView = NSHostingView(rootView: GuardView(source: source, window: state, settings: settings, launch: launch, alerts: alerts))
        window.center(); window.setFrameAutosaveName("ExaltClientMacMain"); state.window = window
        // Compact strip: floats over the game (also in full screen) and never takes focus.
        compact = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 52),
                          styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        compact.level = .floating
        compact.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        compact.isMovableByWindowBackground = true
        compact.backgroundColor = .clear; compact.isOpaque = false; compact.hasShadow = true
        compact.hidesOnDeactivate = false
        compact.contentView = NSHostingView(rootView: CompactView(source: source, alerts: alerts) { [weak self] in self?.showFull() })
        compact.setFrameAutosaveName("ExaltClientMacCompact")
        if compact.frame.origin == .zero, let screen = NSScreen.main {
            compact.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 360, y: screen.visibleFrame.maxY - 20))
        }
        state.showCompact = { [weak self] in self?.showCompact() }
        #if GUARD_UI_TEST
        // Test hook: drive compact and full screen automatically and report what is visible.
        let env = ProcessInfo.processInfo.environment
        if env["GUARD_AUTO_COMPACT"] != nil {
            var steps: [(Double, String, () -> Void)] = [
                (1.5, "compact", { [weak self] in self?.showCompact() }),
                (3.0, "full", { [weak self] in self?.showFull() }),
                (4.5, "compact again", { [weak self] in self?.showCompact() }),
                (6.0, "full again", { [weak self] in self?.showFull() }),
            ]
            if env["GUARD_AUTO_FULLSCREEN"] != nil {
                steps = [(1.0, "enter full screen", { [weak self] in self?.window.toggleFullScreen(nil) }),
                         (3.5, "compact from full screen", { [weak self] in self?.showCompact() }),
                         (6.5, "full", { [weak self] in self?.showFull() })]
            }
            for (delay, name, action) in steps {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    action()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                        guard let self else { return }
                        print("step=\(name) main=\(self.window.isVisible) compact=\(self.compact.isVisible) fullscreen=\(self.window.styleMask.contains(.fullScreen))")
                        fflush(stdout)
                    }
                }
            }
        }
        #endif
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private var compactMode = false
    private var compactAfterFullScreen = false
    /// Show the strip before hiding the main window: hiding the last regular window counts as
    /// "last window closed", which would otherwise quit the app. A full-screen window has to
    /// leave full screen first, or hiding it leaves an empty full-screen space behind.
    func showCompact() {
        if window.styleMask.contains(.fullScreen) {
            compactAfterFullScreen = true
            window.toggleFullScreen(nil)
            return
        }
        compactMode = true; compact.orderFrontRegardless(); window.orderOut(nil)
    }
    func windowDidExitFullScreen(_ notification: Notification) {
        guard compactAfterFullScreen else { return }
        compactAfterFullScreen = false
        showCompact()
    }
    func showFull() { compactMode = false; window.makeKeyAndOrderFront(nil); compact.orderOut(nil); NSApp.activate(ignoringOtherApps: true) }
    /// Quit when the main window is closed, but never while the compact strip is showing.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { !compactMode }
    /// Show party call banners even while this app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    /// Clicking the Dock icon while compact brings the full window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showFull(); return true }
}

@main struct Main {
    static func main() {
        #if GUARD_UI_TEST
        if let path = ProcessInfo.processInfo.environment["GUARD_RENDER_PNG"] { MainActor.assumeIsolated { renderSnapshot(to: path) } }
        #endif
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
}
