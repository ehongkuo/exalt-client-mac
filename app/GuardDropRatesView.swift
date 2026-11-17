import AppKit
import SwiftUI

/// The Drop rates tab of the main window (issues #41, #45), from all the data kept (DropReport has every query):
/// dungeons on the left; the selected dungeon's drops in the middle, one row of item sprites per bag, filtered by a
/// mob when one is picked; the selected item's rates on the right.
final class DropRatesModel: ObservableObject {
    /// The main window shows the Drop rates tab instead of the Guard tab.
    @Published var shown = false
    @Published var dungeon: String?
    @Published var mob: DropReport.Mob?   // only this mob's drops
    @Published var item: Int?
    @Published var search = ""            // dungeons by name, or by an item they drop
    @Published private(set) var report = DropReport()
    @Published private(set) var health = CaptureHealth()
    @Published private(set) var sprites: [Int: CGImage] = [:]
    private var spritesAsked: Set<Int> = []

    func update(health: CaptureHealth) { if health != self.health { self.health = health } }
    func update(_ report: DropReport) {
        if report != self.report { self.report = report }
        // Sprites are cut once per type, off the main thread, as new mobs and items show up.
        let wanted = report.textures.filter { !spritesAsked.contains($0.key) }
        guard !wanted.isEmpty else { return }
        spritesAsked.formUnion(wanted.keys)
        DispatchQueue.global(qos: .utility).async {
            let cut = GameSprites.load(assets: RealmHoundPaths.assets, wanted)
            DispatchQueue.main.async { self.sprites.merge(cut) { _, new in new } }
        }
    }
    func select(dungeon: String) { self.dungeon = dungeon; mob = nil }
}

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
        let h = model.health
        VStack(spacing: 0) {
            HStack {
                MainTabs(rates: model)
                Spacer()
                if let refused = h.refused { Text("Capture is off: \(refused)").foregroundStyle(.orange).lineLimit(1) }
                Text("\(h.kills.formatted()) kills · \(h.bags.formatted()) bags, \(h.linked.formatted()) linked to a kill · ")
                    + Text("\(h.lost.formatted()) records lost").foregroundColor(h.lost > 0 ? .orange : .secondary)
            }
            .font(.caption).foregroundStyle(.secondary).padding(8)
            .help("Capture health over all the data kept")
            Divider()
            HStack(spacing: 0) {
                dungeonList.frame(width: 240)
                Divider()
                Group {
                    if let dungeon { ScrollView { dropsPane(dungeon) } } else { empty("Dungeons show here once the game data is read.") }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                Divider()
                ScrollView {
                    if let dungeon, let item = model.item { itemPane(item, dungeon) } else if let dungeon { summaryPane(dungeon) }
                }
                .frame(width: 340)
            }
        }
        .frame(minWidth: 960, minHeight: 560)
        .background(Color(white: 0.12))
        .preferredColorScheme(.dark)
    }

    private var report: DropReport { model.report }
    private func kills(in dungeon: String) -> Int { report.mobs(in: dungeon).reduce(0) { $0 + report.kills[$1]! } }
    /// The picked dungeon, or the one with the most kills.
    private var dungeon: DropReport.Dungeon? {
        report.dungeons.first { $0.name == model.dungeon } ?? report.dungeons.max { kills(in: $0.name) < kills(in: $1.name) }
    }

    // MARK: Dungeons

    private var dungeonList: some View {
        let search = model.search.trimmingCharacters(in: .whitespaces)
        let items = search.isEmpty ? [] : Set(report.names.filter { $0.value.localizedCaseInsensitiveContains(search) }.keys)
        let shown = report.dungeons.compactMap { d -> (DropReport.Dungeon, [Int])? in
            if search.isEmpty || d.name.localizedCaseInsensitiveContains(search) { return (d, []) }
            let hits = report.possibleDrops(d).intersection(items)
            return hits.isEmpty ? nil : (d, hits.sorted { report.name($0) < report.name($1) })
        }
        .sorted { (kills(in: $0.0.name), $1.0.name) > (kills(in: $1.0.name), $0.0.name) }   // dungeons you played first
        return VStack(spacing: 0) {
            TextField("Search dungeons or items", text: $model.search).textFieldStyle(.roundedBorder).padding(8)
            List(shown, id: \.0.name) { d, hits in
                let n = kills(in: d.name)
                listRow(dungeon?.name == d.name, { model.select(dungeon: d.name); if let hit = hits.first { model.item = hit } }) {
                    SpriteIcon(image: d.portal.flatMap { model.sprites[$0] }, size: 24)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(d.name).lineLimit(1)
                        if !hits.isEmpty { Text(hits.map(report.name).joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                    }
                    Spacer()
                    if n > 0 { Text(n.formatted()).monospacedDigit().foregroundStyle(.secondary) }
                }
                .opacity(n > 0 ? 1 : 0.5)
            }
        }
    }

    // MARK: Bags and drops

    private func dropsPane(_ d: DropReport.Dungeon) -> some View {
        let mobs = report.mobs(in: d.name)
        let runs = report.runs[d.name] ?? 0
        let dropped = Set(mobs.flatMap { (report.copies[$0] ?? [:]).keys })
        let shown = model.mob.map { Set((report.copies[$0] ?? [:]).keys) } ?? report.possibleDrops(d)
        let rows = Dictionary(grouping: shown) { report.bag($0) }
        return VStack(alignment: .leading, spacing: 12) {
            header(d.name, "\(runs.formatted()) runs since capture started · \(kills(in: d.name).formatted()) kills across \(mobs.count) mob types")
            if !mobs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    mobStrip("BOSSES", mobs.filter { report.bosses.contains($0.type) })
                    mobStrip("MINIONS", mobs.filter { !report.bosses.contains($0.type) })
                    if let mob = model.mob {
                        Text("Only drops from \(report.name(mob.type)). Click it again to show all.").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if shown.isEmpty { Text(model.mob == nil ? "No known drops yet." : "No drops from this mob yet.").foregroundStyle(.secondary) }
            ForEach(DropBag.allCases.reversed().map(Optional.some) + [nil], id: \.self) { bag in
                if let items = rows[bag] {
                    HStack(alignment: .top, spacing: 10) {
                        Group {
                            if let bag { BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 28).help(bag.name) }
                            else { Image(systemName: "questionmark.square.dashed").font(.system(size: 22)).foregroundStyle(.secondary).help("No bag in the game data") }
                        }
                        .frame(width: 36, height: 36)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 40, maximum: 40), spacing: 4)], alignment: .leading, spacing: 4) {
                            ForEach(items.sorted { (dropped.contains($0) ? 0 : 1, report.name($0)) < (dropped.contains($1) ? 0 : 1, report.name($1)) }, id: \.self) { item in
                                itemTile(item, dropped: dropped.contains(item))
                            }
                        }
                    }
                    Divider()
                }
            }
        }
        .padding(16)
    }

    private func mobStrip(_ title: String, _ mobs: [DropReport.Mob]) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).frame(width: 56, height: 32, alignment: .leading)
            if mobs.isEmpty { Text("None killed yet").font(.caption).foregroundStyle(.tertiary).frame(height: 32) }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 36, maximum: 36), spacing: 4)], alignment: .leading, spacing: 4) {
                ForEach(mobs, id: \.self) { mob in
                    Button { model.mob = model.mob == mob ? nil : mob } label: {
                        SpriteIcon(image: model.sprites[mob.type], size: 28).padding(3).background(tileBackground(model.mob == mob))
                    }
                    .buttonStyle(.plain).help("\(report.name(mob.type)) · \(report.kills[mob]!.formatted()) kills")
                }
            }
        }
    }

    private func itemTile(_ item: Int, dropped: Bool) -> some View {
        Button { model.item = model.item == item ? nil : item } label: {
            SpriteIcon(image: model.sprites[item], size: 32).opacity(dropped ? 1 : 0.35).padding(4).background(tileBackground(model.item == item))
        }
        .buttonStyle(.plain)
        .help(report.name(item) + (dropped ? "" : " · not dropped here yet"))
    }

    private func tileBackground(_ selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(selected ? 0.12 : 0.04))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
    }

    // MARK: Item specifics

    private func itemPane(_ item: Int, _ d: DropReport.Dungeon) -> some View {
        let mobs = report.mobs(in: d.name).filter { (report.copies[$0]?[item] ?? 0) > 0 }
        let here = mobs.reduce(0) { $0 + report.copies[$1]![item]! }
        let runs = report.runs[d.name] ?? 0
        let counts = report.rarity.filter { $0.key.dungeon == d.name }.compactMap { $0.value[item] }.reduce([0, 0, 0, 0, 0]) { zip($0, $1).map(+) }
        let elsewhere = Set(report.copies.filter { $0.key.dungeon != d.name && ($0.value[item] ?? 0) > 0 }.keys.map(\.dungeon)).sorted()
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SpriteIcon(image: model.sprites[item], size: 40).overlay(alignment: .bottomTrailing) { gems(report.bestEnchants(item, dungeon: d.name), 8) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.name(item)).font(.title3.weight(.semibold))
                    Text((report.bag(item).map { "\($0.name) · " } ?? "") + "\(here.formatted()) dropped here").foregroundStyle(.secondary)
                }
            }
            if runs > 0 {
                section("PER RUN · runs with at least one") {
                    row { RateView(rate: .init(count: report.runsWith[d.name]?[item] ?? 0, of: runs), unit: "runs") }
                }
            }
            ForEach([("BOSSES", true), ("MINIONS", false)], id: \.0) { title, boss in
                let list = mobs.filter { report.bosses.contains($0.type) == boss }
                if !list.isEmpty {
                    section("\(title) · copies per kill") {
                        ForEach(list, id: \.self) { mob in
                            VStack(alignment: .leading, spacing: 4) {
                                mobLabel(mob.type)
                                RateView(rate: .init(count: report.copies[mob]![item]!, of: report.kills[mob]!), unit: "kills")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                        }
                    }
                }
            }
            if mobs.isEmpty { Text("None dropped here yet.").foregroundStyle(.secondary) }
            if here > 0 {
                section("RARITY OF THE COPIES YOU GOT HERE") {
                    VStack(alignment: .leading, spacing: 8) {
                        RarityBar(counts: counts, total: here)
                        RarityLegend(counts: counts, total: here)
                    }
                    .padding(12)
                }
            }
            if !elsewhere.isEmpty {
                section("ALSO DROPPED IN") {
                    ForEach(elsewhere, id: \.self) { other in
                        clickRow({ model.select(dungeon: other) }) { Text(other); Spacer(); Image(systemName: "chevron.right").foregroundStyle(.tertiary) }
                    }
                }
            }
        }
        .padding(16)
    }

    /// With no item picked: the picked mob's best bag per kill, or the bosses' best bag per run.
    @ViewBuilder private func summaryPane(_ d: DropReport.Dungeon) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            if let mob = model.mob {
                let kills = report.kills[mob] ?? 0, bags = report.bestBag[mob] ?? [:]
                HStack(spacing: 10) {
                    SpriteIcon(image: model.sprites[mob.type], size: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack { Text(report.name(mob.type)).font(.title3.weight(.semibold)); if report.bosses.contains(mob.type) { bossTag } }
                        Text("\(kills.formatted()) kills · \((report.maxHP[mob] ?? 0).formatted()) HP").foregroundStyle(.secondary)
                    }
                }
                section("BEST BAG PER KILL") {
                    if bags.isEmpty { row { Text("No bags yet.").foregroundStyle(.secondary) } }
                    ForEach(sortedBags(bags), id: \.self) { bag in
                        VStack(alignment: .leading, spacing: 4) { bagLabel(bag); RateView(rate: .init(count: bags[bag]!, of: kills), unit: "kills") }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            } else if let bosses = report.bossBags[d.name], let runs = report.runs[d.name] {
                section("BEST BAG FROM THE BOSSES, PER RUN") {
                    ForEach(sortedBags(bosses[nil] ?? [:]), id: \.self) { bag in
                        VStack(alignment: .leading, spacing: 4) { bagLabel(bag); RateView(rate: .init(count: bosses[nil]![bag]!, of: runs), unit: "runs") }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                    }
                }
            }
            Text("Click an item for its rates, or a mob for only its drops.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
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
    private func bagLabel(_ bag: DropBag) -> some View {
        HStack(spacing: 6) { BagIcon(bag: bag, sprite: drops.bagSprites[bag], size: 16); Text(bag.name) }
    }
    /// Best colour first.
    private func sortedBags(_ bags: [DropBag: Int]) -> [DropBag] { DropBag.allCases.reversed().filter { bags[$0] != nil } }
}

/// Copies by rarity as one bar, in the rarity gems' colours; copies with no rarity (potions and other items without
/// enchantments, or a cut-short stat) are the faint rest.
struct RarityBar: View {
    var counts: [Int]   // by DropRarity
    var total: Int
    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                ForEach(counts.indices, id: \.self) { i in
                    if counts[i] > 0 { RarityGems.colors[i].frame(width: geo.size.width * CGFloat(counts[i]) / CGFloat(max(total, 1))) }
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: 8).background(Color.white.opacity(0.1)).clipShape(Capsule())
        .help(DropRarity.allCases.map { "\($0.name) \(counts[$0.rawValue])" }.joined(separator: ", ") + ", no rarity \(total - counts.reduce(0, +))")
    }
}

/// The rarity colours, with counts when given.
struct RarityLegend: View {
    var counts: [Int]? = nil
    var total = 0
    var body: some View {
        HStack(spacing: 12) {
            ForEach(DropRarity.allCases, id: \.self) { r in
                HStack(spacing: 4) {
                    Circle().fill(RarityGems.colors[r.rawValue]).frame(width: 8, height: 8)
                    Text(r.name + (counts.map { " \($0[r.rawValue])" } ?? ""))
                }
            }
            HStack(spacing: 4) {
                Circle().fill(Color.white.opacity(0.1)).frame(width: 8, height: 8)
                Text("No rarity" + (counts.map { " \(total - $0.reduce(0, +))" } ?? ""))
            }
        }
        .font(.caption).foregroundStyle(.secondary).padding(.leading, 4)
    }
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
