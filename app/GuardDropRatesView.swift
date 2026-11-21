import AppKit
import Combine
import os
import SwiftUI

/// The Drop rates tab's views; `DropRatesModel` (in GuardDropRates.swift) holds what is picked.

/// Guard | Drop rates, at the top of the main window in both tabs. An orange dot: capture is off.
struct MainTabs: View {
    @ObservedObject var rates: DropRatesModel
    @ObservedObject private var live: DropLive
    init(rates: DropRatesModel) { self.rates = rates; _live = ObservedObject(wrappedValue: rates.live) }
    var body: some View {
        HStack(spacing: 2) {
            tab("Guard", selected: !rates.shown) { rates.shown = false }
            tab("Drop rates", selected: rates.shown, warning: live.health.refused != nil) { rates.shown = true }
        }
        .padding(2)
        .background(Color.black.opacity(0.25))
        .clipShape(RoundedRectangle(cornerRadius: 7))
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
    }
    private func tab(_ title: String, selected: Bool, warning: Bool = false, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(title).font(.system(size: 12))
                if warning { Circle().fill(Color.orange).frame(width: 6, height: 6).help("Capture is off") }
            }
            .foregroundStyle(selected ? Color.primary : Color.secondary)
            .padding(.horizontal, 12).frame(height: 22)
            .background(selected ? Color.white.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 5)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Click to drawn in the Drop rates tab (issue #81), in the system log: `log stream --predicate 'category == "clicks"'`.
/// From the click (or key press; an accessibility press has no event, so from the change) to the frame committed after
/// the main queue's follow-up work (the tab's window resize). Also counts `DropRatesView` body runs: per click, and
/// between clicks (redraws no click asked for).
enum ClickTiming {
    static let log = Logger(subsystem: "exalt-client-mac", category: "clicks")
    static var bodies = 0
    private static var timed = 0.0, pending = false, logged = 0, watch: AnyCancellable?
    static func start(_ model: DropRatesModel) { watch = model.objectWillChange.sink { [unowned model] in willChange(model) } }
    private static func willChange(_ model: DropRatesModel) {
        guard !pending else { return }
        pending = true
        let up = ProcessInfo.processInfo.systemUptime, idle = bodies - logged
        var start = up
        if let event = NSApp.currentEvent, [.leftMouseUp, .leftMouseDown, .keyDown].contains(event.type), event.timestamp != timed,
           up - event.timestamp < 1 { start = event.timestamp; timed = event.timestamp }
        let before = picks(model), bodiesBefore = bodies
        // After Core Animation's commit (order 2000000), once the main queue's follow-ups have run.
        func afterCommit(_ then: @escaping () -> Void) {
            CFRunLoopAddObserver(CFRunLoopGetMain(), CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue,
                                                                                         false, 2_000_001) { _, _ in then() }, .commonModes)
        }
        afterCommit {
            DispatchQueue.main.async {
                afterCommit {
                    pending = false
                    let after = picks(model)
                    let kind = after.indices.filter { after[$0] != before[$0] }.map { pickNames[$0] }.joined(separator: "+")
                    guard !kind.isEmpty else { return }
                    let ms = (ProcessInfo.processInfo.systemUptime - start) * 1000
                    logged = bodies
                    log.notice("click \(kind, privacy: .public) \(ms, format: .fixed(precision: 1), privacy: .public) ms · \(bodies - bodiesBefore, privacy: .public) bodies · \(idle, privacy: .public) idle redraws since the last click")
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }
        }
    }
    private static let pickNames = ["tab", "dungeon", "mob", "group", "item", "bag", "tierGroup", "search", "details", "help"]
    private static func picks(_ m: DropRatesModel) -> [String] {
        [m.shown, m.dungeon as Any, m.mob as Any, m.group as Any, m.item as Any, m.openBags, m.openGroups, m.search, m.lootDetails, m.rateHelp as Any]
            .map { String(describing: $0) }
    }
}

struct DropRatesView: View {
    @ObservedObject var model: DropRatesModel
    @ObservedObject var drops: DropAlerts   // bag sprites

    var body: some View {
        let _ = ClickTiming.bodies += 1
        VStack(spacing: 0) {
            CaptureBar(model: model, live: model.live)
            LootProfileView(model: model, bar: true).padding(.horizontal, 8).padding(.bottom, 8)
            Divider()
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1))
                Divider()
            }
            HSplitView {
                // Each pane redraws only when what it shows changes: the list and the grid stay put on other clicks.
                Keyed([model.drawn, dungeon?.name, model.search, model.item]) { dungeonList }.equatable()
                    .frame(minWidth: 180, idealWidth: 240, maxWidth: 420)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Welcome(live: model.live)
                        if let dungeon {
                            Keyed([model.drawn, dungeon.name, model.mob, model.item, model.group, drops.bagSprites.count]) { dropsPane(dungeon) }
                                .equatable()
                        }
                    }
                    .padding(16)
                }
                .frame(minWidth: 360, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                ScrollView { rightPane.padding(16) }.frame(minWidth: 300, idealWidth: 380, maxWidth: 760)
            }
        }
        .frame(minWidth: 980, minHeight: 560)
        .background(Color(white: 0.12))
        .preferredColorScheme(.dark)
        .onExitCommand { model.back() }
    }

    private var report: DropReport { model.report }
    private var index: DropIndex { model.index }
    /// The picked dungeon, or the one with the most kills.
    private var dungeon: DropReport.Dungeon? {
        report.dungeons.first { $0.name == model.dungeon } ?? index.dungeons.first
    }
}

