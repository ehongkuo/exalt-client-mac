import AppKit
import Combine
import UniformTypeIdentifiers
import SwiftUI
import UserNotifications

// System colors, used only for state: fine, needs attention, wrong.
private let ok = Color.green, warn = Color.orange, bad = Color.red
private let panelBackground = Color(white: 0.15)

/// "Exalt Client Mac Staging" for ./build.sh --stage: its own data folder and defaults, marked in the UI.
private let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String ?? GuardPaths.prodName
private let isStaging = appName != GuardPaths.prodName

#if GUARD_UI_TEST
private let liveURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_LIVE_FILE"] ?? "/dev/null")
private let settingsURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_SETTINGS_FILE"] ?? "/dev/null")
private let dataURL = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_DATA_DIR"] ?? "/nonexistent")
#else
private let dataURL: URL = {
    let home = FileManager.default.homeDirectoryForCurrentUser, prod = GuardPaths.dataFolder(home: home)
    guard isStaging else { return prod }
    let staging = GuardPaths.dataFolder(home: home, name: appName)
    // Drop and party alert settings live in the defaults: copy them along with the guard's.
    if SettingsFile.seed(staging: staging, from: prod), let defaults = UserDefaults.standard.persistentDomain(forName: "local.exalt.clientmac") {
        for (key, value) in defaults { UserDefaults.standard.set(value, forKey: key) }
    }
    return staging
}()
private let liveURL = GuardPaths.liveFile(data: dataURL)
private let settingsURL = GuardPaths.settingsFile(data: dataURL)
#endif

/// Shares feed reads between the windows and the alert timer. Publishes only when something the
/// windows show changes: redrawing the whole panel on every guard tick cost about a third of a core.
final class LiveSource: ObservableObject {
    let feed = LiveFeed(url: liveURL)
    private var meter = RateMeter()
    private var shown: Shown?
    private(set) var snapshot: GuardSnapshot?
    private(set) var link: Link = .offline("Waiting for the guard")
    private(set) var rate: Double?

    /// `detailed`: the diagnostics are open, so timing fields and the data age are on screen too.
    func refresh(detailed: Bool = false) {
        if let fresh = feed.read() {
            snapshot = fresh
            rate = meter.add(ns: fresh.sampleNs, ticks: fresh.ticks)
        }
        let alive = snapshot.map { guard_process_alive($0.pid) != 0 } ?? false
        link = Link.evaluate(snapshot, nowNs: Clock.monotonicNs(), processAlive: alive)
        let next = Shown(snapshot, link, rate, detailed: detailed)
        if next != shown { shown = next; objectWillChange.send() }
    }

    /// The part of the feed the windows draw. Session and party times count in whole seconds.
    private struct Shown: Equatable {
        var snapshot: GuardSnapshot?, link: String, rate: Int?, second: Int
        init(_ s: GuardSnapshot?, _ link: Link, _ rate: Double?, detailed: Bool) {
            snapshot = s; second = Int(Date().timeIntervalSince1970)
            switch link {
            case .live(let age): self.link = detailed ? Format.age(age) : "live"
            case .stale(let age): self.link = "stale " + Format.age(age)
            case .offline(let why): self.link = why
            }
            self.rate = detailed ? rate.map { Int($0) } : nil
            if !detailed {  // change every tick but are only shown in the diagnostics
                snapshot?.sampleNs = 0; snapshot?.sampleEpoch = 0; snapshot?.ticks = 0
                snapshot?.lastGapUs = 0; snapshot?.maxGapUs = 0; snapshot?.workNs = 0
            }
            snapshot?.events = []; snapshot?.eventCount = 0
        }
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

/// Checks the install and the game build, then starts DECA's launcher with the guard.
final class LaunchController: ObservableObject {
    enum State: Equatable { case idle, checking, launched(Date), failed(String) }
    @Published private(set) var state: State = .idle
    /// Open RealmHound (a separate, passive traffic viewer) beside the game; remembered.
    @Published var openRealmHound = UserDefaults.standard.object(forKey: "openRealmHound") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openRealmHound, forKey: "openRealmHound") }
    }
    var realmHound: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.github.pillarzz.realmhound") }

    private func openRealmHoundIfChosen() {
        #if !GUARD_UI_TEST
        guard openRealmHound, let url = realmHound else { return }
        // Behind the launcher, so Play stays in front; a running copy is left as it is.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        #endif
    }

    func start() {
        guard state != .checking else { return }
        state = .checking
        #if GUARD_UI_TEST
        let bundle = URL(fileURLWithPath: ProcessInfo.processInfo.environment["GUARD_APP_BUNDLE"] ?? "/nonexistent/Exalt Client Mac.app")
        #else
        let bundle = Bundle.main.bundleURL
        #endif
        let settings = SettingsFile.load(settingsURL) ?? .standard
        #if GUARD_SYNC_CAPTURE
        let observationOnly = true
        #else
        let observationOnly = false
        #endif
        let running = NSWorkspace.shared.runningApplications.compactMap { $0.executableURL?.lastPathComponent }
        DispatchQueue.global(qos: .userInitiated).async {
            let install = GameInstall.standard(home: FileManager.default.homeDirectoryForCurrentUser)
            let dylib = GuardPaths.dylib(forApp: bundle)
            let expected = (try? String(contentsOf: GuardPaths.buildHashFile(forApp: bundle), encoding: .utf8)).flatMap(FileHash.expected)
            let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
            func plan(_ actual: String?) -> Result<LaunchPlan, LaunchProblem> {
                LaunchPlan.make(install: install, dylib: dylib, data: dataURL, settings: settings, expectedHash: expected,
                                actualHash: actual, running: running, observationOnly: observationOnly, exists: exists)
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
            DispatchQueue.main.async {
                self.state = next
                if case .launched = next { self.openRealmHoundIfChosen() }
            }
        }
    }
}

