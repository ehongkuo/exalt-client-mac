import AppKit
import SwiftUI

/// The drop rates views of the main window (issues #41, #45), from all the data kept (DropReport has every query).
/// Mobs holds the dungeon pages (click a dungeon's name); Items is grouped by category; the sidebar shows capture health.
final class DropRatesModel: ObservableObject {
    enum Tab: String, CaseIterable { case mobs = "Mobs", items = "Items", ask = "Ask a question" }
    /// The main window shows these views instead of the guard's.
    @Published var shown = false
    @Published var tab = Tab.mobs
    @Published var question = DropQuestion.presets[0].1
    @Published var mob: DropReport.Mob?
    @Published var dungeon: String?           // the Mobs view shows this dungeon's page instead of a mob
    @Published var item: Int?
    @Published var category: ItemCategory?    // the Items view lists this category's items
    @Published var search = ""                // the Items view's filter, across categories
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
    func show(mob: DropReport.Mob) { self.mob = mob; dungeon = nil; tab = .mobs }
    func show(dungeon: String) { self.dungeon = dungeon; tab = .mobs }
    func show(item: Int) { self.item = item; category = report.category(item); search = ""; tab = .items }
    func show(category: ItemCategory) { self.category = category; item = nil; search = ""; tab = .items }
}