/// The tabs and capture health over the loot bar. Its own view: health changes with each import while you play.
private struct CaptureBar: View {
    let model: DropRatesModel
    @ObservedObject var live: DropLive
    var body: some View {
        let h = live.health
        HStack(spacing: 8) {
            MainTabs(rates: model)
            Spacer()
            TimelineView(.periodic(from: .now, by: 30)) { context in
                if let refused = h.refused {
                    Label("Capture is off: \(refused)", systemImage: "exclamationmark.triangle").foregroundStyle(.orange).lineLimit(1)
                } else if Self.gameRunning {
                    HStack(spacing: 5) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("Capturing" + (h.lastKill.map { " · last kill \(Self.ago($0, now: context.date))" } ?? ""))
                    }
                } else {
                    Text("Game not running" + (h.lastKill.map { " · last kill \(Self.ago($0, now: context.date))" } ?? ""))
                }
            }
            Text("· \(h.kills.formatted()) kills · \(h.bags.formatted()) bags, \(h.linked.formatted()) linked · ")
                + Text("\(h.lost.formatted()) records lost").foregroundColor(h.lost > 0 ? .orange : .secondary)
        }
        .font(.caption).foregroundStyle(.secondary).padding(8)
        .help("Capture health over all the data kept")
    }
    private static var gameRunning: Bool {
        NSWorkspace.shared.runningApplications.contains { $0.executableURL?.lastPathComponent == LaunchPlan.gameProcess }
    }
    private static func ago(_ time: Double, now: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: Date(timeIntervalSince1970: time), relativeTo: now)
    }
}

