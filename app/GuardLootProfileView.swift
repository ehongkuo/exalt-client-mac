import SwiftUI

/// The Loot profile (issue #58): your character and every loot factor in the game running now, in the game's look
/// (dark panels, inventory slots, gold multipliers). `bar` is the one-row loot bar on top of the Drop rates tab; without
/// it, the details its Details button opens in the tab's right pane. The model is LootNow, in GuardLootProfile.swift.

let lootGold = Color(red: 1, green: 0.85, blue: 0.4)
private let enchantGreen = Color(red: 0.71, green: 0.88, blue: 0.48)
private let boostBlue = Color(red: 0.35, green: 0.64, blue: 1)

struct LootProfileView: View {
    @ObservedObject var model: DropRatesModel
    @ObservedObject private var live: DropLive   // model.now lives here (issue #81)
    var bar = false
    init(model: DropRatesModel, bar: Bool = false) { self.model = model; _live = ObservedObject(wrappedValue: model.live); self.bar = bar }

    var body: some View {
        // Each second, so the potion timers count down.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let now = live.now, s = now?.state(at: context.date.timeIntervalSince1970)
            if bar {
                lootBar(now, s)
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("LOOT PROFILE").font(.system(size: 12, weight: .bold, design: .monospaced))
                        Spacer()
                        Button { model.lootDetails = false } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Close")
                    }
                    if let now, let s { profile(now, s) } else { offline }
                }
            }
        }
    }

    /// One row: who you are, the total, the boosts with timers, your gear, the dungeon's modifiers, then Details.
    @ViewBuilder private func lootBar(_ now: LootNow?, _ s: LootState?) -> some View {
        if let now, let s {
            let loot = (0..<4).map { i in (s.enchants.map { i < $0.count ? $0[i] : [] } ?? []).compactMap { catalog.enchants[$0] } }
            let gear = LootMath.gear(s.enchants ?? [], catalog)
            HStack(spacing: 12) {
                slot(now.classType, size: 40, sprite: 32)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(now.names[now.classType] ?? "Character").font(.system(size: 13, weight: .bold, design: .monospaced))
                        if now.level > 0 { Text("LV \(now.level)").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(lootGold) }
                    }
                    Text((now.seasonal ? "Seasonal · " : "") + (now.map.isEmpty ? "loading" : now.map) + (now.safe ? " · timers paused" : ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                barDivider
                totals(s, big: 22, small: 15)
                barDivider
                HStack(spacing: 6) {
                    small(LootNow.potionSprite, on: s.potion > 0, "Loot Drop Potion" + (s.potion > 0 ? ": ×\(LootMath.times(LootMath.potion)), \(LootMath.clock(s.potion)) left" : ": off"))
                    small(LootNow.tierSprite, on: s.tier > 0, "Loot Tier Potion" + (s.tier > 0 ? ": \(LootMath.clock(s.tier)) left" : ": off"))
                    small(LootNow.crucibleSprite, on: s.crucible == true, "Crucible: " + (s.crucible == nil ? "unknown until your first portal" : s.crucible! ? "on, ×" + LootMath.times(LootMath.crucible) : "off"))
                    small(LootNow.ritualSprite, on: s.ritual > 0, "Blood Ritual: " + (s.ritual > 0 ? "−\(s.ritual * 5)% HP, ×" + LootMath.times(LootMath.ritual(s.ritual)) : "off"))
                }
                barDivider
                HStack(spacing: 4) {
                    ForEach(0..<4, id: \.self) { i in
                        let type = i < now.equipment.count ? now.equipment[i] : -1
                        slot(type, size: 34, sprite: 24, border: loot[i].isEmpty ? nil : lootGold.opacity(0.7))
                            .help(type > 0 ? (now.names[type] ?? "") + (loot[i].isEmpty ? "" : ": " + loot[i].map { "\($0.name) +\(LootMath.times($0.percent))%" }.joined(separator: ", ")) : "Empty slot")
                    }
                    Text(s.enchants == nil ? "gear not captured" : "gear +\(LootMath.times(gear))%").font(.system(size: 11))
                        .foregroundStyle(s.enchants == nil ? Color.secondary : enchantGreen).padding(.leading, 4)
                }
                if !s.modifiers.isEmpty {
                    barDivider
                    HStack(spacing: 4) { ForEach(s.modifiers.prefix(3), id: \.self) { modifier($0) } }
                }
                Spacer(minLength: 0)
                Button { model.lootDetails.toggle() } label: {
                    Text(model.lootDetails ? "Details ▴" : "Details ▾").font(.system(size: 11)).foregroundStyle(lootGold)
                }
                .buttonStyle(.plain).help("Every loot factor, in the right pane")
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(lootGold.opacity(0.55), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
        } else {
            HStack(spacing: 6) {
                Text("LOOT").font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary)
                Text("No game running. Start it from here to see your boosts and your rate now next to each base rate.")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18)).clipShape(RoundedRectangle(cornerRadius: 4))
        }
    }
    private var barDivider: some View { Rectangle().fill(Color.white.opacity(0.12)).frame(width: 1, height: 34) }
    private func small(_ sprite: Int, on: Bool, _ help: String) -> some View {
        slot(sprite, size: 34, sprite: 22, border: on ? boostBlue : nil).opacity(on ? 1 : 0.45).help(help)
    }

    private var catalog: LootCatalog { model.catalog }

    private var offline: some View {
        panel {
            VStack(alignment: .leading, spacing: 6) {
                header("NO GAME RUNNING")
                Text("Start the game from Exalt Client Mac. Your character, gear and loot boosts show here while you play.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func profile(_ now: LootNow, _ s: LootState) -> some View {
        character(now, s)
        multiplier(s)
        header("EQUIPMENT · LOOT ENCHANTS")
        panel {
            HStack(alignment: .top, spacing: 8) {
                ForEach(0..<4, id: \.self) { gearSlot(now, s, $0).frame(maxWidth: .infinity) }
            }
        }
        header("BOOSTS")
        panel {
            VStack(alignment: .leading, spacing: 10) {
                boost(LootNow.potionSprite, "Loot Drop Potion", on: s.potion > 0,
                      detail: s.potion > 0 ? "\(LootMath.clock(s.potion)) left" + (now.safe ? " · paused here" : "") : "not running",
                      value: "×" + LootMath.times(LootMath.potion))
                boost(LootNow.tierSprite, "Loot Tier Potion", on: s.tier > 0,
                      detail: (s.tier > 0 ? "\(LootMath.clock(s.tier)) left · " : "") + "better tiers, not more drops", value: nil)
                boost(LootNow.crucibleSprite, "Crucible", on: s.crucible == true,
                      detail: s.crucible == nil ? "unknown until your first portal: left out" : s.crucible! ? "this season's loot bonus" : "off",
                      value: "×" + LootMath.times(LootMath.crucible))
                boost(LootNow.ritualSprite, "Blood Ritual", on: LootMath.ritual(s.ritual) > 1,
                      detail: s.ritual > 0 ? "−\(s.ritual * 5)% HP" : "off · up to ×1.25 at −20% HP",
                      value: "×" + LootMath.times(LootMath.ritual(s.ritual)))
            }
        }
        header("DUNGEON MODIFIERS")
        panel {
            if s.modifiers.isEmpty {
                Text(now.safe ? "None here" : "None on this map").font(.caption).foregroundStyle(.secondary)
            } else {
                FlowRow(items: s.modifiers) { modifier($0) }
            }
        }
        panel {
            VStack(alignment: .leading, spacing: 6) {
                header("NOT CAPTURED YET")
                Text("Crucible (+10% this season), drop accelerators (+33% stat potions, +50% artifacts) and server-wide loot events. They're left out of every number here.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        Text("Drop rates shows base rates: the chance with no boost. The gold “yours” next to them is base × your multiplier now.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func character(_ now: LootNow, _ s: LootState) -> some View {
        panel {
            HStack(spacing: 12) {
                slot(now.classType, size: 72, sprite: 56)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(now.names[now.classType] ?? "Character").font(.system(size: 18, weight: .bold, design: .monospaced))
                        if now.level > 0 { Text("LV \(now.level)").font(.system(size: 11, weight: .bold, design: .monospaced)).foregroundStyle(lootGold) }
                    }
                    HStack(spacing: 6) {
                        chip(now.seasonal ? "Seasonal" : "Not seasonal", on: now.seasonal)
                        chip(s.crucible == nil ? "Crucible ?" : s.crucible! ? "Crucible on" : "Crucible off", on: s.crucible == true)
                        chip(s.ritual > 0 ? "Blood Ritual −\(s.ritual * 5)%" : "Blood Ritual off", on: s.ritual > 0)
                    }
                    HStack(spacing: 6) {
                        Rectangle().fill(boostBlue).frame(width: 7, height: 7)
                        Text("Live · \(now.map.isEmpty ? "loading" : now.map)" + (now.safe ? " · timers paused" : ""))
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// The total. Minions and bosses apart only when a modifier treats them differently.
    private func multiplier(_ s: LootState) -> some View {
        let boss: Set<String> = ["BOSS", "BOSSFIGHT", "QUEST"], minion: Set<String> = ["MINION"]
        let drops: [LootCatalog.DropMultiplier] = s.modifiers.flatMap { catalog.modifiers[$0]?.drops ?? [] }
        let split = drops.contains { d in d.item == nil && !d.req.isEmpty && d.amount != 1 }
        let gear: Double = LootMath.gear(s.enchants ?? [], catalog)
        let dungeonText: String = split
            ? "dungeon ×" + LootMath.times(LootMath.dungeon(s.modifiers, catalog, labels: minion)) + " / ×" + LootMath.times(LootMath.dungeon(s.modifiers, catalog, labels: boss))
            : "dungeon ×" + LootMath.times(LootMath.dungeon(s.modifiers, catalog, labels: []))
        var parts: [String] = [s.potion > 0 ? "potion ×" + LootMath.times(LootMath.potion) : "no potion",
                               s.enchants == nil ? "gear not captured" : "gear +" + LootMath.times(gear) + "%", dungeonText]
        if s.crucible == true { parts.append("crucible ×" + LootMath.times(LootMath.crucible)) }
        if LootMath.ritual(s.ritual) > 1 { parts.append("ritual ×" + LootMath.times(LootMath.ritual(s.ritual))) }
        return panel {
            VStack(alignment: .leading, spacing: 3) {
                totals(s, big: 32, small: 22)
                Text(parts.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
    /// A modifier treats minions and bosses differently.
    static func split(_ s: LootState, _ catalog: LootCatalog) -> Bool {
        let drops: [LootCatalog.DropMultiplier] = s.modifiers.flatMap { catalog.modifiers[$0]?.drops ?? [] }
        return drops.contains { d in d.item == nil && !d.req.isEmpty && d.amount != 1 }
    }
    /// "LOOT NOW ×1.60 minions ×1.72 bosses", or one number when no modifier treats them differently.
    private func totals(_ s: LootState, big size: CGFloat, small: CGFloat) -> some View {
        let split = Self.split(s, catalog)
        let minions: Double = s.multiplier(catalog, labels: split ? ["MINION"] : [])
        let bosses: Double = s.multiplier(catalog, labels: ["BOSS", "BOSSFIGHT", "QUEST"])
        return VStack(alignment: .leading, spacing: 0) {
            header("LOOT NOW")
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                big("×" + LootMath.times(minions), size: size)
                Text(split ? "minions" : "every mob").font(.caption).foregroundStyle(.secondary)
                if split { big("×" + LootMath.times(bosses), size: small); Text("bosses").font(.caption).foregroundStyle(.secondary) }
            }
        }
    }

    private func gearSlot(_ now: LootNow, _ s: LootState, _ i: Int) -> some View {
        let type = i < now.equipment.count ? now.equipment[i] : -1
        let loot = (s.enchants.map { i < $0.count ? $0[i] : [] } ?? []).compactMap { catalog.enchants[$0] }
        return VStack(spacing: 5) {
            slot(type, size: 52, sprite: 40, border: loot.isEmpty ? nil : lootGold.opacity(0.7))
            Group {
                if type <= 0 { Text("empty").foregroundStyle(.secondary) }
                else if s.enchants == nil { Text("enchants not captured yet").foregroundStyle(.secondary) }
                else if loot.isEmpty { Text("no loot enchant").foregroundStyle(.secondary) }
                else { ForEach(loot.indices, id: \.self) { Text("\(loot[$0].name) +\(LootMath.times(loot[$0].percent))%").foregroundStyle(enchantGreen) } }
            }
            .font(.system(size: 10)).multilineTextAlignment(.center)
        }
        .help(type > 0 ? now.names[type] ?? "" : "Empty slot")
    }

    private func boost(_ sprite: Int, _ name: String, on: Bool, detail: String, value: String?) -> some View {
        HStack(spacing: 10) {
            slot(sprite, size: 44, sprite: 32, border: on ? boostBlue : nil).opacity(on ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 2) {
                Text(name).fontWeight(.semibold).foregroundStyle(on ? .primary : .secondary)
                Text(detail).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            if let value { Text(on ? value : "off").font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(on ? lootGold : .secondary) }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Tough Boss II ×1.10 bosses", "Elite Minions II · no loot effect".
    private func modifier(_ id: String) -> some View {
        let m = catalog.modifiers[id], drops = m?.drops ?? []
        let all = drops.filter { $0.item == nil }
        let effect: String
        if m == nil { effect = "unknown" }
        else if all.isEmpty { effect = drops.isEmpty ? "no loot effect" : "some items only" }
        else {
            effect = all.map { d in "×" + LootMath.times(d.amount) + (d.req.isEmpty ? "" : " " + d.req.sorted().joined(separator: "/").lowercased()) }
                .joined(separator: ", ")
        }
        let shown = !all.isEmpty && all.contains { $0.amount != 1 }
        return HStack(spacing: 4) {
            Text(m?.name ?? id)
            Text(shown ? effect : "· " + effect).fontWeight(shown ? .bold : .regular).foregroundStyle(shown ? lootGold : .secondary)
        }
        .font(.caption).padding(.horizontal, 7).padding(.vertical, 3)
        .background(Color.black.opacity(0.3)).overlay(RoundedRectangle(cornerRadius: 3).stroke(Color.white.opacity(0.2), lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    // MARK: - Parts in the game's look

    private func panel<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content().padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(red: 0.17, green: 0.17, blue: 0.18))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(red: 0.28, green: 0.28, blue: 0.3), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 4))
    }
    /// An inventory slot: a dark bevelled square with the sprite pixel-sharp inside.
    private func slot(_ key: Int, size: CGFloat, sprite: CGFloat, border: Color? = nil) -> some View {
        SpriteIcon(image: model.sprites[key], size: sprite)
            .frame(width: size, height: size)
            .background(Color(red: 0.105, green: 0.105, blue: 0.115))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(border ?? Color(red: 0.33, green: 0.33, blue: 0.36), lineWidth: 2))
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }
    private func header(_ text: String) -> some View {
        Text(text).font(.system(size: 10, weight: .bold, design: .monospaced)).foregroundStyle(.secondary).padding(.leading, 2)
    }
    private func big(_ text: String, size: CGFloat) -> some View {
        Text(text).font(.system(size: size, weight: .bold, design: .monospaced)).foregroundStyle(lootGold).monospacedDigit()
    }
    private func chip(_ text: String, on: Bool) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(on ? enchantGreen : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.black.opacity(0.3))
            .overlay(RoundedRectangle(cornerRadius: 3).stroke(on ? enchantGreen.opacity(0.6) : Color.white.opacity(0.2), lineWidth: 1))
            .lineLimit(1)
    }

}

/// Chips that wrap onto new lines.
private struct FlowRow<Item: Hashable, Cell: View>: View {
    var items: [Item]
    @ViewBuilder var cell: (Item) -> Cell
    var body: some View {
        Flow(spacing: 6) { ForEach(items, id: \.self) { cell($0) } }
    }
}

private struct Flow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        rows(proposal.width ?? .infinity, subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (i, p) in rows(bounds.width, subviews).places.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func rows(_ width: CGFloat, _ subviews: Subviews) -> (places: [CGPoint], size: CGSize) {
        var places: [CGPoint] = [], x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0, widest: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += line + spacing; line = 0 }
            places.append(CGPoint(x: x, y: y))
            x += s.width + spacing; line = max(line, s.height); widest = max(widest, x - spacing)
        }
        return (places, CGSize(width: widest, height: y + line))
    }
}
