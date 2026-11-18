import AppKit
import SwiftUI

/// The Drop rates tab's views; `DropRatesModel` (in GuardDropRates.swift) holds what is picked.

/// Guard | Drop rates, at the top of the main window in both tabs. An orange dot: capture is off.
struct MainTabs: View {
    @ObservedObject var rates: DropRatesModel
    var body: some View {
        HStack(spacing: 2) {
            tab("Guard", selected: !rates.shown) { rates.shown = false }
            tab("Drop rates", selected: rates.shown, warning: rates.health.refused != nil) { rates.shown = true }
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

struct DropRatesView: View {
    @ObservedObject var model: DropRatesModel
    @ObservedObject var drops: DropAlerts   // bag sprites

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            if let problem = model.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    .padding(10).frame(maxWidth: .infinity, alignment: .leading).background(Color.orange.opacity(0.1))
                Divider()
            }
            HSplitView {
                dungeonList.frame(minWidth: 180, idealWidth: 240, maxWidth: 420)
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if model.health.kills == 0 { welcome }
                        if let dungeon { dropsPane(dungeon) }
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
    private func kills(in dungeon: String) -> Int { report.mobs(in: dungeon).reduce(0) { $0 + report.kills[$1]! } }
    /// The picked dungeon, or the one with the most kills.
    private var dungeon: DropReport.Dungeon? {
        report.dungeons.first { $0.name == model.dungeon } ?? report.dungeons.max { kills(in: $0.name) < kills(in: $1.name) }
    }

    // MARK: Top bar

    private var topBar: some View {
        let h = model.health
        return HStack(spacing: 8) {
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

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("No drops recorded yet").font(.headline)
            Text("Start the game from the Guard tab. Every kill and bag you see is recorded here, and rates appear as your runs add up.")
            Text("Rates show “1 in N · ±X%”: ±X% is how far off they may still be. The ⓘ next to them explains more.").foregroundStyle(.secondary)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(0.12)).clipShape(RoundedRectangle(cornerRadius: 8))
    }

    // MARK: Dungeons and search

    private var dungeonList: some View {
        let q = model.search.trimmingCharacters(in: .whitespaces)
        let dungeons = q.isEmpty ? report.dungeons : report.dungeons.filter { $0.name.localizedCaseInsensitiveContains(q) }
        let sorted = dungeons.sorted { (kills(in: $0.name), $1.name) > (kills(in: $1.name), $0.name) }   // dungeons you played first
        let rows = model.stable("dungeons", sorted) { kills(in: $0.name) }
        let items = q.isEmpty ? [] : Array(Set(Set(report.origins.keys).union(report.items).map(report.base))
            .filter { report.name($0).localizedCaseInsensitiveContains(q) }.sorted { report.name($0) < report.name($1) }.prefix(30))
        return VStack(spacing: 0) {
            TextField("Search items or dungeons", text: $model.search).textFieldStyle(.roundedBorder).padding(8)
            List {
                if !q.isEmpty && items.isEmpty && rows.isEmpty {
                    Text("Nothing matches “\(q)”.").foregroundStyle(.secondary)
                }
                if !items.isEmpty {
                    Section("Items") {
                        ForEach(items, id: \.self) { item in
                            listRow(model.item == item, { model.group = nil; model.item = item }) {
                                SpriteIcon(image: model.sprites[item], size: 24)
                                Text(report.name(item)).lineLimit(1).help(report.name(item))
                            }
                        }
                    }
                }
                Section("Dungeons") {
                    ForEach(rows, id: \.row.name) { d, grew in
                        let n = kills(in: d.name)
                        listRow(dungeon?.name == d.name, { model.select(dungeon: d.name) }) {
                            SpriteIcon(image: d.portal.flatMap { model.sprites[$0] }, size: 24)
                            Text(d.name).lineLimit(1).help(d.name)
                            Spacer()
                            if grew { newMark }
                            if n > 0 { Text(n.formatted()).monospacedDigit().foregroundStyle(.secondary) }
                        }
                        .opacity(n > 0 ? 1 : 0.5)
                        .accessibilityLabel("\(d.name), \(n) kills")
                    }
                }
            }
        }
    }

    // MARK: Bags and drops

    private func dropsPane(_ d: DropReport.Dungeon) -> some View {
        let mobs = report.mobs(in: d.name)
        let runs = report.runs[d.name] ?? 0
        let dropped = Set(mobs.flatMap { (report.copies[$0] ?? [:]).keys })
        let shown = report.possibleDrops(d)
        let rows = report.tiles(shown)
        return VStack(alignment: .leading, spacing: 12) {
            breadcrumb(d)
            Text("\(runs.formatted()) runs · \(kills(in: d.name).formatted()) kills across \(mobs.count) mob types").foregroundStyle(.secondary)
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
                            ForEach(tiles, id: \.self) { tile in tileView(tile, d, dropped: dropped) }
                        }
                    }
                    Divider()
                }
            }
        }
    }

    /// Dungeon › mob › group › item; each part steps back to it.
    private func breadcrumb(_ d: DropReport.Dungeon) -> some View {
        HStack(spacing: 6) {
            Button { model.mob = nil; model.group = nil; model.item = nil } label: { Text(d.name).font(.title3.weight(.semibold)) }
                .buttonStyle(.plain)
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
                let boss = report.bosses.contains(mob.type), name = report.name(mob.type), n = report.kills[mob]!
                chip(selected: model.mob == mob, { model.pick(mob: mob) }) {
                    SpriteIcon(image: model.sprites[mob.type], size: 20)
                    Text(name).lineLimit(1)
                }
                .help("\(name) · \(n.formatted()) kills")
                .accessibilityLabel("\(name)\(boss ? ", boss" : ""), \(n) kills")
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

    @ViewBuilder private func tileView(_ tile: DropReport.Tile, _ d: DropReport.Dungeon, dropped: Set<Int>) -> some View {
        let anyDropped = tile.items.contains { report.variants($0).contains(where: dropped.contains) }
        switch tile {
        case .item(let item):
            let name = report.name(item), shiny = report.variants(item).count > 1
            Button { model.group = nil; model.item = model.item == item ? nil : item } label: {
                SpriteIcon(image: model.sprites[item], size: 32).opacity(anyDropped ? 1 : 0.35).padding(4)
                    .background(tileBackground(model.item == item && model.group == nil))
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
                    .background(tileBackground(model.group == group && model.item == nil))
            }
            .buttonStyle(.plain)
            .help("\(group.name): \(items.map(report.name).joined(separator: ", "))")
            .accessibilityLabel("\(group.name), \(items.count) items" + (anyDropped ? "" : ", none dropped here yet"))
        }
    }


    // MARK: Right pane

    @ViewBuilder private var rightPane: some View {
        if let item = model.item { itemPane(report.base(item)) }
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
                        if runs > 0 { RateView(rate: .init(count: report.runsWith(d.name, report.variants(item)), of: runs), unit: "runs", compact: true) }
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
        let types = report.variants(item), shinies = types.subtracting([item])
        let sources = model.stable("sources", report.sources(types)) { $0.runsWith + $0.mobs.values.reduce(0, +) }
        let total = types.reduce(0) { $0 + report.dropped($1) }
        let possible = report.dungeons.filter { report.possibleDrops($0).contains(item) }.map(\.name)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                SpriteIcon(image: model.sprites[item], size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(report.name(item)).font(.title3.weight(.semibold)).lineLimit(2)
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
                    ForEach(sources, id: \.row.dungeon) { entry in sourceBox(entry.row, grew: entry.grew) }
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
    private func sourceBox(_ s: DropReport.Source, grew: Bool) -> some View {
        let mobs = s.mobs.sorted {
            DropRate(count: $0.value, of: report.kills[$0.key] ?? 0).range.lowerBound > DropRate(count: $1.value, of: report.kills[$1.key] ?? 0).range.lowerBound
        }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button { model.select(dungeon: s.dungeon, keepItem: true) } label: {
                    Text(s.dungeon).fontWeight(.semibold).lineLimit(1)
                }
                .buttonStyle(.plain).help("Show \(s.dungeon)")
                if grew { newMark }
                Spacer()
                if let perRun = s.perRun { RateView(rate: perRun, unit: "runs", compact: true) }
                else { Text("no runs: no boss died here").font(.caption).foregroundStyle(.secondary) }
                rateInfo(s.dungeon)
            }
            ForEach(mobs, id: \.key) { mob, n in
                HStack(spacing: 6) {
                    SpriteIcon(image: model.sprites[mob.type], size: 20)
                    Text(report.name(mob.type)).lineLimit(1).help(report.name(mob.type))
                    Spacer()
                    RateView(rate: .init(count: n, of: report.kills[mob] ?? 0), unit: "kills", compact: true)
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
                    Image(systemName: "sparkles").font(.system(size: 11)).foregroundStyle(.yellow).offset(x: 5, y: -5)
                }
                .help(report.name(shiny))
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("per run").font(.caption).foregroundStyle(.secondary)
                        if runs > 0 { RateView(rate: .init(count: shinyRuns, of: runs), unit: "runs", compact: true) } else { Text("no runs yet").font(.caption) }
                        rateInfo("shiny")
                    }
                    HStack(spacing: 6) {
                        Text("of drops").font(.caption).foregroundStyle(.secondary)
                        RateView(rate: .init(count: shinyCopies, of: copies), unit: "drops", compact: true)
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
            Text(d.name).font(.title3.weight(.semibold))
            if let bosses = report.bossBags[d.name], let runs = report.runs[d.name] {
                section("BEST BAG FROM THE BOSSES, PER RUN") {
                    ForEach(sortedBags(bosses[nil] ?? [:]), id: \.self) { bag in
                        row { bagLabel(bag); Spacer(); RateView(rate: .init(count: bosses[nil]![bag]!, of: runs), unit: "runs", compact: true) }
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
        Button(action: action) { HStack(spacing: 6) { content() }.contentShape(Rectangle()) }
            .buttonStyle(.plain)
            .listRowBackground(selected ? Color.accentColor.opacity(0.25) : Color.clear)
    }
    /// ⓘ: how to read a rate, in one place.
    private func rateInfo(_ key: String) -> some View {
        Button { model.rateHelp = model.rateHelp == key ? nil : key } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain).foregroundStyle(.secondary).help("How to read a rate").accessibilityLabel("How to read a rate")
            .popover(isPresented: Binding(get: { model.rateHelp == key }, set: { if !$0, model.rateHelp == key { model.rateHelp = nil } }), arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("How to read a rate").font(.headline)
                    Text("**1 in 20** is your rate so far: drops ÷ runs (or kills, for a mob).")
                    Text("**±44%** is how far off it may still be, at 95% confidence. It's about 2 ÷ √drops, so it narrows as drops add up: ±44% at 20 drops, ±20% at 100, ±10% at 400.")
                    Text("**Too few drops**: under 4 drops, the rate is a rough guess. Faded rates are looser than ±50%.")
                    Text("**Rarer than 1 in 22**: none yet in that many runs, so the rate is probably below that.")
                    Text("**Per run** counts runs where a boss died with at least one copy. **Surest first** sorts by the low end of each range, so a lucky early drop doesn't come out on top.")
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

/// A mob's page (issue #50), laid out like the dungeon's grid: a row per bag with the bag's total, then a cell per
/// item or tier group with its drop chance per kill, drops/kills and ±. A group opens a row of the items it dropped;
/// an item opens its item page.
struct MobPage: View {
    @ObservedObject var model: DropRatesModel
    var mob: DropReport.Mob
    var bagSprites: [DropBag: CGImage]

    var body: some View {
        let report = model.report, kills = report.kills[mob] ?? 0, runs = report.runs[mob.dungeon] ?? 0
        let tiles = report.tiles(of: mob)
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
            Text("DROPS · per kill").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            if tiles.isEmpty { Text("No drops from this mob yet.").foregroundStyle(.secondary) }
            ForEach(DropBag.allCases.reversed().map(Optional.some) + [nil], id: \.self) { bag in
                if let row = tiles[bag] {
                    HStack(alignment: .top, spacing: 12) {
                        VStack(spacing: 2) {
                            Group {
                                if let bag { BagIcon(bag: bag, sprite: bagSprites[bag], size: 28).help(bag.name) }
                                else { Image(systemName: "questionmark.square.dashed").font(.system(size: 22)).foregroundStyle(.secondary).help("No bag in the game data") }
                            }
                            .frame(width: 36, height: 36)
                            numbers(report.killsWith(mob, row), of: kills, stacked: true)
                        }
                        .frame(width: 56)
                        // An open group's items follow its cell, marked as its members.
                        let cells = row.flatMap { tile -> [(tile: DropReport.Tile, member: Bool)] in
                            guard case .group(let group, let items) = tile, model.openGroups.contains(group) else { return [(tile, false)] }
                            return [(tile, false)] + items.filter { report.killsWith(mob, [.item($0)]) > 0 }.map { (.item($0), true) }
                        }
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6)], alignment: .leading, spacing: 6) {
                            ForEach(cells, id: \.tile) { cell($0.tile, member: $0.member, kills: kills) }
                        }
                    }
                    Divider()
                }
            }
            Text("Drop chance: the share of kills that dropped at least one. A tier group opens the items it dropped; an item opens its page. Esc steps back.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// An item or tier group: sprite (a group cycles its kinds, with its tier), name, drop chance, drops/kills · ±.
    private func cell(_ tile: DropReport.Tile, member: Bool, kills: Int) -> some View {
        let report = model.report, n = report.killsWith(mob, [tile])
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
                .frame(width: 32, height: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    numbers(n, of: kills, stacked: false)
                }
                Spacer(minLength: 0)
                if let open { Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption).foregroundStyle(.tertiary) }
            }
            .padding(6).frame(maxWidth: .infinity, alignment: .leading)
            .background(tileBackground(open == true))
            .overlay(alignment: .leading) { if member { Capsule().fill(Color.accentColor).frame(width: 3).padding(.vertical, 8) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(name): dropped in \(n.formatted()) of \(kills.formatted()) kills")
        .accessibilityLabel("\(name), \(DropRate(count: n, of: kills).percent) per kill")
    }

    /// "45%" over "9/20 · ±65%" ("too few" under 4 drops), faded when looser than ±50% as elsewhere in the tab.
    private func numbers(_ n: Int, of kills: Int, stacked: Bool) -> some View {
        let rate = DropRate(count: n, of: kills), counts = "\(n.formatted())/\(kills.formatted())", detail = rate.plusMinus ?? "too few"
        return VStack(alignment: stacked ? .center : .leading, spacing: 0) {
            Text(rate.percent).font(.system(size: 14, weight: .semibold))
            if stacked { Text(counts); Text(detail) } else { Text("\(counts) · \(detail)") }
        }
        .font(.caption2).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
        .opacity(rate.precision.map { $0 > 0.5 } ?? true ? 0.65 : 1)
    }

    private func pill(_ text: String) -> some View {
        Text(text).font(.caption).padding(.horizontal, 8).padding(.vertical, 2)
            .overlay(Capsule().stroke(Color.white.opacity(0.3), lineWidth: 1))
    }
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

/// "1 in 41 · ±44%" over "10 in 410 runs". Under 4 drops "too few drops" takes the ±'s place; with none, "rarer than
/// 1 in N" (the top of the 95% range). Rates looser than ±50% are faded. `compact` is one line, right-aligned.
struct RateView: View {
    var rate: DropRate
    var unit: String
    var compact = false

    var body: some View {
        let precision = rate.precision
        let main: Text = rate.count == 0 ? Text("rarer than \(DropRate.oneIn(rate.range.upperBound))") : Text(DropRate.oneIn(rate.rate))
        let detail = rate.plusMinus ?? (rate.count == 0 ? "" : "too few drops")
        let counts = "\(rate.count.formatted()) in \(rate.of.formatted()) \(unit)"
        Group {
            if rate.of == 0 {
                Text("no \(unit) yet").font(.caption).foregroundStyle(.secondary)
            } else if compact {
                HStack(spacing: 6) {
                    main.fontWeight(.semibold)
                    Text(detail.isEmpty ? counts : detail).font(.caption).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) { main.fontWeight(.semibold); Text(detail).foregroundStyle(.secondary) }
                    Text(counts).font(.caption).foregroundStyle(.secondary)
                }
                .monospacedDigit()
            }
        }
        .opacity(precision.map { $0 > 0.5 } ?? true ? 0.65 : 1)
        .help(rate.of == 0 ? "" : "\(counts). 95% range: \(DropRate.oneIn(rate.range.upperBound)) to \(rate.count == 0 ? "never" : DropRate.oneIn(rate.range.lowerBound)).")
    }
}