/// Until the first kill is recorded.
private struct Welcome: View {
    @ObservedObject var live: DropLive
    var body: some View {
        if live.health.kills == 0 { note }
    }
    private var note: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No drops recorded yet").font(.headline)
            Text("Start the game from the Guard tab. Every kill and bag you see is recorded here, and rates appear as your runs add up.")
            Text("Rates show a percent and a bar: the wider its band, the less sure. Hover a rate for its counts; the ⓘ explains more.").foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension DropRatesView {
    // MARK: Dungeons and search

    private var dungeonList: some View {
        let q = model.search.trimmingCharacters(in: .whitespaces)
        let index = index, picked = dungeon?.name
        let sorted = q.isEmpty ? index.dungeons : index.dungeons.filter { $0.name.localizedCaseInsensitiveContains(q) }   // dungeons you played first
        let rows = model.stable("dungeons", sorted) { index.kills(in: $0.name) }
        let items = q.isEmpty ? [] : index.search(q)
        return VStack(spacing: 0) {
            TextField("Search items or dungeons", text: $model.search).textFieldStyle(.roundedBorder).padding(8)
            // A lazy stack, not a List: a List re-measures every row it inserts, which made each keystroke and pick slow (issue #81).
            ScrollView { LazyVStack(alignment: .leading, spacing: 0) {
                if !q.isEmpty && items.isEmpty && rows.isEmpty {
                    Text("Nothing matches “\(q)”.").foregroundStyle(.secondary).modifier(ListRowInsets())
                }
                if !items.isEmpty {
                    listSection("Items") {
                        ForEach(items, id: \.self) { item in
                            listRow(model.item == item, { model.group = nil; model.item = item }) {
                                SpriteIcon(image: model.sprites[item], size: 24)
                                Text(report.name(item)).lineLimit(1).help(report.name(item))
                            }
                        }
                    }
                }
                listSection("Dungeons") {
                    ForEach(rows, id: \.row.name) { d, grew in
                        let n = index.kills(in: d.name)
                        Keyed([model.drawn, d.name, picked == d.name, grew, n]) {   // a pick re-measures only the rows it changes
                            listRow(picked == d.name, { model.select(dungeon: d.name) }) {
                                SpriteIcon(image: d.portal.flatMap { model.sprites[$0] }, size: 24)
                                Text(d.name).lineLimit(1).help(d.name)
                                Spacer()
                                if grew { newMark }
                                if n > 0 { Text(n.formatted()).monospacedDigit().foregroundStyle(.secondary) }
                            }
                            .opacity(n > 0 ? 1 : 0.5)
                            .accessibilityLabel("\(d.name), \(n) kills")
                        }
                        .equatable()
                    }
                }
                if q.isEmpty { uncatalogedSection }
            }.padding(.vertical, 6) }
        }
    }

    /// Seen in play but missing from the drop catalog (issue #51): shown by game name until a refresh picks them up.
    @ViewBuilder private var uncatalogedSection: some View {
        let u = report.uncataloged
        if !(u.dungeons.isEmpty && u.mobs.isEmpty && u.items.isEmpty) {
            listSection("Not in the catalog yet", help: "Seen in play but missing from the drop catalog. Running tools/drop_catalog.py build picks them up.") {
                ForEach(u.dungeons, id: \.self) { name in uncatalogedRow(nil, name, "map") }
                ForEach(u.mobs, id: \.self) { mob in uncatalogedRow(model.sprites[mob.type], report.name(mob.type), mob.dungeon) }
                ForEach(u.items, id: \.self) { item in uncatalogedRow(model.sprites[item], report.name(item), "item") }
            }
        }
    }
    private func uncatalogedRow(_ sprite: CGImage?, _ name: String, _ kind: String) -> some View {
        HStack(spacing: 8) {
            SpriteIcon(image: sprite, size: 20)
            Text(name).lineLimit(1).help(name)
            Spacer()
            Text(kind).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }
        .modifier(ListRowInsets())
    }
    /// A section of the dungeon list: its header, as a List draws one, then its rows.
    private func listSection<Content: View>(_ title: String, help: String? = nil, @ViewBuilder _ rows: () -> Content) -> some View {
        Group {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
                .help(help ?? "")
            rows()
        }
    }

    // MARK: Bags and drops

    private func dropsPane(_ d: DropReport.Dungeon) -> some View {
        let mobs = index.mobs(in: d.name)
        let runs = report.runs[d.name] ?? 0
        let dropped = Set(mobs.flatMap { (report.copies[$0] ?? [:]).keys })
        let shown = index.possible[d.name] ?? []
        let rows = index.tiles[d.name] ?? [:]
        return VStack(alignment: .leading, spacing: 12) {
            breadcrumb(d)
            Text("\(runs.formatted()) runs · \(index.kills(in: d.name).formatted()) kills across \(mobs.count) mob types").foregroundStyle(.secondary)
            if !mobs.isEmpty { mobStrip(mobs) }
            if shown.isEmpty {
                Text(d.codes.isEmpty ? "No drop data for this area: the game data doesn't list what drops here. Items show up here as they drop."
                     : "No known drops yet.").foregroundStyle(.secondary)
            }
            ForEach(DropBag.allCases.reversed().map(Optional.some) + [nil], id: \.self) { bag in
                if let tiles = rows[bag] {
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if let bag { BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 28).help(bag.name).accessibilityLabel(bag.name) }
                            else { Image(systemName: "questionmark.square.dashed").font(.system(size: 22)).foregroundStyle(.secondary).help("No bag in the game data") }
                        }
                        .frame(width: 36, height: 36)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 4)], alignment: .leading, spacing: 6) {
                            ForEach(tiles, id: \.self) { tile in   // a pick redraws only the tiles it selects or clears
                                Keyed([model.drawn, d.name, tile, selected(tile)]) { tileView(tile, d, dropped: dropped) }.equatable()
                            }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    /// The game's collection icon for the dungeon's items (from its sheet), beside the dungeon's name.
    @ViewBuilder private func collectionIcon(_ d: DropReport.Dungeon) -> some View {
        if let icon = model.collectionIcons[d.name] {
            SpriteIcon(image: icon, size: 20).help("The game's collection icon for \(d.name) items")
        }
    }

    /// Dungeon › mob › group › item; each part steps back to it.
    private func breadcrumb(_ d: DropReport.Dungeon) -> some View {
        HStack(spacing: 6) {
            Button { model.mob = nil; model.group = nil; model.item = nil } label: { Text(d.name).font(.title3.weight(.semibold)) }
                .buttonStyle(.plain)
            collectionIcon(d)
            if let mob = model.mob {
                chevron
                Button { model.group = nil; model.item = nil } label: { Text(report.name(mob.type)) }.buttonStyle(.plain)
            }
            if let group = model.group {
                chevron
                Button { model.item = nil } label: { Text(group.name) }.buttonStyle(.plain)
            }
            if let item = model.item {
                chevron
                Text(report.name(report.base(item))).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Text("esc steps back").font(.caption).foregroundStyle(.tertiary)
        }
    }
    private var chevron: some View { Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) }

    /// The bosses and the minions killed here, each in their own row. Clicking one opens its page on the right;
    /// clicking it again, the breadcrumb or Esc closes it.
    private func mobStrip(_ mobs: [DropReport.Mob]) -> some View {
        let bosses = mobs.filter { report.bosses.contains($0.type) }, minions = mobs.filter { !report.bosses.contains($0.type) }
        return VStack(alignment: .leading, spacing: 6) {
            if !bosses.isEmpty { mobRow("BOSSES", bosses) }
            if !minions.isEmpty { mobRow("MINIONS", minions) }
        }
    }
    private func mobRow(_ title: String, _ mobs: [DropReport.Mob]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(mobs, id: \.self) { mob in
                let boss = report.bosses.contains(mob.type), name = report.name(mob.type), n = report.kills[mob] ?? 0
                Keyed([model.drawn, mob, model.mob == mob]) {
                    chip(selected: model.mob == mob, { model.pick(mob: mob) }) {
                        SpriteIcon(image: model.sprites[mob.type], size: 20)
                        Text(name).lineLimit(1)
                    }
                    .help("\(name) · \(n.formatted()) kills")
                    .accessibilityLabel("\(name)\(boss ? ", boss" : ""), \(n) kills")
                }
                .equatable()
            }
            }
        }
    }
    private func chip<Content: View>(selected: Bool, _ action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 5) { content() }
                .font(.caption).padding(.horizontal, 6).frame(height: 28).frame(maxWidth: .infinity, alignment: .leading)
                .background(tileBackground(selected)).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func selected(_ tile: DropReport.Tile) -> Bool {
        switch tile {
        case .item(let item): return model.item == item && model.group == nil
        case .group(let group, _): return model.group == group && model.item == nil
        }
    }
    @ViewBuilder private func tileView(_ tile: DropReport.Tile, _ d: DropReport.Dungeon, dropped: Set<Int>) -> some View {
        let anyDropped = tile.items.contains { report.variants($0).contains(where: dropped.contains) }
        switch tile {
        case .item(let item):
            let name = report.name(item), shiny = report.variants(item).contains { report.shinyOf[$0] != nil }
            Button { model.group = nil; model.item = model.item == item ? nil : item } label: {
                SpriteIcon(image: model.sprites[item], size: 32).opacity(anyDropped ? 1 : 0.35).padding(4)
                    .background(tileBackground(selected(tile)))
            }
            .buttonStyle(.plain)
            .help(name + (shiny ? " (and its shiny)" : "") + (anyDropped ? "" : " · not dropped here yet"))
            .accessibilityLabel(name + (anyDropped ? "" : ", not dropped here yet"))
        case .group(let group, let items):
            // The still sprite: the member that dropped most here, else the first by name.
            let shown = items.max { report.dropped($0) < report.dropped($1) }.flatMap { report.dropped($0) > 0 ? $0 : nil } ?? items[0]
            Button { model.item = nil; model.group = model.group == group ? nil : group } label: {
                GroupTile(sprites: model.rotation(items, first: shown), tier: group.tier)
                    .opacity(anyDropped ? 1 : 0.35).padding(4)
                    .background(tileBackground(selected(tile)))
            }
            .buttonStyle(.plain)
            .help("\(group.name): \(items.map(report.name).joined(separator: ", "))")
            .accessibilityLabel("\(group.name), \(items.count) items" + (anyDropped ? "" : ", none dropped here yet"))
        }
    }


    // MARK: Right pane

    @ViewBuilder private var rightPane: some View {
        if model.lootDetails { LootProfileView(model: model) }
        else if let item = model.item { itemPane(report.base(item)) }
        else if let group = model.group, let d = dungeon { groupPane(group, d) }
        else if let mob = model.mob { MobPage(model: model, mob: mob, bagSprites: drops.bagSprites) }
        else if let d = dungeon { summaryPane(d) }
    }

    /// A tier group in this dungeon: the odds of any of it per run, then each item.
    private func groupPane(_ group: DropReport.Group, _ d: DropReport.Dungeon) -> some View {
        let members = report.members[group] ?? []
        let runs = report.runs[d.name] ?? 0
        let all = members.reduce(into: Set<Int>()) { $0.formUnion(report.variants($1)) }
        let rows = model.stable("group", members.sorted { report.runsWith(d.name, report.variants($0)) > report.runsWith(d.name, report.variants($1)) }) {
            report.runsWith(d.name, report.variants($0))
        }
        let scale = RateAxis(rows.map { DropRate(count: report.runsWith(d.name, report.variants($0.row)), of: runs) })
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                GroupTile(sprites: model.rotation(members, first: members[0]), tier: group.tier, size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.name).font(.title3.weight(.semibold))
                    Text("\(members.count) items · \(d.name)").foregroundStyle(.secondary)
                }
            }
            if runs > 0 {
                section("ANY OF THESE · per run") { row { RateView(rate: .init(count: report.runsWith(d.name, all), of: runs), unit: "runs") } }
            } else {
                Text("No boss died here, so there are no runs to count. Each item's page has its rates per kill.").foregroundStyle(.secondary)
            }
            section("EACH ITEM · per run") {
                ForEach(rows, id: \.row) { item, grew in
                    clickRow({ model.item = item }) {
                        SpriteIcon(image: model.sprites[item], size: 24)
                        Text(report.name(item)).lineLimit(1).help(report.name(item))
                        Spacer()
                        if grew { newMark }
                        if runs > 0 { RateView(rate: .init(count: report.runsWith(d.name, report.variants(item)), of: runs), unit: "runs", scale: scale) }
                    }
                    .accessibilityLabel(report.name(item))
                }
            }
            Text("Click an item for where else it drops.").font(.caption).foregroundStyle(.secondary)
        }
    }

    /// One item, from every dungeon: its bag, where it drops (one box per dungeon, surest first, with each mob), its
    /// shiny, and the rarity of every copy.
    private func itemPane(_ item: Int) -> some View {
        let types = report.variants(item), shinies = types.filter { report.shinyOf[$0] != nil }
        let sources = model.stable("sources", report.sources(types)) { $0.runsWith + $0.mobs.values.reduce(0, +) }
        let total = types.reduce(0) { $0 + report.dropped($1) }
        let possible = index.possibleIn[item] ?? []
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SpriteIcon(image: model.sprites[item], size: 44)
                if let unlocked = report.unlocks[item] {   // a blueprint: the items it unlocks in the forge
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    ForEach(unlocked, id: \.self) { u in SpriteIcon(image: model.sprites[u], size: 44).help(report.name(u)) }
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.name(item)).font(.title3.weight(.semibold)).lineLimit(2)
                    if let unlocked = report.unlocks[item] {
                        Text("Unlocks \(unlocked.map(report.name).formatted(.list(type: .and))) in the forge")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(3)
                    }
                    HStack(spacing: 6) {
                        if let bag = report.bag(item) { pill(bag.name, BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 12)) }
                        if let tier = report.group(item)?.tier { pill("T\(tier)", EmptyView()) }
                    }
                }
            }
            if sources.isEmpty {
                Text(possible.isEmpty ? "Not dropped yet." : "Not dropped yet. The game data or RealmEye lists it in:").foregroundStyle(.secondary)
                ForEach(possible, id: \.self) { name in
                    clickRow({ model.select(dungeon: name, keepItem: true) }) { Text(name); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                }
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    sectionTitle("WHERE IT DROPS")
                    let scale = RateAxis(sources.compactMap { $0.row.perRun })
                    ForEach(sources, id: \.row.dungeon) { entry in sourceBox(entry.row, grew: entry.grew, scale: scale) }
                }
            }
            if let shiny = shinies.min() { shinyBox(shiny, shinies: shinies, of: types, sources: sources.map(\.row)) }
            if total > 0 {
                section("RARITY · every copy") { RarityBars(counts: report.rarityCounts(types), total: total).padding(12) }
            }
        }
    }
    private func pill<Icon: View>(_ text: String, _ icon: Icon) -> some View {
        HStack(spacing: 4) { icon; Text(text) }
            .font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
    }

    /// A dungeon on the item page: its total rate per run (or a note when no boss died there), then each mob's per kill.
    /// The name goes to the dungeon, keeping the item open.
    private func sourceBox(_ s: DropReport.Source, grew: Bool, scale: RateAxis) -> some View {
        let mobs = s.mobs.sorted {
            report.perKill($0.key, $0.value).range.lowerBound > report.perKill($1.key, $1.value).range.lowerBound
        }
        let mobScale = RateAxis(mobs.map { report.perKill($0.key, $0.value) })
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { model.select(dungeon: s.dungeon, keepItem: true) } label: {
                    Text(s.dungeon).fontWeight(.semibold).lineLimit(1)
                }
                .buttonStyle(.plain).help("Show \(s.dungeon)")
                if grew { newMark }
                Spacer()
                if let perRun = s.perRun { RateView(rate: perRun, unit: "runs", scale: scale) }
                else { Text("no runs: no boss died here").font(.caption).foregroundStyle(.secondary) }
                rateInfo(s.dungeon)
            }
            ForEach(mobs, id: \.key) { mob, n in
                HStack(spacing: 6) {
                    SpriteIcon(image: model.sprites[mob.type], size: 20)
                    Text(report.name(mob.type)).lineLimit(1).help(report.name(mob.type))
                    Spacer()
                    let rate = report.perKill(mob, n)
                    YoursRate(model: model, live: model.live, rate: rate, mob: mob, unit: "kills", copies: true, scale: mobScale)
                }
                .padding(.trailing, 20)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }

    /// The shiny: how often one drops per run (over the runs in every place the item dropped), and how many of the
    /// item's copies were shiny.
    private func shinyBox(_ shiny: Int, shinies: Set<Int>, of types: Set<Int>, sources: [DropReport.Source]) -> some View {
        let ran = sources.filter { $0.runs > 0 }
        let runs = ran.reduce(0) { $0 + $1.runs }, shinyRuns = ran.reduce(0) { $0 + report.runsWith($1.dungeon, shinies) }
        let copies = types.reduce(0) { $0 + report.dropped($1) }, shinyCopies = shinies.reduce(0) { $0 + report.dropped($1) }
        return VStack(alignment: .leading, spacing: 6) {
            sectionTitle("SHINY")
            HStack(spacing: 12) {
                SpriteIcon(image: model.sprites[shiny], size: 44).overlay(alignment: .topTrailing) {
                    ShinyMark(size: 16).offset(x: 5, y: -5)
                }
                .help(report.name(shiny))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("per run").font(.caption).foregroundStyle(.secondary)
                        if runs > 0 { RateView(rate: .init(count: shinyRuns, of: runs), unit: "runs") } else { Text("no runs yet").font(.caption) }
                        rateInfo("shiny")
                    }
                    HStack(spacing: 6) {
                        Text("of drops").font(.caption).foregroundStyle(.secondary)
                        RateView(rate: .init(count: shinyCopies, of: copies), unit: "drops", verb: "shiny")
                    }
                    .padding(.trailing, 20)
                }
            }
            .padding(12)
            .background(Color.white.opacity(0.05)).clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
    }

    /// With nothing picked: the bosses' best bag per run.
    private func summaryPane(_ d: DropReport.Dungeon) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) { Text(d.name).font(.title3.weight(.semibold)); collectionIcon(d) }
            if let bosses = report.bossBags[d.name], let runs = report.runs[d.name] {
                let scale = RateAxis((bosses[nil] ?? [:]).values.map { DropRate(count: $0, of: runs) })
                section("BEST BAG FROM THE BOSSES, PER RUN") {
                    ForEach(sortedBags(bosses[nil] ?? [:]), id: \.self) { bag in
                        row { bagLabel(bag); Spacer(); RateView(rate: .init(count: bosses[nil]![bag]!, of: runs), unit: "runs", scale: scale) }
                    }
                }
            } else {
                Text("No runs here yet: a run counts once a boss dies.").foregroundStyle(.secondary)
            }
            Text("Click an item or a tier group for its rates, or a mob for its page.").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Pieces

    private func sectionTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
    }
    private func section<Content: View>(_ title: String, info: String? = nil, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { sectionTitle(title); Spacer(); if let info { rateInfo(info) } }
            VStack(alignment: .leading, spacing: 0) { content() }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.white.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        }
    }
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }.frame(minHeight: 32).padding(.horizontal, 12).padding(.vertical, 4)
    }
    private func clickRow<Content: View>(_ action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
        Button(action: action) { row(content).contentShape(Rectangle()) }.buttonStyle(.plain)
    }
    private func listRow<Content: View>(_ selected: Bool, _ action: @escaping () -> Void, @ViewBuilder _ content: () -> Content) -> some View {
        Button(action: action) {
            HStack(spacing: 6) { content() }.modifier(ListRowInsets())
                .background(selected ? Color.accentColor.opacity(0.25) : Color.clear).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
    /// ⓘ: how to read a rate, in one place.
    private func rateInfo(_ key: String) -> some View {
        Button { model.rateHelp = model.rateHelp == key ? nil : key } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("How to read a rate").accessibilityLabel("How to read a rate")
            .popover(isPresented: Binding(get: { model.rateHelp == key }, set: { if !$0, model.rateHelp == key { model.rateHelp = nil } }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to read a rate").font(.headline)
                    Text("**5%** is your rate so far: drops ÷ runs (or kills, for a mob).")
                    Text("**The bar**: the tick is the rate, the band where the true rate likely is (95% confidence). A wide band means few drops yet; it narrows as they add up. Bars in one list share a scale, each step ×10, so a band is as wide for an unsure 0.1% as for an unsure 50%. Hover a rate for its counts.")
                    Text("**Per run** counts runs where a boss died with at least one copy. **Surest first** sorts by the low end of each range, so a lucky early drop doesn't come out on top.")
                    Divider()
                    Text("How rates are calculated").font(.headline)
                    Text("**Per kill rates are base rates**, with loot boosts taken out: each kill counts as its loot multiplier then, so a kill with a Loot Drop Potion (×1.5) counts as 1.5 kills. The factors multiply: potion, gear enchantments, the dungeon's modifiers, Crucible and Blood Ritual. **Items count every copy**: two vits from one kill count 2. So a rate can top 100%: 130% is one sure and a 30% chance of a second.")
                    Text("**Gold** (while you play) is the base rate × your loot boosts now, as a number and a tick on the bar. The loot bar above shows it.")
                    if model.report.gearUnknown > 0 {
                        Text("Gear enchantments weren't captured for \(model.report.gearUnknown.formatted()) kills; they count without one (at most +12% off).")
                            .foregroundStyle(.secondary)
                    }
                    Text("Drop accelerators and server loot events aren't captured yet, so they're left out. So is the Crucible on kills from before this build, and on the first map after launch.").foregroundStyle(.secondary)
                    Text("**Per run** and bag colour rates are as seen, boosts included.").foregroundStyle(.secondary)
                }
                .font(.callout).frame(width: 340).padding(14)
            }
    }
    /// A row whose count grew since you opened it.
    private var newMark: some View {
        Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("New since you opened this").accessibilityLabel("new")
    }
    private func bagLabel(_ bag: DropBag) -> some View {
        HStack(spacing: 6) { BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 16); Text(bag.name) }
    }
    /// Best colour first.
    private func sortedBags(_ bags: [DropBag: Int]) -> [DropBag] { DropBag.allCases.reversed().filter { bags[$0] != nil } }
}

