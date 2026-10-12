import SwiftUI
import AppKit

// Build with -D UI_PREVIEW alongside the app sources to test the batch model
// and render its actual SwiftUI view without computer-use automation.
@main struct AppChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        let screenshots = URL(fileURLWithPath: CommandLine.arguments[2])
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        app.appearance = NSAppearance(named: .aqua)
        let model = AppModel()
        model.folder = root.appendingPathComponent("ui-output")
        try FileManager.default.createDirectory(at: model.folder!, withIntermediateDirectories: true)
        let png = root.appendingPathComponent("transparent.png")
        let pdf = root.appendingPathComponent("tiny.pdf")
        model.add([png, pdf, png])
        guard model.items.count == 2, model.items[0].kind == .image, model.items[1].kind == .pdf else {
            throw CompressionError.message("Mixed selection or duplicate handling failed")
        }
        model.start()
        let deadline = Date().addingTimeInterval(30)
        while model.running && Date() < deadline { try await Task.sleep(nanoseconds: 50_000_000) }
        guard !model.running, model.items.allSatisfy({ $0.result != nil && !$0.failed }), model.pending.isEmpty else {
            throw CompressionError.message("Mixed batch did not complete")
        }
        print("PASS: Actual app model completes a mixed PDF/image batch and deduplicates inputs")
        if let icon = Bundle.main.url(forResource: "BrandIcon", withExtension: "png") {
            guard NSImage(contentsOf: icon) != nil else { throw CompressionError.message("Header icon cannot load") }
            print("PASS: In-app icon loads from app bundle")
        } else { throw CompressionError.message("Header icon missing from bundle") }
        for (name, state) in [("empty", AppModel()), ("batch", model)] {
            let view = NSHostingView(rootView: ContentView(model: state).environment(\.colorScheme, .light))
            view.frame = NSRect(x: 0, y: 0, width: 960, height: 760)
            view.layoutSubtreeIfNeeded()
            guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
                throw CompressionError.message("UI render failed")
            }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: screenshots.appendingPathComponent("\(name).png"))
        }
        let comparison = NSHostingView(rootView: ComparisonView(item: model.items[0]).environment(\.colorScheme, .light))
        comparison.frame = NSRect(x: 0, y: 0, width: 940, height: 670)
        comparison.layoutSubtreeIfNeeded()
        let bitmap = comparison.bitmapImageRepForCachingDisplay(in: comparison.bounds)!
        comparison.cacheDisplay(in: comparison.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: screenshots.appendingPathComponent("comparison.png"))
        print("PASS: Rendered empty and mixed-batch views")
    }
}