/// Party call alerts: a sound, the Join popup and an outline on the compact strip. Checked
/// on a timer rather than by the views, which stop redrawing while hidden or behind a
/// full-screen game. Preferences are kept in the app's defaults.
final class PartyAlerts: ObservableObject {
    @Published var settings: PartyAlertSettings { didSet { save() } }
    /// The call shown in the Join popup (and named on the compact strip), if any.
    @Published private(set) var popup: PartyCall?
    @Published private(set) var joinStatus: JoinStatus = .idle
    private var popupShownAt = 0.0, statusSince = 0.0
    private var popupIsTest = false
    private var joinSent: UInt32?
    private var lastJoinRequest: UInt32 = 0
    private var tracker = PartyAlertTracker()
    private var refusals = RefusalTracker()
    private var watch = UnguardedGameWatch()
    private var lastWatch = -Double.infinity
    /// Game processes running without the guard; the window shows a warning while any are.
    @Published private(set) var unguarded: [Int32] = []
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
    }
    func requestPermission() {
        guard canNotify else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert]) { _, _ in }
    }
    private var now: Double { Double(Clock.monotonicNs()) / 1e9 }
    func check(_ source: LiveSource) {
        // A refused game always alerts, whatever the party alert settings say.
        if let refusal = refusals.update(source.snapshot, now: Date().timeIntervalSince1970) { alert(refusal) }
        if now - lastWatch >= 1 {
            lastWatch = now
            let games = NSWorkspace.shared.runningApplications
                .filter { $0.executableURL?.lastPathComponent == "RotMGExalt" }.map(\.processIdentifier)
            let result = watch.update(games: games, snapshot: source.snapshot, now: now)
            if result.unguarded != unguarded { unguarded = result.unguarded }
            if result.new { alertUnguarded() }
        }
        updatePopup(source)
        // The tracker sees every snapshot even with alerts off, so turning them on never replays old calls.
        guard let call = tracker.update(source.snapshot, live: source.link.isLive, now: now),
              settings.enabled else { return }
        alert(call)
    }
    private func updatePopup(_ source: LiveSource) {
        let status = JoinStatus.evaluate(sent: joinSent, snapshot: source.snapshot, live: source.link.isLive)
        if status != joinStatus { joinStatus = status; statusSince = now }
        guard popup != nil, JoinPopupRules.shouldClose(shownAt: popupShownAt, now: now, snapshot: source.snapshot,
                                                       live: source.link.isLive, status: joinStatus, statusSince: statusSince,
                                                       test: popupIsTest)
        else { return }
        dismiss()
    }
    func dismiss() { popup = nil; joinSent = nil; joinStatus = .idle }
    /// Joins the caller's dungeon the way the game's ctrl-click menu does, then switches to the game.
    func join(_ call: PartyCall, source: LiveSource) {
        guard let s = source.snapshot, source.link.isLive else { joinStatus = .failed("Game not running"); return }
        lastJoinRequest = max(lastJoinRequest, s.joinRequest) + 1
        if source.feed.sendJoin(call.caller, request: lastJoinRequest) {
            joinSent = lastJoinRequest; joinStatus = .sending; statusSince = now
        } else {
            joinStatus = .failed("Could not reach the guard")
        }
        GameFocus.bringForward(pid: s.pid)
    }
    func alert(_ call: PartyCall, test: Bool = false) {
        popupIsTest = test
        // No banner: the popup already shows over everything, including full-screen video.
        popup = call; popupShownAt = now; joinSent = nil; joinStatus = .idle
        #if !GUARD_UI_TEST
        if settings.sound { NSSound(named: "Glass")?.play() }
        #endif
    }
    func alert(_ refusal: GuardRefusal) {
        #if !GUARD_UI_TEST
        NSSound(named: "Basso")?.play()
        #endif
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "Game closed: guard checks failed"
        content.body = refusal.reason
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "guard-refusal", content: content, trigger: nil))
    }
    func alertUnguarded() {
        #if !GUARD_UI_TEST
        NSSound(named: "Basso")?.play()
        #endif
        guard canNotify else { return }
        let content = UNMutableNotificationContent()
        content.title = "The game is running without the guard"
        content.body = "No potions or Nexus will be used for you. Quit the game and start it from Exalt Client Mac."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "guard-missing", content: content, trigger: nil))
    }
}

/// Drop alerts: a sound and a popup with no buttons when RealmHound logs a chosen bag or a shiny.
/// Checked once a second; the popup goes after `DropRules.shown` seconds or when clicked.
final class DropAlerts: ObservableObject {
    @Published var settings: DropAlertSettings { didSet { save(); loadShiniesIfNeeded(); loadBagsIfNeeded() } }
    @Published private(set) var popup: DropAlert?
    @Published private(set) var logs = 0
    @Published private(set) var shinies: Set<Int> = []
    @Published private(set) var bagSprites: [DropBag: CGImage] = [:]
    private var shownAt = 0.0, lastPoll = -Double.infinity, loadingShinies = false, loadingBags = false
    private let log = LootLog(accounts: RealmHoundPaths.accounts)
    private let defaults = UserDefaults.standard

    init() {
        var s = DropAlertSettings()
        if let v = defaults.object(forKey: "dropAlerts") as? Bool { s.enabled = v }
        if let v = defaults.object(forKey: "dropAlertSound") as? Bool { s.sound = v }
        if let v = defaults.stringArray(forKey: "dropAlertBags") { s.bags = Set(v.compactMap(DropBag.init(rawValue:))) }
        if let v = defaults.object(forKey: "dropAlertRarity") as? Int, let r = DropRarity(rawValue: v) { s.minRarity = r }
        if let v = defaults.object(forKey: "dropAlertShiny") as? Bool { s.shiny = v }
        settings = s
        loadShiniesIfNeeded()
        loadBagsIfNeeded()
    }
    private func save() {
        defaults.set(settings.enabled, forKey: "dropAlerts")
        defaults.set(settings.sound, forKey: "dropAlertSound")
        defaults.set(settings.bags.map(\.rawValue).sorted(), forKey: "dropAlertBags")
        defaults.set(settings.minRarity.rawValue, forKey: "dropAlertRarity")
        defaults.set(settings.shiny, forKey: "dropAlertShiny")
    }
    /// The shiny list comes from about 60 MB of XML, so it is read once, off the main thread.
    private func loadShiniesIfNeeded() {
        #if !GUARD_UI_TEST
        guard settings.enabled, settings.shiny, shinies.isEmpty, !loadingShinies else { return }
        loadingShinies = true
        DispatchQueue.global(qos: .utility).async {
            let ids = ShinyIndex.load(folder: RealmHoundPaths.xml)
            DispatchQueue.main.async { self.shinies = ids; self.loadingShinies = false }
        }
        #endif
    }
    /// Bag sprites are cut from a large atlas, so they are read once, off the main thread.
    private func loadBagsIfNeeded() {
        #if !GUARD_UI_TEST
        guard settings.enabled, bagSprites.isEmpty, !loadingBags else { return }
        loadingBags = true
        DispatchQueue.global(qos: .utility).async {
            let sprites = BagSprites.load(assets: RealmHoundPaths.assets)
            DispatchQueue.main.async { self.bagSprites = sprites; self.loadingBags = false }
        }
        #endif
    }
    private var now: Double { Double(Clock.monotonicNs()) / 1e9 }
    func check() {
        if popup != nil, now - shownAt >= DropRules.shown { popup = nil }
        guard now - lastPoll >= 1 else { return }
        lastPoll = now
        #if !GUARD_UI_TEST
        // The log is polled with alerts off too, so turning them on never replays old drops.
        let drops = log.poll()
        if log.logs != logs { logs = log.logs }
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        if let alert = drops.compactMap({ DropRules.alert(for: $0, settings: settings, shiny: shinies, nowMs: nowMs) }).last {
            show(alert)
        }
        #endif
    }
    func show(_ alert: DropAlert) {
        popup = alert; shownAt = now
        #if !GUARD_UI_TEST
        if settings.sound { NSSound(named: "Hero")?.play() }
        #endif
    }
    func dismiss() { popup = nil }
}