/// A mob's page (issue #50), laid out like the dungeon's grid: a row per bag with the bag's total that opens to a cell per
/// untiered item with its drop chance per kill, drops/kills and ±, then a full-width row per tier group that opens in
/// place to its items. Items it can drop but hasn't yet are faded at 0/N. An item opens its item page.
struct MobPage: View {
    @ObservedObject var model: DropRatesModel
    var mob: DropReport.Mob
    var bagSprites: [DropBag: CGImage]

    var body: some View {
        let report = model.report, kills = report.kills[mob] ?? 0, runs = report.runs[mob.dungeon] ?? 0
        let tiles = report.tiles(of: mob)   // once per page: each bag's rows share a bar axis, and the bags one more
        let bagScale = RateAxis(tiles.values.map { report.perKill(mob, report.killsWith(mob, $0)) })
        let rowScales = tiles.mapValues { row in RateAxis(row.map { report.perKill(mob, report.copies(mob, [$0])) }) }
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                SpriteIcon(image: model.sprites[mob.type], size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.name(mob.type)).font(.title3.weight(.semibold)).lineLimit(2)
                    HStack(spacing: 6) {
                        if report.bosses.contains(mob.type) { pill("Boss").foregroundStyle(.orange) }
                        pill(mob.dungeon)
                    }
                }
            }
            Text("\(kills.formatted()) kills · "
                 + (runs > 0 ? "killed in \((report.mobRuns[mob] ?? 0).formatted()) of \(runs.formatted()) runs" : "no runs: no boss died here")
                 + " · \((report.maxHP[mob] ?? 0).formatted()) HP").foregroundStyle(.secondary)
            if let portals = report.portals[mob], !portals.isEmpty {
                Text("PORTALS · per kill").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                ForEach(portals.sorted { ($1.value, report.name($0.key)) < ($0.value, report.name($1.key)) }, id: \.key) { type, n in
                    HStack(spacing: 10) {
                        SpriteIcon(image: model.sprites[type], size: 28).frame(width: 36, height: 36)
                        Text(report.name(type)).font(.callout.weight(.medium)).lineLimit(1)
                        Spacer()
                        numbers(n, stacked: false, asSeen: true)
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                }
            }
            Text("DROPS · per kill").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if tiles.isEmpty { Text("No drops from this mob yet.").foregroundStyle(.secondary) }
            ForEach(DropBag.allCases.reversed().map(Optional.some) + [nil], id: \.self) { bag in
                if let row = tiles[bag] {
                    let open = model.openBags.contains(bag)
                    // A bag is one row (icon, name, its total) until clicked open.
                    Button { if open { model.openBags.remove(bag) } else { model.openBags.insert(bag) } } label: {
                        HStack(spacing: 10) {
                            Group {
                                if let bag { BagIcon(bag: bag, sprite: bagSprites[bag], size: 28) }
                                else { Image(systemName: "questionmark.square.dashed").font(.system(size: 22)).foregroundStyle(.secondary) }
                            }
                            .frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(bag?.name ?? "No bag in the game data").font(.callout.weight(.medium))
                                Text("\(row.count) \(row.count == 1 ? "entry" : "entries")").font(.caption2).foregroundStyle(.secondary)
                            }
                            Spacer()
                            numbers(report.killsWith(mob, row), stacked: false, scale: bagScale)
                            Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 4).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(bag?.name ?? "No bag"), \(report.perKill(mob, report.killsWith(mob, row)).percent) per kill")
                    .accessibilityAddTraits(open ? .isSelected : [])
                    if open {
                        // Untiered items in a grid, then each tier group as a full-width row that opens in place.
                        VStack(alignment: .leading, spacing: 6) {
                            let singles = row.filter { if case .item = $0 { return true } else { return false } }
                            if !singles.isEmpty { grid(singles, kills: kills, scale: rowScales[bag]) }
                            ForEach(row, id: \.self) { tile in
                                if case .group(let group, let items) = tile {
                                    VStack(alignment: .leading, spacing: 6) {
                                        cell(tile, kills: kills, scale: rowScales[bag])
                                        if model.openGroups.contains(group) {
                                            grid(items.map(DropReport.Tile.item), kills: kills, scale: rowScales[bag])
                                                .padding([.horizontal, .bottom], 6)
                                        }
                                    }
                                    .background(Color.white.opacity(model.openGroups.contains(group) ? 0.04 : 0))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                }
                            }
                        }
                        .padding(.leading, 46)
                    }
                    Divider()
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("Per kill, with loot boosts taken out. Items count every copy, so a rate can top 100%.")
                Text("Faded: not dropped by this mob yet. Portals count as seen, boosts included.")
                Text("Click a bag or a tier group to open it; an item opens its page. Esc steps back.")
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// An item or tier group: sprite (a group cycles its kinds, with its tier), name, drop chance, drops/kills · ±.
    private func grid(_ tiles: [DropReport.Tile], kills: Int, scale: RateAxis?) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 6)], alignment: .leading, spacing: 6) {
            ForEach(tiles, id: \.self) { cell($0, kills: kills, scale: scale) }
        }
    }

    /// `scale`: the bar axis its bag's tiles share (a group's members sit under the group).
    private func cell(_ tile: DropReport.Tile, kills: Int, scale: RateAxis?) -> some View {
        let report = model.report, n = report.copies(mob, [tile]), rate = report.perKill(mob, n).rate
        let name: String, open: Bool?
        switch tile {
        case .item(let item): name = report.name(item); open = nil
        case .group(let group, _): name = group.name; open = model.openGroups.contains(group)
        }
        return Button {
            switch tile {
            case .item(let item): model.group = nil; model.item = item
            case .group(let group, _): if open == true { model.openGroups.remove(group) } else { model.openGroups.insert(group) }
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    switch tile {
                    case .item(let item): SpriteIcon(image: model.sprites[item], size: 32)
                    case .group(let group, let items):
                        let first = items.first { report.killsWith(mob, [.item($0)]) > 0 } ?? items[0]
                        GroupTile(sprites: model.rotation(items, first: first), tier: group.tier)
                    }
                }
                .frame(width: 32, height: 32).opacity(n > 0 ? 1 : 0.35)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    numbers(n, stacked: false, copies: true, scale: scale)
                }
                Spacer(minLength: 0)
                if let open { Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(tileBackground(open == true))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(n > 0 ? "\(name): \(n.formatted()) \(n == 1 ? "copy" : "copies") in \(kills.formatted()) kills" + (rate >= 1
              ? ". \(DropRate.percent(rate)) per kill: \(Int(rate)) sure" + (rate - rate.rounded(.down) < 0.005 ? "" : ", and a \(DropRate.percent(rate - rate.rounded(.down))) chance of one more") : "")
              : "\(name): not dropped by this mob yet")
        .accessibilityLabel("\(name), \(report.perKill(mob, n).percent) per kill")
    }

    /// A mob's rate as a number and a bar (issue #67). The % is the base rate; while you play, yours shows in gold.
    /// `copies`: every copy counts (items, tier groups); else a share of kills (bags, portals). Bags share one scale,
    /// portals another; a tile passes its bag's. `stacked` is kept for its callers and no longer changes the layout.
    /// `asSeen`: per kill as seen, not a base rate (portals: whether boosts change them is still open, #64).
    private func numbers(_ n: Int, stacked: Bool, copies: Bool = false, scale: RateAxis? = nil, asSeen: Bool = false) -> some View {
        let report = model.report, kills = report.kills[mob] ?? 0
        let rate = asSeen ? DropRate(count: n, of: kills) : report.perKill(mob, n)
        let scale = scale ?? RateAxis((report.portals[mob] ?? [:]).values.map { DropRate(count: $0, of: kills) })   // portals'
        return Group {
            if asSeen { RateView(rate: rate, unit: "kills", verb: "opened", scale: scale) }
            else { YoursRate(model: model, live: model.live, rate: rate, mob: mob, unit: "kills", copies: copies, scale: scale) }
        }
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
    }
}

