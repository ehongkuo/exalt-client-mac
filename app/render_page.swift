import AppKit
import SwiftUI

/// Draws the mob page (issue #50) from a drop database to a PNG, with the app's own views, sprites and numbers, for
/// design review without opening the app. Not part of the app; build it with the app's sources and -D GUARD_RENDER.
/// Usage: render-page <drop_rates.db copy> <mob name> <out.png> [open bag or tier group, e.g. "Purple bag" "T9 weapons"]...
///        render-page <drop_rates.db copy> --dungeon <dungeon name> <out.png>   (a dungeon's page, issue #86)
/// The copy's catalog is rebuilt from RealmHound's XML first when it changed.
@main struct RenderPage {
    @MainActor static func main() {
        let args = CommandLine.arguments
        guard args.count >= 4, let store = DropRateStore(path: args[1]) else { print("usage: render-page db mob out.png [group]..."); exit(2) }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        _ = GameNames.refreshCatalog(store, folder: RealmHoundPaths.assets.appendingPathComponent("xml"), catalog: repo.appendingPathComponent("data/drop_catalog.json"))
        let report = DropReport.load(store)
        let model = DropRatesModel()
        model.update(report)
        if args[2] == "--dungeon" {
            guard args.count >= 5, let d = report.dungeons.first(where: { $0.name == args[3] }) else { print("no dungeon \(args[3])"); exit(1) }
            model.select(dungeon: d.name)
            wait(for: model, report)
            write(DropRatesView(model: model, drops: DropAlerts()).dropsPane(d), to: args[4], model)
            return
        }
        guard let mob = report.kills.keys.filter({ report.name($0.type) == args[2] }).max(by: { report.kills[$0]! < report.kills[$1]! }) else {
            print("no kills of \(args[2])"); exit(1)
        }
        model.pick(mob: mob)
        model.openGroups = Set(report.members.keys.filter { args.dropFirst(4).contains($0.name) })
        model.openBags = Set(DropBag.allCases.filter { args.dropFirst(4).contains($0.name) }.map(Optional.some))
        let bags = BagSprites.load(assets: RealmHoundPaths.assets)
        wait(for: model, report)
        write(MobPage(model: model, mob: mob, bagSprites: bags), width: 430, to: args[3], model)
    }
    @MainActor static func wait(for model: DropRatesModel, _ report: DropReport) {
        let deadline = Date().addingTimeInterval(15)   // item sprites are cut off the main thread
        while model.sprites.count < report.textures.count / 2 && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.1)) }
    }
    @MainActor static func write(_ view: some View, width: CGFloat = 640, to path: String, _ model: DropRatesModel) {
        let renderer = ImageRenderer(content: view.padding(16).frame(width: width).background(Color(white: 0.12)).environment(\.colorScheme, .dark))
        renderer.scale = 2
        guard let image = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { print("render failed"); exit(1) }
        try! png.write(to: URL(fileURLWithPath: path))
        print("wrote \(path) (\(model.sprites.count) sprites)")
    }
}