/// The drop popup: like the Join popup, but nothing to press; a click dismisses it.
struct DropPopupView: View {
    @ObservedObject var drops: DropAlerts

    var body: some View {
        if let drop = drops.popup {
            DropPopupContent(drop: drop, bagSprite: drop.bag.flatMap { drops.bagSprites[$0] }).onTapGesture { drops.dismiss() }
        }
    }
}

struct DropPopupContent: View {
    var drop: DropAlert
    /// The bag's game sprite; the SF Symbol stands in when RealmHound's assets are missing.
    var bagSprite: CGImage? = nil

    var body: some View {
        HStack(spacing: 12) {
            ZStack(alignment: .topLeading) {
                BagIcon(bag: drop.bag, sprite: bagSprite, size: 32).frame(width: 40, height: 40)
                if drop.shiny {
                    Image(systemName: "sparkles").font(.system(size: 11, weight: .bold))
                        .foregroundStyle(shinyPink, shinyGold).padding(2)
                }
            }
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(drop.shiny ? "\(drop.item) (Shiny)" : drop.item).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                    if drop.rarity != .common { RarityGems(rarity: drop.rarity) }
                }
                Text(drop.detail).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .frame(width: 380, height: 64)
        .background(panelBackground.opacity(0.97))
        .overlay {
            if drop.shiny {
                RoundedRectangle(cornerRadius: 14).strokeBorder(
                    AngularGradient(colors: [shinyPink, shinyGold, .white, shinyPink, shinyGold, .white, shinyPink], center: .center),
                    lineWidth: 2)
            } else {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }
}

private let shinyPink = Color(red: 1, green: 0.55, blue: 0.9), shinyGold = Color(red: 1, green: 0.85, blue: 0.3)

/// The game's rarity mark: one gem per enchantment slot, in the rarity's colour (green, blue,
/// purple, gold), clustered as on an item's slot.
struct RarityGems: View {
    var rarity: DropRarity
    private let gem: CGFloat = 10

    var body: some View {
        let color = [Color.clear, Color(red: 0.3, green: 0.82, blue: 0.3), Color(red: 0.2, green: 0.62, blue: 1),
                     Color(red: 0.76, green: 0.55, blue: 1), Color(red: 1, green: 0.8, blue: 0.15)][rarity.rawValue]
        // Gem centres in gem widths: a pair, a triangle, then a diamond of four.
        let spots: [(CGFloat, CGFloat)] = [[], [(0, 0)], [(0, 0), (1, 0)], [(0, 0), (1, 0), (0.5, 0.5)],
                                           [(0.5, 0), (0, 0.5), (1, 0.5), (0.5, 1)]][rarity.rawValue]
        ZStack(alignment: .topLeading) {
            ForEach(spots.indices, id: \.self) { i in
                ZStack {
                    Diamond().fill(color)
                    Diamond().fill(.white.opacity(0.55)).frame(width: gem * 0.4, height: gem * 0.4).offset(x: -gem * 0.12, y: -gem * 0.12)
                    Diamond().stroke(.black, lineWidth: 1)
                }
                .frame(width: gem, height: gem).offset(x: spots[i].0 * gem, y: spots[i].1 * gem)
            }
        }
        .frame(width: gem * (spots.map(\.0).max()! + 1), height: gem * (spots.map(\.1).max()! + 1), alignment: .topLeading)
        .accessibilityLabel(rarity.name)
    }
}

private struct Diamond: Shape {
    func path(in r: CGRect) -> Path {
        Path { p in p.move(to: CGPoint(x: r.midX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.midY))
            p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.midY)); p.closeSubpath() }
    }
}

/// A bag's game sprite, or a bag symbol in its colour when RealmHound's assets are missing.
struct BagIcon: View {
    var bag: DropBag?
    var sprite: CGImage?
    var size: CGFloat

    var body: some View {
        if let sprite {
            Image(decorative: sprite, scale: 1).interpolation(.none).resizable().frame(width: size, height: size)
        } else {
            Image(systemName: "bag.fill").font(.system(size: size * 0.53)).foregroundStyle(bag.map(bagColor) ?? .white)
                .frame(width: size, height: size)
        }
    }
}

func bagColor(_ bag: DropBag) -> Color {
    switch bag {
    case .brown: return Color(red: 0.6, green: 0.4, blue: 0.2)
    case .pink: return .pink
    case .purple: return .purple
    case .egg: return Color(red: 0.95, green: 0.85, blue: 0.6)
    case .cyan: return .cyan
    case .blue: return .blue
    case .gold: return .yellow
    case .white: return .white
    case .orange: return .orange
    case .red: return .red
    }
}

/// Brings the game to the front, also from a full-screen video in another space.
enum GameFocus {
    static func bringForward(pid: Int32) {
        guard pid > 0, let game = NSRunningApplication(processIdentifier: pid) else { return }
        // Opening the running app through Launch Services activates it reliably even when this
        // app is not in front (a plain activate() request can be declined on recent macOS).
        if let url = game.bundleURL {
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, _ in }
        } else {
            game.activate(options: [.activateAllWindows])
        }
    }
}

/// The Join popup: a small card at the top of the screen, over everything, for the newest call.
/// The only place a call can be joined from.
struct JoinPopupView: View {
    @ObservedObject var alerts: PartyAlerts
    let source: LiveSource

    var body: some View {
        if let call = alerts.popup {
            JoinPopupContent(call: call, status: alerts.joinStatus,
                             join: { alerts.join(call, source: source) }, dismiss: { alerts.dismiss() })
        }
    }
}

struct JoinPopupContent: View {
    var call: PartyCall
    var status: JoinStatus
    var join: () -> Void
    var dismiss: () -> Void