/// A dungeon list row's size, as a List row: 32 pt apart, inset from the edges.
private struct ListRowInsets: ViewModifier {
    func body(content: Content) -> some View {
        content.padding(.horizontal, 16).frame(maxWidth: .infinity, minHeight: 32, alignment: .leading)
    }
}

/// `content`, redrawn only when `key` changes (issue #81). The key lists everything the content reads that can change.
struct Keyed<Content: View>: View, Equatable {
    let key: [AnyHashable?]
    let content: () -> Content
    init(_ key: [AnyHashable?], @ViewBuilder _ content: @escaping () -> Content) { self.key = key; self.content = content }
    var body: some View { content() }
    static func == (a: Self, b: Self) -> Bool { a.key == b.key }
}

/// A base rate with yours beside it (issue #58). Its own view: yours follows the game each second, and only these redraw.
struct YoursRate: View {
    let model: DropRatesModel
    @ObservedObject var live: DropLive
    var rate: DropRate, mob: DropReport.Mob, unit: String, copies = false, scale: RateAxis?
    var body: some View { RateView(rate: rate, unit: unit, copies: copies, yours: model.yours(rate, mob), scale: scale) }
}

func tileBackground(_ selected: Bool) -> some View {
    RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(selected ? 0.12 : 0.04))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
}

