import AppKit
import SwiftUI

/// The Drop rates window (issue #41), laid out as docs/drop-rates-mockup.html. Today shows today's kills;
/// the other tabs use all the data kept (DropReport has every query).
final class DropRatesModel: ObservableObject {
    enum Tab: String, CaseIterable { case today = "Today", mobs = "Mobs", items = "Items", dungeons = "Dungeons" }
    @Published var tab = Tab.today
    @Published var mob: DropReport.Mob?
    @Published var item: Int?
    @Published var dungeon: String?
    @Published var search = ""   // the Items tab's filter
    @Published private(set) var report = DropReport()
    @Published private(set) var day = DropDay()
    @Published private(set) var sprites: [Int: CGImage] = [:]
    private var spritesAsked: Set<Int> = []

    func update(_ report: DropReport, day: DropDay) {
        if report != self.report { self.report = report }
        if day != self.day { self.day = day }
        // Sprites are cut once per type, off the main thread, as new mobs and items show up.
        let wanted = report.textures.filter { !spritesAsked.contains($0.key) }
        guard !wanted.isEmpty else { return }
        spritesAsked.formUnion(wanted.keys)
        DispatchQueue.global(qos: .utility).async {
            let cut = GameSprites.load(assets: RealmHoundPaths.assets, wanted)
            DispatchQueue.main.async { self.sprites.merge(cut) { _, new in new } }
        }
    }
    func show(mob: DropReport.Mob) { self.mob = mob; tab = .mobs }
    func show(item: Int) { self.item = item; tab = .items }
}