struct DropRatesView: View {
    @ObservedObject var model: DropRatesModel
    @ObservedObject var drops: DropAlerts   // bag sprites

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Button { model.shown = false } label: {
                    Label("Guard", systemImage: "chevron.left").padding(.horizontal, 10).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
                }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.bottom, 6)
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
                let h = model.health
                VStack(alignment: .leading, spacing: 3) {
                    if let refused = h.refused { Text("Capture is off: \(refused)").foregroundStyle(.orange) }
                    Text("\(h.kills.formatted()) kills · \(h.bags.formatted()) bags")
                    Text("\(h.linked.formatted()) bags linked to a kill")
                    Text("\(h.lost.formatted()) records lost").foregroundStyle(h.lost > 0 ? Color.orange : .secondary)
                }
                .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 10).padding(.bottom, 4)
                .help("Capture health over all the data kept")
            }
            .padding(8).frame(width: 170)
            Divider()
            Group {
                switch model.tab {
                case .mobs: mobs
                case .items: items
                case .ask: ask
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
        case .mobs: return report.kills.count.formatted()
        case .items: return report.items.count.formatted()
        case .ask: return ""
        }
    }

    // MARK: Views

    private var mobs: some View {
        let selected = model.mob ?? report.kills.keys.max { (report.kills[$0]!, $1.type) < (report.kills[$1]!, $0.type) }
        return HStack(spacing: 0) {
            List {
                ForEach(Array(Dictionary(grouping: report.kills.keys, by: \.dungeon).sorted { $0.key < $1.key }), id: \.key) { dungeon, mobs in
                    Section {
                        ForEach(mobs.sorted { report.name($0.type) < report.name($1.type) }, id: \.self) { mob in
                            listRow(model.dungeon == nil && selected == mob, { model.show(mob: mob) }) {
                                mobLabel(mob.type); Spacer(); Text((report.kills[mob] ?? 0).formatted()).monospacedDigit().foregroundStyle(.secondary)
                            }
                        }
                    } header: {
                        Button { model.show(dungeon: dungeon) } label: {
                            HStack {
                                Text(dungeon.isEmpty ? "Unknown map" : dungeon)
                                Spacer()
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(model.dungeon == dungeon ? Color.accentColor : .secondary)
                        .help("Open the dungeon's page")
                    }
                }
            }
            .frame(width: 260)
            Divider()
            ScrollView {
                if let dungeon = model.dungeon {
                    dungeonPage(dungeon)
                } else if let mob = selected {
                    mobPage(mob)
                } else {
                    empty("Kills of mobs you hit show here once they are imported.")
                }
            }
        }
    }

    private func mobPage(_ mob: DropReport.Mob) -> some View {
        let kills = report.kills[mob] ?? 0
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SpriteIcon(image: model.sprites[mob.type], size: 40)
                VStack(alignment: .leading, spacing: 2) {
                    HStack { Text(report.name(mob.type)).font(.title3.weight(.semibold)); if report.bosses.contains(mob.type) { bossTag } }
                    HStack(spacing: 0) {
                        Button(mob.dungeon) { model.show(dungeon: mob.dungeon) }.buttonStyle(.link)
                        Text(" · \(kills.formatted()) kills since capture started · \((report.maxHP[mob] ?? 0).formatted()) HP")
                    }
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
            section("ITEMS · copies per kill; a double drop counts twice · rarity of the copies") {
                let copies = report.copies[mob] ?? [:]
                ForEach(copies.keys.sorted { (copies[$0]!, $1) > (copies[$1]!, $0) }, id: \.self) { item in
                    clickRow({ model.show(item: item) }) {
                        itemLabel(item, enchants: report.bestEnchants(item, mob: mob)); Spacer()
                        RateView(rate: .init(count: copies[item]!, of: kills), unit: "kills")
                        RarityBar(counts: report.rarityCounts(item, mob: mob), total: copies[item]!).frame(width: 90)
                    }
                }
            }
            RarityLegend()
        }
        .padding(20)
    }

    /// A dungeon's page: its drop sources, the bosses' best bags per run, and its possible drops by category.
    private func dungeonPage(_ dungeon: String) -> some View {
        let runs = report.runs[dungeon] ?? 0
        let mobs = report.kills.keys.filter { $0.dungeon == dungeon }
            .sorted { (report.bosses.contains($0.type) ? 1 : 0, report.kills[$0]!) > (report.bosses.contains($1.type) ? 1 : 0, report.kills[$1]!) }
        let kills = mobs.reduce(0) { $0 + report.kills[$1]! }
        let bosses = report.bossBags[dungeon] ?? [:]
        let possible = Dictionary(grouping: report.possibleDrops(dungeon), by: report.category).sorted { $0.key < $1.key }
        let code = report.origin(of: dungeon)
        // Per run where the dungeon has runs; per kill in it otherwise.
        func rate(_ item: Int) -> RateView {
            runs > 0 ? RateView(rate: .init(count: report.runsWith[dungeon]?[item] ?? 0, of: runs), unit: "runs")
                : RateView(rate: .init(count: mobs.reduce(0) { $0 + (report.copies[$1]?[item] ?? 0) }, of: kills), unit: "kills")
        }
        return VStack(alignment: .leading, spacing: 16) {
            header(dungeon.isEmpty ? "Unknown map" : dungeon,
                   "\(runs.formatted()) runs since capture started · \(kills.formatted()) kills across \(mobs.count) mob types")
            section("DROP SOURCES · kills, and kills whose best bag was each colour") {
                ForEach(mobs, id: \.self) { mob in
                    clickRow({ model.show(mob: mob) }) {
                        mobLabel(mob.type); Spacer(); bagCounts(report.bestBag[mob] ?? [:])
                        Text(report.kills[mob]!.formatted()).monospacedDigit().frame(minWidth: 50, alignment: .trailing)
                    }
                }
            }
            if !bosses.isEmpty {
                section("BEST BAG FROM BOSSES, PER RUN") {
                    ForEach(bosses.keys.sorted { a, b in a == nil || (b != nil && report.name(a!) < report.name(b!)) }, id: \.self) { boss in
                        let bags = bosses[boss]!
                        if let boss { groupTitle(report.name(boss)) } else { groupTitle("Any boss: the best bag of the run") }
                        ForEach(sortedBags(bags), id: \.self) { bag in
                            row { bagLabel(bag); Spacer(); RateView(rate: .init(count: bags[bag]!, of: runs), unit: "runs") }
                        }
                    }
                }
            }
            section("POSSIBLE DROPS · " + (code.map { "tagged \($0) in the game data, or " } ?? "") + "dropped here; "
                    + (runs > 0 ? "runs with at least one" : "copies per kill")) {
                if possible.isEmpty { row { Text("No drops yet.").foregroundStyle(.secondary) } }
                ForEach(possible, id: \.key) { category, items in
                    Button { model.show(category: category) } label: {
                        HStack(spacing: 4) { Text(category.name); Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)) }
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.top, 10).contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).help("Open \(category.name) in Items")
                    ForEach(items, id: \.self) { item in
                        clickRow({ model.show(item: item) }) {
                            itemLabel(item, enchants: report.bestEnchants(item, dungeon: dungeon)); Spacer(); rate(item)
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private var items: some View {
        let all = report.items
        let categories = Dictionary(grouping: all, by: report.category)
        return HStack(spacing: 0) {
            VStack(spacing: 0) {
                TextField("Search an item", text: $model.search).textFieldStyle(.roundedBorder).padding(8)
                List {
                    if !model.search.isEmpty {
                        ForEach(all.filter { report.name($0).localizedCaseInsensitiveContains(model.search) }, id: \.self, content: itemRow)
                    } else if let category = model.category {
                        Button { model.category = nil; model.item = nil } label: {
                            Label("All categories", systemImage: "chevron.left").contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        Section(category.name) { ForEach(categories[category] ?? [], id: \.self, content: itemRow) }
                    } else {
                        ForEach(categories.keys.sorted(), id: \.self) { category in
                            listRow(false, { model.category = category }) {
                                Text(category.name); Spacer()
                                Text(categories[category]!.count.formatted()).monospacedDigit().foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                            }
                        }
                    }
                }
            }
            .frame(width: 260)
            Divider()
            ScrollView {
                if let item = model.item {
                    itemPage(item)
                } else {
                    empty(all.isEmpty ? "Items show here once a kill of yours leaves a bag."
                          : model.category == nil ? "Pick a category, then an item." : "Pick an item.")
                }
            }
        }
    }

    private func itemRow(_ item: Int) -> some View {
        listRow(model.item == item, { model.item = item }) {
            itemLabel(item, enchants: report.bestEnchants(item)); Spacer()
            Text(report.dropped(item).formatted()).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func itemPage(_ item: Int) -> some View {
        let sources = report.copies.filter { ($0.value[item] ?? 0) > 0 }.keys
            .sorted { (report.copies[$0]![item]!, $1.type) > (report.copies[$1]![item]!, $0.type) }
        let dungeons = Set(sources.map(\.dungeon)).filter { (report.runs[$0] ?? 0) > 0 }.sorted()
        return VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                SpriteIcon(image: model.sprites[item], size: 40).overlay(alignment: .bottomTrailing) { gems(report.bestEnchants(item), 8) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(report.name(item)).font(.title3.weight(.semibold))
                    Text("\(report.category(item).name) · " + (report.itemBag[item].map { "\($0.name) · " } ?? "")
                         + "\(report.dropped(item).formatted()) dropped since capture started")
                        .foregroundStyle(.secondary)
                }
            }
            section("PER KILL, BY MOB") {
                if sources.isEmpty { row { Text("None dropped yet.").foregroundStyle(.secondary) } }
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
            section("RARITY OF THE COPIES YOU GOT") {
                let counts = report.rarityCounts(item)
                VStack(alignment: .leading, spacing: 8) {
                    RarityBar(counts: counts, total: report.dropped(item))
                    RarityLegend(counts: counts, total: report.dropped(item))
                }
                .padding(12)
            }
            if !dungeons.isEmpty {
                section("PER RUN · runs with at least one; a run is one visit where a boss died") {
                    ForEach(dungeons, id: \.self) { dungeon in
                        clickRow({ model.show(dungeon: dungeon) }) {
                            Text(dungeon); Spacer()
                            RateView(rate: .init(count: report.runsWith[dungeon]?[item] ?? 0, of: report.runs[dungeon] ?? 0), unit: "runs")
                        }
                    }
                }
            }
        }
        .padding(20)
    }

    private var ask: some View {
        let q = model.question, answer = report.answer(q)
        let items = [DropQuestion.anyUT, DropQuestion.anySTRobe, DropQuestion.anyWhite] + report.items.map(report.name)
        let dungeons = Set(report.kills.keys.map(\.dungeon)).sorted()
        // A preset can name an item or dungeon with no data yet; it still shows as the picker's choice.
        func choices(_ list: [String], _ current: String?) -> [String] { current.map { list.contains($0) ? list : list + [$0] } ?? list }
        let what = q.item == DropQuestion.anyWhite ? "white bag items" : q.item.hasPrefix("Any ") ? String(q.item.dropFirst(4)) + "s" : q.item
        let sentence = (q.rarity.map { $0.name + " " } ?? "") + what + " from " + (q.mobs == .any ? "any mob" : q.mobs.rawValue.lowercased())
            + " in " + (q.from ?? "any map") + ", per " + q.per.rawValue.lowercased()
        let per = q.per == .run ? "A run is one map visit where a boss died; it counts once however many it left."
            : q.per == .white ? "White bags are kills whose best bag was white; an overflow second bag counts once."
            : "Kills are of mobs you damaged; pet kills don't count."
        return ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header("Ask a question", "Pick what dropped, from what, and per what. Every answer is a count divided by a count.")
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), alignment: .leading)], alignment: .leading, spacing: 6) {
                    ForEach(DropQuestion.presets, id: \.0) { title, preset in
                        Button(title) { model.question = preset }.buttonStyle(.bordered).tint(preset == q ? .accentColor : nil)
                    }
                }
                section("QUESTION") {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("What dropped", selection: $model.question.item) { ForEach(choices(items, q.item), id: \.self) { Text($0) } }
                        Picker("Rarity", selection: $model.question.rarity) {
                            Text("Any").tag(DropRarity?.none)
                            ForEach(DropRarity.allCases, id: \.self) { Text($0.name).tag(DropRarity?.some($0)) }
                        }
                        Picker("From", selection: $model.question.from) {
                            Text("Anywhere").tag(String?.none)
                            ForEach(choices(dungeons, q.from), id: \.self) { Text($0).tag(String?.some($0)) }
                        }
                        Picker("Which mobs", selection: $model.question.mobs) { ForEach(DropQuestion.Mobs.allCases, id: \.self) { Text($0.rawValue) } }
                        Picker("Per", selection: $model.question.per) { ForEach(DropQuestion.Per.allCases, id: \.self) { Text($0.rawValue) } }
                    }
                    .frame(maxWidth: 420).padding(12)
                }
                section("ANSWER") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(answer.rate.of == 0 ? "No data" : DropRate.oneIn(answer.rate.rate)).font(.system(size: 28, weight: .semibold))
                        Text(sentence).foregroundStyle(.secondary)
                        RateView(rate: answer.rate, unit: answer.unit)
                        Text("Counted: \(answer.rate.count.formatted()) \(q.per == .run ? "runs with a match" : "matching copies") in bags linked to those kills. "
                             + "Divided by: \(answer.rate.of.formatted()) \(answer.unit) since capture started. \(per)"
                             + (answer.unread > 0 ? " \(answer.unread.formatted()) matching copies left out: they have no rarity (potions and other items without enchantments)." : ""))
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(12)
                }
            }
            .padding(20)
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