extension DropRatesModel {
    /// A group's sprites by kind, in its family's fixed order (sword, dagger, bow, …; attack, defense, speed, … rings).
    func rotation(_ items: [Int], first: Int) -> GroupTile.Rotation {
        GroupTile.Rotation(kinds: report.kinds(items).map { $0.map { sprites[$0] } }, still: sprites[first])
    }
}

/// A tier group's tile: its kinds in turn, one a second on the wall clock, so groups with the same kinds (T7 and T8
/// weapons) show the same kind at once. A kind with two items shows the next one each time round. `still` with Reduce
/// Motion.
struct GroupTile: View {
    struct Rotation {
        var kinds: [[CGImage?]], still: CGImage?
        func frame(_ second: Int) -> CGImage? {
            let kind = kinds[second % kinds.count]
            return kind[second / kinds.count % kind.count]
        }
    }
    var sprites: Rotation
    var tier: Int
    var size: CGFloat = 32
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !reduceMotion && sprites.kinds.joined().count > 1 {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    SpriteIcon(image: sprites.frame(Int(context.date.timeIntervalSince1970)), size: size)
                }
            } else {
                SpriteIcon(image: sprites.still, size: size)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Text("T\(tier)").font(.system(size: 9, weight: .bold)).padding(.horizontal, 2)
                .background(Color.black.opacity(0.75)).clipShape(RoundedRectangle(cornerRadius: 3)).offset(x: 4, y: 4)
        }
    }
}