    var body: some View {
        let failed: Bool = { if case .failed = status { return true } else { return false } }()
        HStack(spacing: 12) {
            Image(systemName: "person.2.fill").font(.system(size: 14))
                .frame(width: 34, height: 34).background(Color.white.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            VStack(alignment: .leading, spacing: 2) {
                Text(call.caller).font(.system(size: 15, weight: .semibold)).lineLimit(1)
                Text(status == .idle ? "Party call · \(call.text)" : status.text).font(.system(size: 12))
                    .foregroundStyle(failed ? bad : Color.secondary).lineLimit(1)
            }
            Spacer(minLength: 8)
            // A plain colored label: a prominent button turns gray in this never-key panel.
            Button(action: join) {
                Text(status == .sending ? "Joining…" : "Join").font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white).frame(width: 72, height: 30)
                    .background(Color.accentColor).clipShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).disabled(status == .sending || status == .sent)
            Button(action: dismiss) { Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)) }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Dismiss")
        }
        .padding(.horizontal, 14)
        .frame(width: 380, height: 76)
        .background(panelBackground.opacity(0.97))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, .dark)
    }
}

final class WindowState: ObservableObject {
    /// Keep on top: on unless the user turned it off, remembered between launches.
    @Published var floating = UserDefaults.standard.object(forKey: "keepOnTop") as? Bool ?? true
    var window: NSWindow?
    var showCompact: () -> Void = {}
    /// Which rows of the More section are open.
    @Published var sessionOpen = false
    @Published var partyOpen = false
    @Published var dropsOpen = false
    @Published var diagnosticsOpen = false
    func setFloating(_ value: Bool) {
        floating = value; window?.level = value ? .floating : .normal
        UserDefaults.standard.set(value, forKey: "keepOnTop")
    }
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

/// HP bar with markers at the potion (solid) and ceiling (faint) thresholds.
struct HPBar: View {
    var fraction: Double
    var potion: Int, ceiling: Int
    var color: Color
    var height: CGFloat = 6
    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: height)
                Capsule().fill(color).frame(width: max(0, min(1, fraction)) * w, height: height)
                ForEach([(potion, 1.0), (ceiling, 0.5)], id: \.1) { value, opacity in
                    if value > 0 {
                        Rectangle().fill(Color.white.opacity(opacity)).frame(width: 1.5, height: height + 6)
                            .offset(x: w * Double(value) / 100 - 0.75)
                    }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: height + 6)
    }
}

struct GuardView: View {
    @ObservedObject var source: LiveSource
    @ObservedObject var window: WindowState
    @ObservedObject var settings: SettingsController
    @ObservedObject var launch: LaunchController
    @ObservedObject var alerts: PartyAlerts
    @ObservedObject var drops: DropAlerts

    var body: some View {
        #if !GUARD_SYNC_CAPTURE
        let _ = settings.sync(with: source.snapshot, live: source.link.isLive)
        #endif
        MainLayout {
            GuardPanel(window: window, settings: settings, launch: launch, alerts: alerts, drops: drops, source: source).content(source.snapshot, source.link, source.rate)
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
        .background(Color(white: 0.12))
    }
}

/// A titled group of rows, in the style of System Settings.
struct PanelSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title { Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4) }
            VStack(alignment: .leading, spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
        .padding(.top, 14)
    }
}

/// Dry run | Armed, drawn in SwiftUI. The native segmented Picker re-measures its AppKit
/// control on every 30 Hz redraw, and that cost grew without limit (99% CPU after 15 minutes).
struct ModeSwitch: View {
    @Binding var armed: Bool
    var body: some View {
        HStack(spacing: 2) {
            segment("Dry run", value: false)
            segment("Armed", value: true)
        }
        .padding(2)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }
    private func segment(_ title: String, value: Bool) -> some View {
        let selected = armed == value
        return Button { if !selected { armed = value } } label: {
            Text(title).font(.system(size: 12))
                .foregroundStyle(selected ? Color.primary : Color.secondary)
                .padding(.horizontal, 10).frame(height: 20)
                .background(selected ? Color.white.opacity(0.16) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// One line of a section: label on the left, value or control on the right.
struct PanelRow<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: 8) { content }.frame(minHeight: 32).padding(.horizontal, 12)
    }
}

struct RowDivider: View {
    var body: some View { Divider().padding(.leading, 12) }
}

/// The window's contents for one snapshot.
struct GuardPanel {
    @ObservedObject var window: WindowState
    @ObservedObject var settings: SettingsController
    @ObservedObject var launch: LaunchController
    @ObservedObject var alerts: PartyAlerts
    @ObservedObject var drops: DropAlerts
    let source: LiveSource