struct DropRatesView: View {
    @ObservedObject var model: DropRatesModel
    @ObservedObject var drops: DropAlerts   // bag sprites

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(DropRatesModel.Tab.allCases, id: \.self) { tab in
                    Button { model.tab = tab } label: {
                        HStack {
                            Text(tab.rawValue)
                            Spacer()
                            Text(count(tab)).font(.caption).foregroundStyle(model.tab == tab ? .white.opacity(0.75) : .secondary)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6).contentShape(Rectangle())
                        .background(model.tab == tab ? Color.accentColor : .clear)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .foregroundStyle(model.tab == tab ? .white : .primary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(8).frame(width: 170)
            Divider()
            Group {
                switch model.tab {
                case .today: today
                case .mobs: mobs
                case .items: items
                case .dungeons: dungeons
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(minWidth: 820, minHeight: 560)
        .background(Color(white: 0.12))
        .preferredColorScheme(.dark)
    }

    private var report: DropReport { model.report }
    private func count(_ tab: DropRatesModel.Tab) -> String {
        switch tab {
        case .today: return model.day.kills.formatted()
        case .mobs: return report.kills.count.formatted()
        case .items: return report.items.count.formatted()
        case .dungeons: return report.dungeons.count.formatted()
        }
    }

    // MARK: Tabs

    private var today: some View {
        let day = model.day
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header("Today", "Kills of mobs you damaged since midnight, and the bags they left. Click a mob for its rates.")
                if let refused = day.refused { Text("Capture is off: \(refused)").foregroundStyle(.orange) }
                HStack(spacing: 1) {
                    stat(day.kills, "kills"); stat(day.bags, "bags"); stat(day.linked, "bags linked to a kill"); stat(day.lost, "records lost")
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                section("KILLS BY MOB · kills that left a bag of each colour") {
                    if day.mobs.isEmpty { row { Text("Kills of mobs you hit show here a few seconds after they happen.").foregroundStyle(.secondary) } }
                    ForEach(Array(Dictionary(grouping: day.mobs, by: \.map).sorted { $0.key < $1.key }), id: \.key) { map, mobs in
                        groupTitle(map.isEmpty ? "Unknown map" : map)
                        ForEach(mobs, id: \.self) { mob in
                            clickRow({ model.show(mob: .init(type: mob.type, dungeon: mob.map)) }) {
                                mobLabel(mob.type)
                                Spacer()
                                bagCounts(mob.bags)
                                Text(mob.kills.formatted()).monospacedDigit().frame(minWidth: 50, alignment: .trailing)
                            }
                        }
                    }
                }
                if !day.notable.isEmpty {
                    section("LATEST WHITE, ORANGE AND RED BAGS") {
                        ForEach(day.notable, id: \.self) { drop in
                            row {
                                BagIcon(bag: drop.bag, sprite: drops.bagSprites[drop.bag], size: 14)
                                ForEach(Array(drop.items.enumerated()), id: \.offset) { i, item in
                                    Button { model.show(item: item) } label: {
                                        itemLabel(item, enchants: i < drop.enchants.count ? drop.enchants[i] : nil, size: 24)
                                    }
                                    .buttonStyle(.plain)
                                }
                                Spacer()
                                Text(drop.mob.map(report.name) ?? "No kill").foregroundStyle(.secondary).lineLimit(1)
                                Text(Date(timeIntervalSince1970: drop.time).formatted(date: .omitted, time: .shortened))
                                    .monospacedDigit().foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
    }

    private var mobs: some View {
        let selected = model.mob ?? report.kills.keys.max { (report.kills[$0]!, $1.type) < (report.kills[$1]!, $0.type) }
        return HStack(spacing: 0) {
            List {
                ForEach(Array(Dictionary(grouping: report.kills.keys, by: \.dungeon).sorted { $0.key < $1.key }), id: \.key) { dungeon, mobs in
                    Section(dungeon.isEmpty ? "Unknown map" : dungeon) {
                        ForEach(mobs.sorted { report.name($0.type) < report.name($1.type) }, id: \.self) { mob in
                            listRow(selected == mob, { model.mob = mob }) {
                                mobLabel(mob.type); Spacer(); Text((report.kills[mob] ?? 0).formatted()).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .frame(width: 260)
            Divider()
            ScrollView {
                if let mob = selected {
                    let kills = report.kills[mob] ?? 0
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            SpriteIcon(image: model.sprites[mob.type], size: 40)
                            VStack(alignment: .leading, spacing: 2) {
                                HStack { Text(report.name(mob.type)).font(.title3.weight(.semibold)); if report.bosses.contains(mob.type) { bossTag } }
                                Text("\(mob.dungeon) · \(kills.formatted()) kills since capture started · \((report.maxHP[mob] ?? 0).formatted()) HP")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        section("BEST BAG PER KILL") {
                            let bags = report.bestBag[mob] ?? [:]
                            if bags.isEmpty { row { Text("No bags yet.").foregroundStyle(.secondary) } }
                            ForEach(sortedBags(bags), id: \.self) { bag in
                                row { bagLabel(bag); Spacer(); RateView(rate: .init(count: bags[bag]!, of: kills), unit: "kills") }
                            }
                        }
                        section("ITEMS · copies per kill; a double drop counts twice") {
                            let copies = report.copies[mob] ?? [:]
                            ForEach(copies.keys.sorted { (copies[$0]!, $1) > (copies[$1]!, $0) }, id: \.self) { item in
                                clickRow({ model.show(item: item) }) {
                                    itemLabel(item, enchants: report.enchants[mob]?[item]); Spacer()
                                    RateView(rate: .init(count: copies[item]!, of: kills), unit: "kills")
                                }
                            }
                        }
                    }
                    .padding(20)
                } else {
                    empty("Kills of mobs you hit show here once they are imported.")
                }
            }
        }
    }

    private var items: some View {
        let all = report.items
        let shown = model.search.isEmpty ? all : all.filter { report.name($0).localizedCaseInsensitiveContains(model.search) }
        let selected = model.item ?? all.max { (report.dropped($0), $1) < (report.dropped($1), $0) }
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search an item", text: $model.search).textFieldStyle(.roundedBorder).padding(8)
                List(shown, id: \.self) { item in
                    listRow(selected == item, { model.item = item }) {
                        itemLabel(item, enchants: report.bestEnchants(item)); Spacer()
                        Text(report.dropped(item).formatted()).monospacedDigit().foregroundStyle(.secondary)
                    }
                }
            }
            .frame(width: 260)
            Divider()
            ScrollView {
                if let item = selected {
                    let sources = report.copies.filter { ($0.value[item] ?? 0) > 0 }.keys
                        .sorted { (report.copies[$0]![item]!, $1.type) > (report.copies[$1]![item]!, $0.type) }
                    let dungeons = Set(sources.map(\.dungeon)).filter { (report.runs[$0] ?? 0) > 0 }.sorted()
                    VStack(alignment: .leading, spacing: 16) {
                        HStack(spacing: 10) {
                            SpriteIcon(image: model.sprites[item], size: 40).overlay(alignment: .bottomTrailing) { gems(report.bestEnchants(item), 8) }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(report.name(item)).font(.title3.weight(.semibold))
                                Text((report.itemBag[item].map { "\($0.name) · " } ?? "") + "\(report.dropped(item).formatted()) dropped since capture started")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        section("PER KILL, BY MOB") {
                            ForEach(sources, id: \.self) { mob in
                                clickRow({ model.show(mob: mob) }) {
                                    VStack(alignment: .leading, spacing: 1) {
                                        mobLabel(mob.type)
                                        Text(mob.dungeon).font(.caption).foregroundStyle(.secondary).padding(.leading, 26)
                                    }
                                    Spacer()
                                    RateView(rate: .init(count: report.copies[mob]![item]!, of: report.kills[mob] ?? 0), unit: "kills")
                                }
                            }
                        }
                        if !dungeons.isEmpty {
                            section("PER RUN · runs with at least one; a run is one visit where a boss died") {
                                ForEach(dungeons, id: \.self) { dungeon in
                                    row {
                                        Text(dungeon); Spacer()
                                        RateView(rate: .init(count: report.runsWith[dungeon]?[item] ?? 0, of: report.runs[dungeon] ?? 0), unit: "runs")
                                    }
                                }
                            }
                        }
                    }
                    .padding(20)
                } else {
                    empty("Items show here once a kill of yours leaves a bag.")
                }
            }
        }
    }

    private var dungeons: some View {
        let list = report.dungeons
        let dungeon = model.dungeon.flatMap { list.contains($0) ? $0 : nil } ?? list.first
        return ScrollView {
            if let dungeon {
                let runs = report.runs[dungeon] ?? 0
                let mobs = report.kills.filter { $0.key.dungeon == dungeon }
                let bosses = report.bossBags[dungeon] ?? [:]
                let notable: [DropBag] = [.white, .red, .orange]
                let runItems = (report.runsWith[dungeon] ?? [:]).filter { report.itemBag[$0.key].map(notable.contains) ?? false }
                VStack(alignment: .leading, spacing: 16) {
                    Picker("Dungeon", selection: Binding(get: { dungeon }, set: { model.dungeon = $0 })) {
                        ForEach(list, id: \.self) { Text($0) }
                    }
                    .frame(maxWidth: 320)
                    header(dungeon, "\(runs.formatted()) runs since capture started · \(mobs.values.reduce(0, +).formatted()) kills across \(mobs.count) mob types")
                    section("BEST BAG FROM BOSSES, PER RUN") {
                        ForEach(bosses.keys.sorted { a, b in a == nil || (b != nil && report.name(a!) < report.name(b!)) }, id: \.self) { boss in
                            let bags = bosses[boss]!
                            if let boss { groupTitle(report.name(boss)) } else { groupTitle("Any boss: the best bag of the run") }
                            ForEach(sortedBags(bags), id: \.self) { bag in
                                row { bagLabel(bag); Spacer(); RateView(rate: .init(count: bags[bag]!, of: runs), unit: "runs") }
                            }
                        }
                    }
                    section("ITEMS PER RUN · white, red and orange bag items; runs with at least one") {
                        if runItems.isEmpty { row { Text("No white, red or orange bag items yet.").foregroundStyle(.secondary) } }
                        ForEach(runItems.keys.sorted { (runItems[$0]!, $1) > (runItems[$1]!, $0) }, id: \.self) { item in
                            clickRow({ model.show(item: item) }) {
                                itemLabel(item, enchants: report.bestEnchants(item, dungeon: dungeon)); Spacer()
                                RateView(rate: .init(count: runItems[item]!, of: runs), unit: "runs")
                            }
                        }
                    }
                }
                .padding(20)
            } else {
                empty("A dungeon shows here once you kill its boss.")
            }
        }
    }

    // MARK: Pieces

    private func header(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.title3.weight(.semibold))
            Text(detail).foregroundStyle(.secondary)
        }
    }
    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).padding(20).frame(maxWidth: .infinity, alignment: .leading)
    }
    private func stat(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value.formatted()).font(.title2.weight(.semibold)).monospacedDigit()
            Text(label).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.white.opacity(0.05))
    }
    private func section<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).padding(.leading, 4)
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
    private func groupTitle(_ text: String) -> some View {
        Text(text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.top, 10)
    }
    private var bossTag: some View {
        Text("BOSS").font(.system(size: 9, weight: .semibold)).foregroundStyle(.orange)
            .padding(.horizontal, 4).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.orange.opacity(0.5)))
    }
    private func mobLabel(_ type: Int) -> some View {
        HStack(spacing: 6) {
            SpriteIcon(image: model.sprites[type], size: 20)
            Text(report.name(type)).lineLimit(1)
            if report.bosses.contains(type) { bossTag }
        }
    }
    /// The game's rarity gems for a copy's enchantments; in a row for an item type, its best copy's.
    @ViewBuilder private func gems(_ enchants: Int?, _ size: CGFloat) -> some View {
        if let enchants, enchants > 0 {
            RarityGems(rarity: DropRarity(enchants: enchants), gem: size).offset(x: 2, y: 2)
                .help("\(DropRarity(enchants: enchants).name): \(enchants) enchantment\(enchants == 1 ? "" : "s")")
        }
    }
    /// An item's sprite and name, with the rarity gems of the copy (or best copy) on the sprite.
    private func itemLabel(_ type: Int, enchants: Int? = nil, size: CGFloat = 20) -> some View {
        HStack(spacing: 6) {
            SpriteIcon(image: model.sprites[type], size: size).overlay(alignment: .bottomTrailing) { gems(enchants, 6) }
            Text(report.name(type)).lineLimit(1)
        }
    }
    private func bagLabel(_ bag: DropBag) -> some View {
        HStack(spacing: 6) { BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 16); Text(bag.name) }
    }
    private func bagCounts(_ bags: [DropBag: Int]) -> some View {
        HStack(spacing: 8) {
            ForEach(sortedBags(bags), id: \.self) { bag in
                HStack(spacing: 3) {
                    BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 12)
                    Text(bags[bag]!.formatted()).monospacedDigit().foregroundStyle(.secondary)
                }
            }
        }
    }
    /// Best colour first.
    private func sortedBags(_ bags: [DropBag: Int]) -> [DropBag] { DropBag.allCases.reversed().filter { bags[$0] != nil } }
}

/// A game sprite, pixel-sharp; blank space when RealmHound's art is missing, so names stay aligned.
struct SpriteIcon: View {
    var image: CGImage?
    var size: CGFloat
    var body: some View {
        if let image {
            Image(decorative: image, scale: 1).interpolation(.none).resizable().aspectRatio(contentMode: .fit).frame(width: size, height: size)
        } else {
            Color.clear.frame(width: size, height: size)
        }
    }
}

/// "1 in N" with a 95% range bar and the counts. The bar is on a log scale from 1 in 10,000 (left) to every
/// time (right): the tick is the rate, the band the range.
struct RateView: View {
    var rate: DropRate
    var unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if rate.of == 0 {
                Text("no \(unit) yet").font(.caption).foregroundStyle(.secondary)
            } else {
                let range = rate.range, p = rate.rate
                Text(DropRate.oneIn(p)).fontWeight(.semibold)
                GeometryReader { geo in
                    let w = geo.size.width, low = Self.position(range.lowerBound), high = Self.position(range.upperBound)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                        Capsule().fill(Color.accentColor.opacity(0.5)).frame(width: max((high - low) * w, 2), height: 6).offset(x: low * w)
                        if rate.count > 0 { Rectangle().fill(.white).frame(width: 2, height: 10).offset(x: Self.position(p) * w - 1) }
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 10)
                (Text("\(rate.count.formatted()) in \(rate.of.formatted()) \(unit) · ")
                 + Text(String(format: p < 0.01 ? "%.2f%%" : "%.1f%%", p * 100))
                 + Text(" · 95%: \(DropRate.oneIn(range.upperBound)) to \(DropRate.oneIn(range.lowerBound))")
                 + (rate.rough ? Text(" · rough").foregroundColor(.orange) : Text("")))
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 300, alignment: .leading)
        .help("95% range: \(String(format: "%.3f%%", rate.range.lowerBound * 100)) to \(String(format: "%.3f%%", rate.range.upperBound * 100))")
    }

    static func position(_ p: Double) -> CGFloat { p <= 0 ? 0 : CGFloat(min(max((log10(p) + 4) / 4, 0), 1)) }
}