/// Copies by rarity: one row per rarity with its gems, a bar in its colour (longest = most copies), the count and the
/// share; empty rarities faded, and copies without a rarity counted below.
struct RarityBars: View {
    var counts: [Int]   // by DropRarity
    var total: Int
    var body: some View {
        let rated = max(counts.reduce(0, +), 1), most = max(counts.max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(DropRarity.allCases.reversed(), id: \.self) { r in
                let n = counts[r.rawValue]
                HStack(spacing: 8) {
                    Group { if r == .common { Text("–").foregroundStyle(.secondary) } else { RarityGems(rarity: r, gem: 6) } }
                        .frame(width: 22, height: 14)
                    Text(r.name).font(.caption).frame(width: 70, alignment: .leading)
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.06))
                            Capsule().fill(RarityGems.colors[r.rawValue]).frame(width: n == 0 ? 0 : max(geo.size.width * CGFloat(n) / CGFloat(most), 6))
                        }
                    }
                    .frame(height: 8)
                    Text(n.formatted()).font(.caption.weight(.semibold)).monospacedDigit().frame(width: 28, alignment: .trailing)
                    Text("\(Int((Double(n) / Double(rated) * 100).rounded()))%").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        .frame(width: 34, alignment: .trailing)
                }
                .opacity(n == 0 ? 0.4 : 1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(r.name): \(n)")
            }
            let none = total - counts.reduce(0, +)
            if none > 0 { Text("\(none.formatted()) with no rarity: potions and items without enchantments").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

/// A game sprite, pixel-sharp; a faint dashed square while it loads or when RealmHound's art is missing.
struct SpriteIcon: View {
    var image: CGImage?
    var size: CGFloat
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0.15), style: StrokeStyle(lineWidth: 1, dash: [3]))
                .frame(width: size * 0.8, height: size * 0.8).frame(width: size, height: size)
        }
    }
}