    @ViewBuilder func content(_ s: GuardSnapshot?, _ link: Link, _ rate: Double?) -> some View {
        #if GUARD_SYNC_CAPTURE
        VStack(alignment: .leading, spacing: 16) {
            Text("Exalt Client Mac").font(.title2.bold())
            Pill(text: "SYNC OBSERVATION ONLY", color: warn)
            Text("Auto Nexus, damage cancellation, auto potions and party Join are off for this capture.")
                .foregroundStyle(warn)
            Text("Your saved gameplay settings are preserved.").foregroundStyle(.secondary)
            Card(title: "Recorder") {
                if link.isLive, let s {
                    Text(s.deathStatus == 1 ? "Recorder ready" : s.deathStatus == 2 ? "Capture complete" : s.deathStatus < 0 ? "Recorder refused — stop the test" : "Enter Nexus to initialize the recorder")
                        .font(.headline)
                    Text("Map: \(s.map.isEmpty ? "Loading" : s.map) • HP: \(s.hp)/\(s.maxHP)")
                } else {
                    Text("Waiting for a fresh game launch").font(.headline)
                }
                Text("Click Start game, then Play in DECA’s launcher. Enter Nexus and wait for Recorder ready. Play briefly while healthy, receive a few weak hits and healing, then manually Nexus.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            if case .failed(let message) = launch.state {
                Text(message).foregroundStyle(bad)
            }
            if case .launched = launch.state {
                Text("Launcher started. Click Play in its window.").foregroundStyle(.secondary)
            }
            Button("Start game (observation only)") { launch.start() }
                .disabled(link.isLive || launch.state == .checking)
            Spacer(minLength: 0)
        }
        #else
        // Not running: no live snapshot; settings edit what the next Start uses.
        let running: GuardSnapshot? = { if case .offline = link { return nil } else { return s } }()
        VStack(alignment: .leading, spacing: 0) {
            statusBar(s, link)
            if let refusal = s?.refusal {
                alarm("Game closed: guard checks failed", refusal.reason,
                      detail: "The game was not left running without protection. Check: \(refusal.detail)")
            }
            if !alerts.unguarded.isEmpty {
                alarm("Game running without the guard", "No potions or Nexus will be used for you. Quit the game and start it from here.")
            }
            if let running { health(running) } else { startSection(link) }
            protection(running)
            more(s, running, link, rate)
            Spacer(minLength: 0)
        }
        #endif
    }

    // MARK: Status

    private func statusBar(_ s: GuardSnapshot?, _ link: Link) -> some View {
        let (dot, text): (Color, String) = {
            switch link {
            case .live: return (ok, s.map { "Connected · \(place($0))" } ?? "Connected")
            case .stale(let age): return (warn, "Connected, no update for \(Format.age(age))")
            case .offline(let why): return (.gray, why == "Game closed" ? "Game closed" : "Game not running")
            }
        }()
        return HStack(spacing: 8) {
            Circle().fill(dot).frame(width: 7, height: 7)
            Text(text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
            if isStaging { Pill(text: "STAGING", color: .blue) }
            Spacer()
            Button { window.setFloating(!window.floating) } label: { Image(systemName: window.floating ? "pin.fill" : "pin") }
                .buttonStyle(.borderless).help(window.floating ? "Keep on top is on" : "Keep on top is off")
            Button { window.showCompact() } label: { Image(systemName: "arrow.down.right.and.arrow.up.left") }
                .buttonStyle(.borderless).help("Compact view")
        }
        .padding(.horizontal, 4)
    }

    private func place(_ s: GuardSnapshot) -> String {
        let map = s.mapKnown ? (s.map.isEmpty ? "Loading map" : s.map) : "Unknown map"
        if s.inNexus { return "\(map), actions paused" }
        switch s.status {
        case 0: return s.settled ? map : "\(map), settling"
        case 1: return "Starting"
        case 2: return "Waiting for the game's HUD"
        case 3: return "Waiting for the player"
        default: return "No data"
        }
    }

    /// Stays until the cause is gone: a refused game, or one running without the guard.
    private func alarm(_ title: String, _ message: String, detail: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: "exclamationmark.triangle.fill").font(.system(size: 13, weight: .semibold)).foregroundStyle(bad)
            Text(message).font(.system(size: 12))
            if let detail { Text(detail).font(.system(size: 11)).foregroundStyle(.secondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(bad.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(bad.opacity(0.45), lineWidth: 0.5))
        .padding(.top, 12)
    }

    // MARK: Health or Start

    private func health(_ s: GuardSnapshot) -> some View {
        let percent = s.percent ?? 0
        let color = s.deathBlocking ? bad : percent <= Double(s.potion) ? warn : ok
        let (line, urgent) = potionLine(s)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.percent == nil ? "-" : s.hp.formatted()).font(.system(size: 30, weight: .light))
                Text("/ \(s.maxHP.formatted())").font(.system(size: 14)).foregroundStyle(.secondary)
                Spacer()
                Text(s.percent.map { String(format: "%.0f%%", $0) } ?? "").font(.system(size: 16)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            HPBar(fraction: percent / 100, potion: s.potion, ceiling: s.ceiling, color: color)
            Text(line).font(.system(size: 11)).foregroundStyle(urgent ? warn : Color.secondary)
        }
        .padding(.horizontal, 4).padding(.top, 14)
    }

    private func potionLine(_ s: GuardSnapshot) -> (String, Bool) {
        if s.deathBlocking { return ("Escaping to Nexus", true) }
        if s.drinking { return ("Drinking until over \(s.stopPercent)%", true) }
        if s.stacks.isEmpty { return ("Quickslots not read yet", false) }
        if s.totalPotions == 0 { return (s.nexusOnDeath ? "Out of potions. Nexus on death stays on." : "Out of potions", true) }
        return ("\(s.totalPotions) potions" + (s.nextSlot >= 0 ? " · next from slot \(s.nextSlot + 1)" : ""), false)
    }

    private func startSection(_ link: Link) -> some View {
        PanelSection {
            VStack(alignment: .leading, spacing: 8) {
                switch launch.state {
                case .checking:
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Checking the game files…") }
                case .launched(let when) where Date().timeIntervalSince(when) < 120:
                    Text("DECA's launcher is opening with the guard. Click Play; this window goes live when the game loads.")
                        .foregroundStyle(.secondary)
                default:
                    Text(link == .offline("Game closed") ? "Start the game again here." : "Start the game with the guard, using the settings below.")
                        .foregroundStyle(.secondary)
                    if case .failed(let message) = launch.state {
                        Text(message).font(.system(size: 12, weight: .semibold)).foregroundStyle(bad)
                    }
                    HStack {
                        Button("Start game") { launch.start() }.keyboardShortcut("r", modifiers: .command)
                        if launch.realmHound != nil {
                            Toggle("Also open RealmHound", isOn: $launch.openRealmHound).toggleStyle(.checkbox)
                        }
                    }
                }
            }
            .font(.system(size: 12))
            .padding(12)
        }
    }

    // MARK: Protection

    private func protection(_ running: GuardSnapshot?) -> some View {
        let changed = running != nil && settings.draft != running?.settings
        let (dot, status) = nexusStatus(running)
        return VStack(alignment: .leading, spacing: 0) {
            PanelSection(title: "Protection") {
                PanelRow {
                    Text("Mode")
                    Spacer()
                    // Applies at once, unlike the rows below.
                    ModeSwitch(armed: Binding(get: { settings.draft.armed }, set: { value in
                        var next = running?.settings ?? settings.draft; next.armed = value
                        settings.apply(next, source: source)
                    }))
                    .help("Dry run only shows what it would do. Armed drinks and Nexuses for you. Applies immediately.")
                }
                RowDivider()
                PanelRow {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nexus on death")
                        HStack(spacing: 5) {
                            if let dot { Circle().fill(dot).frame(width: 6, height: 6) }
                            Text(status).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                    Spacer()
                    Toggle("Nexus on death", isOn: $settings.draft.nexusOnDeath).toggleStyle(.switch).labelsHidden().controlSize(.small)
                }
                .help("Escapes before lethal projectile, ground, area or locally calculated damage. May escape early when timing is uncertain. Meter limits alone never trigger it.")
                RowDivider()
                sliderRow("Drink potions at", $settings.draft.potion, help: "Start drinking at or below this HP. Off: no automatic potions.")
                RowDivider()
                sliderRow("Keep drinking to", $settings.draft.ceiling, help: "Keep drinking until HP is over this. Off: stop once above the trigger.")
            }
            if let problem = settings.draft.problem ?? settings.error {
                Text(problem).font(.system(size: 11, weight: .semibold)).foregroundStyle(bad).padding(.top, 8).padding(.horizontal, 4)
            }
            HStack(spacing: 8) {
                Text(running == nil && settings.state(source) == .idle
                     ? "Apply saves for the next launch."
                     : applyText(settings.state(source), changed: changed))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Revert") { settings.draft = running?.settings ?? settings.saved }
                    .disabled(running != nil && !changed)
                Button("Apply") { settings.apply(settings.draft, source: source) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(settings.draft.problem != nil || (running != nil && !changed))
            }
            .padding(.top, 8).padding(.horizontal, 4)
        }
    }

    /// What the running guard's Nexus on death is doing; a description while it is off or not running.
    private func nexusStatus(_ s: GuardSnapshot?) -> (Color?, String) {
        guard let s, s.nexusOnDeath || s.deathBlocking else { return (nil, "Escapes to Nexus before a hit that would kill you") }
        if s.deathBlocking { return (bad, "Escaping to Nexus") }
        if s.deathReady { return s.armed ? (ok, "Ready") : (.gray, "Watching only (dry run)") }
        if s.deathStatus < 0 { return (warn, "Unavailable for this game build") }
        return (warn, "Enter Nexus to prepare")
    }

    private func sliderRow(_ title: String, _ value: Binding<Int>, help: String) -> some View {
        PanelRow {
            Text(title)
            Spacer()
            // No step: on macOS it draws 101 tick marks. The binding rounds to whole percent.
            Slider(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                   in: 0...100)
                .frame(width: 150)
            Text(value.wrappedValue == 0 ? "Off" : "\(value.wrappedValue)%").monospacedDigit()
                .foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
        }
        .help(help)
    }

    private func applyText(_ state: ApplyState, changed: Bool) -> String {
        switch state {
        case .waiting: return "Sending to the guard…"
        case .applied: return changed ? "Edited, not applied" : "Applied to the running guard"
        case .rejected: return "The guard refused these settings"
        case .savedForNextLaunch: return "Saved. Used next time you start the game."
        case .idle: return changed ? "Edited, not applied" : "Matches the running guard"
        }
    }

    // MARK: More

    private func more(_ s: GuardSnapshot?, _ running: GuardSnapshot?, _ link: Link, _ rate: Double?) -> some View {
        // The last session stays readable after the game closes.
        let session = running ?? (link == .offline("Game closed") ? s : nil)
        return PanelSection(title: "More") {
            if let session {
                disclosure($window.sessionOpen, running == nil ? "Last session" : "This session",
                           value: sessionLength(session, closed: running == nil)) { sessionDetail(session) }
                RowDivider()
            }
            disclosure($window.partyOpen, "Party calls", value: partyValue(running)) { partyDetail(running) }
            RowDivider()
            disclosure($window.dropsOpen, "Drop alerts", value: drops.settings.enabled ? "On" : "Off") { dropDetail() }
            RowDivider()
            disclosure($window.diagnosticsOpen, "Diagnostics and logs", value: "") { diagnostics(running, link, rate) }
        }
        .padding(.bottom, 4)
    }

    private func disclosure<Content: View>(_ open: Binding<Bool>, _ title: String, value: String,
                                           @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { open.wrappedValue.toggle() } label: {
                HStack(spacing: 8) {
                    Text(title)
                    Spacer()
                    Text(value).foregroundStyle(.secondary).lineLimit(1)
                    Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open.wrappedValue ? 90 : 0))
                }
                .frame(minHeight: 32).padding(.horizontal, 12).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open.wrappedValue { content().padding(.horizontal, 12).padding(.bottom, 10) }
        }
    }

    private func sessionLength(_ s: GuardSnapshot, closed: Bool) -> String {
        guard s.summary.start > 0 else { return "-" }
        return Format.duration((closed ? s.sampleEpoch : Date().timeIntervalSince1970) - s.summary.start)
    }

    private func sessionDetail(_ s: GuardSnapshot) -> some View {
        let summary = s.summary
        let dry = !s.armed && summary.potionsSent == 0 && summary.nexusSent == 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                tile("Potions", "\(dry ? summary.potionsDry : summary.potionsSent)")
                tile("Nexus", "\(dry ? summary.nexusDry : summary.nexusSent)")
                tile("Lowest HP", summary.closestPercent.map { String(format: "%.0f%%", $0) } ?? "-")
                    .help(summary.closestPercent == nil ? "No damage outside the Nexus yet"
                          : "\(summary.closestText), outside the Nexus at \(Format.time(summary.lowestEpoch))")
            }
            HStack {
                if dry { Text("Dry run: counts what it would have done") }
                Spacer()
                Button("Show log") { showLog(summary.logName) }.buttonStyle(.link).disabled(summary.logName.isEmpty)
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func tile(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(size: 17)).monospacedDigit()
            Text(title).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Color.black.opacity(0.18))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func partyValue(_ s: GuardSnapshot?) -> String {
        guard alerts.settings.enabled else { return "Off" }
        guard let call = s?.lastCall else { return "On" }
        let ago = Date().timeIntervalSince1970 - call.epoch
        if ago >= 300 { return "On" }
        return "\(call.caller), " + (ago < 60 ? "\(max(0, Int(ago))) s ago" : "\(Int(ago / 60)) min ago")
    }

    private func partyDetail(_ s: GuardSnapshot?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Alert when someone calls j in party chat", isOn: $alerts.settings.enabled).toggleStyle(.switch).controlSize(.small)
            HStack {
                Toggle("Play a sound", isOn: $alerts.settings.sound).toggleStyle(.checkbox)
                Spacer()
                Button("Test alert") {
                    alerts.alert(PartyCall(caller: "Test", text: "j cit", epoch: Date().timeIntervalSince1970, count: 0), test: true)
                }
            }
            .disabled(!alerts.settings.enabled)
            if let s {
                let (text, problem): (String, Bool) = {
                    switch s.chatStatus {
                    case Int32(CHAT_READING) where !WaitingMaps.contains(s): return ("In a dungeon: quiet", false)
                    case Int32(CHAT_READING): return ("Waiting for calls", false)
                    case Int32(CHAT_UNAVAILABLE): return ("Chat not supported in this build", true)
                    default: return ("Looking for chat", false)
                    }
                }()
                Text("\(text) · \(s.partyCalls) this session").foregroundStyle(problem ? bad : Color.secondary)
            }
            Text("Counts \"j\", \"jjjj\", \"j cit\" and \"join\" from other players while you wait in the Nexus, Vault, Realm, Guild Hall, Pet Yard or Daily Quest Room. Quiet in dungeons. A burst alerts once every 5 s.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }

    private func dropDetail() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Toggle("Alert when a chosen bag drops", isOn: $drops.settings.enabled).toggleStyle(.switch).controlSize(.small)
            Group {
                HStack {
                    Toggle("Play a sound", isOn: $drops.settings.sound).toggleStyle(.checkbox)
                    Spacer()
                    Button("Test alert") {
                        drops.show(DropAlert(item: "Test item", bag: .red, rarity: .legendary, shiny: false, mob: "Test", dungeon: ""))
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(DropBag.allCases, id: \.self) { bag in
                        Toggle(isOn: Binding(get: { drops.settings.bags.contains(bag) },
                                             set: { on in if on { drops.settings.bags.insert(bag) } else { drops.settings.bags.remove(bag) } })) {
                            HStack(spacing: 6) {
                                BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 16)
                                Text(bag.name).frame(width: 78, alignment: .leading)
                                Text(bag.holds).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                        .toggleStyle(.checkbox)
                    }
                }
                Picker("Lowest rarity", selection: $drops.settings.minRarity) {
                    ForEach(DropRarity.allCases, id: \.self) { Text($0 == .common ? "Any" : $0.name).tag($0) }
                }
                .fixedSize()
                Toggle("Always alert for shiny items, in any bag", isOn: $drops.settings.shiny).toggleStyle(.checkbox)
            }
            .disabled(!drops.settings.enabled)
            Text(drops.logs == 0 ? "RealmHound has no loot log yet. Open it while you play (Also open RealmHound)."
                 : "Reading RealmHound's loot log" + (drops.settings.shiny && drops.shinies.isEmpty ? " · loading the shiny list" : ""))
                .foregroundStyle(drops.logs == 0 ? bad : Color.secondary)
            Text("Uses the drops RealmHound records while it runs. Rarity counts the item's enchantment slots: Uncommon 1, Rare 2, Legendary 3, Divine 4.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .font(.system(size: 11))
    }

    private func diagnostics(_ s: GuardSnapshot?, _ link: Link, _ rate: Double?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if let s {
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 3) {
                    GridRow { Text("Checks per second").foregroundStyle(.secondary); Text(rate.map { String(format: "%.0f", $0) } ?? "-") }
                    GridRow { Text("Last gap").foregroundStyle(.secondary); Text(Format.ms(s.lastGapUs)) }
                    GridRow { Text("Worst gap (1 s)").foregroundStyle(.secondary); Text(Format.ms(s.maxGapUs)) }
                    GridRow { Text("Check work").foregroundStyle(.secondary); Text(String(format: "%.1f µs", Double(s.workNs) / 1000)) }
                    GridRow { Text("Data age").foregroundStyle(.secondary); Text(ageText(link)) }
                }
                .monospacedDigit()
            }
            Button("Export logs…") { exportLogs() }
        }
        .font(.system(size: 11))
    }

    private func ageText(_ link: Link) -> String {
        switch link {
        case .live(let age), .stale(let age): return Format.age(age)
        case .offline: return "-"
        }
    }

    /// Saves every session log plus the settings as one zip, then shows it in Finder.
    private func exportLogs() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = LogExport.defaultName()
        panel.allowedContentTypes = [.zip]
        panel.directoryURL = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask).first
        guard panel.runModal() == .OK, let url = panel.url else { return }
        // Copying and zipping tens of MB off the main thread keeps party-call checks running.
        DispatchQueue.global(qos: .userInitiated).async {
            let failure: Error?
            do { try LogExport.export(data: dataURL, to: url); failure = nil } catch { failure = error }
            DispatchQueue.main.async {
                guard let failure else { NSWorkspace.shared.activateFileViewerSelecting([url]); return }
                let alert = NSAlert(); alert.messageText = "Could not export the logs"
                alert.informativeText = failure.localizedDescription; alert.runModal()
            }
        }
    }
    private func showLog(_ name: String) {
        let log = liveURL.deletingLastPathComponent().appendingPathComponent(name)
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }
}

/// Small always-on-top strip: HP, potions and guard state. Never takes focus from the game.
struct CompactView: View {
    @ObservedObject var source: LiveSource
    @ObservedObject var alerts: PartyAlerts
    var expand: () -> Void

    var body: some View {
        CompactContent(snapshot: source.snapshot, link: source.link, expand: expand, call: alerts.popup)
    }
}

struct CompactContent: View {
    var snapshot: GuardSnapshot?
    var link: Link
    var expand: () -> Void
    /// The call in the Join popup, if any: the strip names the caller and outlines itself.
    var call: PartyCall? = nil

    var body: some View {
        let stale: Bool = { if case .stale = link { return true } else { return false } }()
        HStack(spacing: 10) {
            if let s = snapshot, s.refusal == nil, link.isLive || stale {
                let percent = s.percent ?? 0
                let color = s.deathBlocking ? bad : percent <= Double(s.potion) ? warn : ok
                HStack(spacing: 5) {
                    Circle().fill(stale ? warn : s.armed ? ok : Color.gray).frame(width: 6, height: 6)
                    Text(s.armed ? "Armed" : "Dry run").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                .frame(width: 62, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if let call {
                            Text("\(call.caller) called").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                            Spacer()
                            Text(call.text).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(s.percent == nil ? "-" : "\(s.hp.formatted()) / \(s.maxHP.formatted())").font(.system(size: 12))
                            Spacer()
                            Text(s.inNexus ? "Nexus" : s.percent.map { String(format: "%.0f%%", $0) } ?? "")
                                .font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                    }
                    .monospacedDigit()
                    HPBar(fraction: percent / 100, potion: s.potion, ceiling: s.ceiling, color: color, height: 5)
                }
                VStack(alignment: .trailing, spacing: 0) {
                    Text("\(s.totalPotions)").font(.system(size: 14)).monospacedDigit()
                    Text("pots").font(.system(size: 10)).foregroundStyle(.secondary)
                }
                .frame(width: 30, alignment: .trailing)
            } else if snapshot?.refusal != nil {
                Label("Guard checks failed: game closed", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(bad).lineLimit(1)
                Spacer()
            } else {
                Text(link == .offline("Game closed") ? "Game closed" : "Waiting for the guard")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                Spacer()
            }
            Button(action: expand) { Image(systemName: "arrow.up.left.and.arrow.down.right") }
                .buttonStyle(.plain).foregroundStyle(.secondary).help("Back to the full window")
        }
        .padding(.horizontal, 12)
        .frame(width: 340, height: 52)
        .background(panelBackground.opacity(0.95))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .strokeBorder(call != nil ? Color.accentColor : Color.white.opacity(0.12), lineWidth: call != nil ? 1.5 : 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .environment(\.colorScheme, .dark)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, UNUserNotificationCenterDelegate {
    var window: NSWindow!
    var compact: NSPanel!
    let source = LiveSource()
    let state = WindowState()
    let settings = SettingsController()
    let launch = LaunchController()
    let alerts = PartyAlerts()
    let drops = DropAlerts()
    var joinPopups: [NSPanel] = []
    var dropPopup: NSPanel!
    private var popupWatch: AnyCancellable?
    private var dropWatch: AnyCancellable?
    private var alertTimer: Timer?
    private var activity: NSObjectProtocol?
    func applicationDidFinishLaunching(_ notification: Notification) {
        // The feed is read and party calls are checked 10 times a second, also while a slider or the
        // window is being dragged; the windows redraw only when what they show changes. Without the
        // activity, App Nap slows timers while the game is in front.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Watching party chat")
        alertTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.source.refresh(detailed: self.state.diagnosticsOpen)
            #if !GUARD_SYNC_CAPTURE
            self.alerts.check(self.source)
            self.drops.check()
            #endif
        }
        RunLoop.main.add(alertTimer!, forMode: .common)
        #if !GUARD_UI_TEST && !GUARD_SYNC_CAPTURE
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
            // Always: a refused game is announced whatever the party alert settings say.
            alerts.requestPermission()
        }
        #endif
        try? FileManager.default.createDirectory(at: GuardPaths.logs(data: dataURL), withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        #if !GUARD_UI_TEST
        LogCleanup.removeOld(data: dataURL)
        #endif
        let menu = NSMenu()
        let appItem = NSMenuItem(); menu.addItem(appItem)
        let appMenu = NSMenu(); appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; NSApp.mainMenu = menu
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 760), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        #if GUARD_SYNC_CAPTURE
        window.title = "Exalt Client Mac — Sync observation"
        #else
        window.title = appName
        #endif
        window.delegate = self
        window.contentView = NSHostingView(rootView: GuardView(source: source, window: state, settings: settings, launch: launch, alerts: alerts, drops: drops))
        window.center(); window.setFrameAutosaveName("ExaltClientMacMain"); state.window = window
        state.setFloating(state.floating)
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
        // Join popup: one copy at the top centre of every monitor. They share the call, so Join or ✕ on any closes all.
        popupWatch = alerts.$popup.receive(on: DispatchQueue.main).sink { [weak self] call in
            guard let self else { return }
            if call == nil { self.joinPopups.forEach { $0.orderOut(nil) }; return }
            let screens = NSScreen.screens
            while self.joinPopups.count < screens.count {
                self.joinPopups.append(self.popupPanel(height: 76, JoinPopupView(alerts: self.alerts, source: self.source)))
            }
            for (i, panel) in self.joinPopups.enumerated() {
                guard i < screens.count else { panel.orderOut(nil); continue }
                panel.setFrameTopLeftPoint(NSPoint(x: screens[i].frame.midX - 190, y: self.popupTop(screens[i])))
                panel.orderFrontRegardless()
            }
        }
        // Drop popup: on the game's monitor, just below that monitor's Join popup while one is up.
        dropPopup = popupPanel(height: 64, DropPopupView(drops: drops))
        dropWatch = drops.$popup.receive(on: DispatchQueue.main).sink { [weak self] drop in
            guard let self, let panel = self.dropPopup else { return }
            if drop == nil { panel.orderOut(nil); return }
            if let screen = self.gameScreen() ?? NSScreen.main {
                var top = self.popupTop(screen)
                if let join = self.joinPopups.first(where: { $0.isVisible && screen.frame.contains(NSPoint(x: $0.frame.midX, y: $0.frame.midY)) }) {
                    top = join.frame.minY - 8
                }
                panel.setFrameTopLeftPoint(NSPoint(x: screen.frame.midX - 190, y: top))
            }
            panel.orderFrontRegardless()
        }
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
        // Screenshot hook: open every More row (tools/readme-screenshots.sh).
        if env["GUARD_OPEN_MORE"] != nil { state.sessionOpen = true; state.partyOpen = true; state.dropsOpen = true; state.diagnosticsOpen = true }
        #endif
        window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    private var compactMode = false
    private var compactAfterFullScreen = false
    /// Show the strip before hiding the main window: hiding the last regular window counts as
    /// A popup card above everything, including full-screen video, that never takes focus.
    private func popupPanel<V: View>(height: CGFloat, _ view: V) -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: height),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.backgroundColor = .clear; panel.isOpaque = false; panel.hasShadow = true
        panel.hidesOnDeactivate = false
        let host = NSHostingView(rootView: view)
        // Fixed size: otherwise the empty view shrinks the panel to zero and the next popup grows upward off screen.
        host.sizingOptions = []
        panel.contentView = host
        return panel
    }
    /// Where a popup's top edge goes. In full screen the visible frame reaches into the camera notch; stay below both.
    private func popupTop(_ screen: NSScreen) -> CGFloat {
        min(screen.visibleFrame.maxY, screen.frame.maxY - screen.safeAreaInsets.top) - 12
    }
    /// The screen holding most of the game window, or nil when the game has no window.
    private func gameScreen() -> NSScreen? {
        let guarded = source.link.isLive ? source.snapshot?.pid : nil
        guard let pid = guarded ?? NSWorkspace.shared.runningApplications
                .first(where: { $0.executableURL?.lastPathComponent == "RotMGExalt" })?.processIdentifier,
              let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Bounds and owner need no screen recording permission; only window titles do.
        let window = info.filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { ($0[kCGWindowBounds as String] as? NSDictionary).flatMap { CGRect(dictionaryRepresentation: $0 as CFDictionary) } }
            .max { $0.width * $0.height < $1.width * $1.height }
        let screens = NSScreen.screens
        let bounds = screens.map { CGDisplayBounds(($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0) }
        return PopupScreen.index(window: window, screens: bounds).map { screens[$0] }
    }
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
    /// Clicking a guard banner switches to the game, if one is running.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let pid = source.snapshot?.pid, source.link.isLive { GameFocus.bringForward(pid: pid) }
        completionHandler()
    }
    /// Show guard banners even while this app is in front.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list])
    }
    /// Clicking the Dock icon while compact brings the full window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showFull(); return true }
}

@main struct Main {
    static func main() {
        let app = NSApplication.shared
        _ = dataURL   // a first staging run copies prod's defaults before any controller reads them
        let delegate = AppDelegate()
        app.delegate = delegate; app.setActivationPolicy(.regular); app.run()
        withExtendedLifetime(delegate) {}
    }
}