/// A rate as a number and a bar (issue #67, the format the whole tab uses): the tick is the rate, the band its 95%
/// range, on `scale`, the log axis its list shares (nil: its own). A gold number and
/// tick show yours. Hovering opens `RateCard`, which labels the bar. `copies`, `verb`: see `DropRate.caption`.
struct RateView: View {
    var rate: DropRate
    var unit: String
    var copies = false
    var verb = "dropped"
    var yours: Double?   // the rate with your loot boosts now (issue #58)
    var scale: RateAxis?
    @StateObject private var hover = Hover()
    /// Whether the pointer is over the rate. (@State needs a compiler plugin this build doesn't load.)
    final class Hover: ObservableObject { @Published var on = false }

    var body: some View {
        if rate.of == 0 {
            Text("no \(unit) yet").font(.caption).foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                Text(rate.percent).fontWeight(.semibold).frame(minWidth: 40, alignment: .trailing)
                if let yours { Text(DropRate.percent(yours)).font(.caption.weight(.semibold)).foregroundStyle(lootGold) }
                RateBar(rate: rate, axis: scale ?? RateAxis([rate]), yours: yours).frame(width: 80)
            }
            .monospacedDigit()
            .contentShape(Rectangle())
            .onHover { hover.on = $0 }
            .popover(isPresented: $hover.on, arrowEdge: .bottom) {
                RateCard(rate: rate, axis: scale ?? RateAxis([rate]), caption: rate.caption(unit, copies: copies, verb: verb), yours: yours)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(rate.percent), \(rate.likely), \(rate.caption(unit, copies: copies, verb: verb))")
        }
    }
}

/// The hover card (issue #67): the bar drawn large on the same axis as its row, with faint gridlines at each power of
/// ten (0.1%, 1%, 10%) labelled under it, so the band reads without sentences. The rate sits over its tick, yours over a
/// gold tick; the counts go under it.
struct RateCard: View {
    var rate: DropRate, axis: RateAxis, caption: String, yours: Double?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { g in
                let w = g.size.width
                let x = { (v: Double) in CGFloat(axis.position(v)) * w }
                let at = { (v: Double) in min(max(x(v), 18), w - 18) }   // labels stay inside the card
                let (rateAt, yoursAt) = RateAxis.apart(Double(x(rate.rate)), yours.map { Double(x($0)) }, width: Double(w))
                ZStack(alignment: .topLeading) {
                    Capsule().fill(Color.white.opacity(0.1)).frame(width: w, height: 10).position(x: w / 2, y: 28)
                    ForEach(axis.decades, id: \.self) { d in
                        Rectangle().fill(Color.white.opacity(0.25)).frame(width: 1, height: 16).position(x: x(d), y: 28)
                        Text(DropRate.percent(d)).position(x: at(d), y: 48)
                    }
                    Capsule().fill(Color.accentColor.opacity(0.6)).frame(width: max(x(rate.range.upperBound) - x(rate.range.lowerBound), 4), height: 10)
                        .position(x: (x(rate.range.lowerBound) + x(rate.range.upperBound)) / 2, y: 28)
                    if rate.count > 0 {
                        tick(.primary).position(x: x(rate.rate), y: 28)
                        Text(rate.percent).font(.callout.weight(.semibold)).foregroundStyle(.primary).position(x: rateAt, y: 8)
                    }
                    if let yours {
                        tick(lootGold).position(x: x(yours), y: 28)
                        Text(DropRate.percent(yours)).font(.callout.weight(.semibold)).foregroundStyle(lootGold)
                            .position(x: yoursAt, y: 8)
                    }
                }
                .font(.caption2).foregroundStyle(.tertiary)
            }
            .frame(height: 56)
            HStack {
                Label(caption, systemImage: "scope").lineLimit(1)
                Spacer(minLength: 8)
                if yours != nil { Label("your boosts", systemImage: "sparkles").foregroundStyle(lootGold) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
        .monospacedDigit().padding(14).frame(width: 320)
    }
    private func tick(_ color: Color) -> some View { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3, height: 20) }
}

/// The bar: a track, the 95% range as a band, the rate as a tick, yours as a gold tick, on `axis`.
struct RateBar: View {
    var rate: DropRate, axis: RateAxis, yours: Double?
    var body: some View {
        GeometryReader { g in
            let x = { (v: Double) in CGFloat(axis.position(v)) * g.size.width }
            let low = x(rate.range.lowerBound), high = x(rate.range.upperBound)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.1))
                Capsule().fill(Color.accentColor.opacity(0.55)).frame(width: max(high - low, 4)).offset(x: low)
                if rate.count > 0 { tick(.primary).offset(x: x(rate.rate) - 1) }
                if let yours { tick(lootGold).offset(x: x(yours) - 1) }
            }
        }
        .frame(height: 6)
    }
    private func tick(_ color: Color) -> some View { RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 2, height: 12) }
}

