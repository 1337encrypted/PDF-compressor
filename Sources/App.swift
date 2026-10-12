import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

private let accent = Color(red: 0.04, green: 0.39, blue: 0.49)

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    let kind: FileKind
    var status = "Ready"
    var result: CompressionResult?
    var failed = false
}

@MainActor final class AppModel: ObservableObject {
    @Published var items: [FileItem] = []
    @Published var quality: Quality = .balanced
    @Published var folder: URL?
    @Published var running = false
    @Published var processed = 0
    @Published var engineAvailable = Compressor.executable() != nil
    @Published var alert: String?
    @Published var imageFormat: ImageFormat = .automatic
    @Published var imageMaxDimension = 0
    @Published var workingTotal = 0
    private var cancellation = Cancellation()

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var saved: Int64 { items.reduce(0) { $0 + (($1.result?.inputBytes ?? 0) - ($1.result?.outputBytes ?? 0)) } }
    var pending: [FileItem] { items.filter { $0.result == nil && !$0.failed } }
    func add(_ urls: [URL]) {
        guard !running else { return }
        var rejected = 0
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if items.contains(where: { $0.url == canonical }) { continue }
            do {
                let kind = try Compressor.kind(canonical)
                items.append(FileItem(url: canonical, size: try Compressor.bytes(canonical), kind: kind))
            } catch { rejected += 1; alert = error.localizedDescription }
        }
        if rejected > 1 { alert = "\(rejected) files could not be added. Choose readable PDFs or supported images." }
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = Compressor.allowedTypes
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { add(panel.urls) }
    }
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Choose folder"
        if panel.runModal() == .OK { folder = panel.url }
    }
    func start() {
        engineAvailable = Compressor.executable() != nil
        guard !running, !pending.isEmpty else { return }
        running = true
        processed = 0
        cancellation = Cancellation()
        let queue = pending
        let destination = folder
        let profile = quality
        let token = cancellation
        let imageOptions = ImageOptions(format: imageFormat, maxDimension: imageMaxDimension)
        workingTotal = queue.count
        Task {
            for item in queue {
                if token.isCancelled { break }
                update(item.id, status: "Compressing…")
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<CompressionResult, Error> in
                    Result { try Compressor.compress(input: item.url, directory: destination ?? item.url.deletingLastPathComponent(), quality: profile, cancellation: token, imageOptions: imageOptions) }
                }.value
                if let index = items.firstIndex(where: { $0.id == item.id }) {
                    switch outcome {
                    case .success(let result):
                        items[index].result = result
                        items[index].status = result.output == nil ? "Already compact · original kept" : "\(Int((1 - Double(result.outputBytes) / Double(result.inputBytes)) * 100))% smaller"
                    case .failure(let error):
                        if token.isCancelled { items[index].status = "Ready" }
                        else { items[index].failed = true; items[index].status = error.localizedDescription }
                    }
                }
                processed += 1
            }
            running = false
        }
    }
    func update(_ id: UUID, status: String) {
        if let index = items.firstIndex(where: { $0.id == id }) { items[index].status = status }
    }
    func cancel() { cancellation.cancel() }
    func retryFailures() {
        for index in items.indices where items[index].failed { items[index].failed = false; items[index].status = "Ready" }
    }
}

@MainActor struct ContentView: View {
    @StateObject var model: AppModel
    init() { _model = StateObject(wrappedValue: AppModel()) }
    init(model: AppModel) { _model = StateObject(wrappedValue: model) }
    @State private var targeted = false
    @State private var comparison: FileItem?
    private var brandIcon: NSImage {
        if let url = Bundle.main.url(forResource: "BrandIcon", withExtension: "png"), let image = NSImage(contentsOf: url) { return image }
        return NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                Image(nsImage: brandIcon).resizable().interpolation(.high).scaledToFit().frame(width: 58, height: 58).accessibilityLabel("PDF Press icon")
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF Press").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(.primary)
                    Text("Compress PDFs and images.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("On your Mac", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    dropZone
                    HStack {
                        Text(model.items.isEmpty ? "Your files" : "\(model.items.count) files · \(size(model.total))").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if !model.items.isEmpty {
                            Button("Clear") { model.items.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.running)
                        }
                    }
                    if model.items.isEmpty {
                        VStack(spacing: 8) {
                            Text("Start with one file, or a mixed batch.").font(.system(size: 14, weight: .medium))
                            Text("Compressed copies appear alongside your originals\nunless you choose another folder.").font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(model.items) { item in
                                    fileRow(item)
                                    Divider()
                                }
                            }
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                ScrollView { settings }.frame(width: 255)
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.saved > 0 ? "\(size(model.saved)) saved" : "Your originals stay untouched").font(.system(size: 13, weight: .semibold))
                    Text(model.running ? "Working on \(min(model.processed + 1, model.workingTotal)) of \(model.workingTotal)…" : "Files stay on this Mac. Nothing is uploaded.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                } else {
                    if model.items.contains(where: { $0.failed }) { Button("Retry failed") { model.retryFailures() } }
                    Button { model.start() } label: {
                        Text("Compress files").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.pending.isEmpty)
                }
            }
        }.padding(28).frame(minWidth: 880, minHeight: 660).background(Color(nsColor: .windowBackgroundColor))
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in model.cancel() }
            .alert("PDF Press", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                Button("OK") { model.alert = nil }
            } message: { Text(model.alert ?? "") }
            .sheet(item: $comparison) { item in ComparisonView(item: item) }
    }
    private var dropZone: some View {
        Button { model.chooseFiles() } label: {
            VStack(spacing: 9) {
                Image(systemName: "arrow.down.doc").font(.system(size: 31, weight: .light))
                Text("Drop PDFs or images here").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("PNG, JPEG, HEIC, TIFF, BMP, GIF, WebP, AVIF").font(.system(size: 11)).foregroundStyle(.secondary)
                Text("or click to choose files").font(.system(size: 12)).foregroundStyle(.secondary)
            }.foregroundStyle(accent).frame(maxWidth: .infinity).frame(height: 150)
                .background(accent.opacity(targeted ? 0.13 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        }.buttonStyle(.plain).disabled(model.running).accessibilityLabel("Choose PDFs and images or drop them here")
            .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
                guard !model.running else { return false }
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        if let url { Task { @MainActor in model.add([url]) } }
                    }
                }
                return true
            }
    }
    private var settings: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Compression").font(.system(size: 17, weight: .semibold))
            VStack(spacing: 8) {
                ForEach(Quality.allCases) { quality in
                    Button { model.quality = quality } label: {
                        HStack(spacing: 10) {
                            Image(systemName: model.quality == quality ? "largecircle.fill.circle" : "circle").foregroundStyle(model.quality == quality ? accent : .secondary)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(quality.title).font(.system(size: 13, weight: .semibold))
                                Text(quality.detail).font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }.padding(.vertical, 8).padding(.horizontal, 10).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.quality == quality ? accent.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.running).accessibilityAddTraits(model.quality == quality ? .isSelected : [])
                }
            }
            Text("PNG stays lossless unless resized. Lower quality softens PDF and photo images.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("Images").font(.system(size: 13, weight: .semibold))
                Picker("Output", selection: $model.imageFormat) {
                    ForEach(ImageFormat.allCases) { format in Text(format.title).tag(format) }
                }
                Picker("Size", selection: $model.imageMaxDimension) {
                    Text("Original dimensions").tag(0)
                    Text("Up to 2560 px").tag(2560)
                    Text("Up to 1920 px").tag(1920)
                    Text("Up to 1280 px").tag(1280)
                }
                Text("Automatic keeps the format; BMP, WebP and AVIF use JPEG or PNG.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .help("Transparency is preserved. The resize setting limits the longest edge and never enlarges images. Already compact files may not shrink.")
            }.disabled(model.running)
            Divider()
            VStack(alignment: .leading, spacing: 9) {
                Text("Save copies to").font(.system(size: 13, weight: .semibold))
                Text(model.folder?.path ?? "Same folder as each original").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(3).help(model.folder?.path ?? "Same folder as each original")
                HStack {
                    Button("Choose folder…") { model.chooseFolder() }
                    if model.folder != nil { Button("Reset") { model.folder = nil }.buttonStyle(.plain) }
                }.disabled(model.running)
            }
            if !model.engineAvailable {
                VStack(alignment: .leading, spacing: 8) {
                    Label("One-time setup", systemImage: "wrench.adjustable").font(.system(size: 12, weight: .semibold))
                    Text("PDFs need Ghostscript. Images work without it. Install in Terminal:").font(.system(size: 11))
                    Text("brew install ghostscript").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button("Check again") { model.engineAvailable = Compressor.executable() != nil }
                }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
    }
    private func fileRow(_ item: FileItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.failed ? "exclamationmark.circle" : item.result != nil ? "checkmark.circle" : item.kind == .image ? "photo" : "doc.text").font(.system(size: 19)).foregroundStyle(item.failed ? .orange : accent).padding(.top, 2)
            VStack(alignment: .leading, spacing: 5) {
                Text(item.url.lastPathComponent).font(.system(size: 13, weight: .medium)).lineLimit(1).help(item.url.path)
                Text(item.result?.output != nil ? "\(size(item.size)) → \(size(item.result!.outputBytes))" : size(item.size)).font(.system(size: 11)).foregroundStyle(.secondary)
                Text(item.status).font(.system(size: 11)).foregroundStyle(item.failed ? .orange : .secondary).fixedSize(horizontal: false, vertical: true)
                if let output = item.result?.output {
                    HStack(spacing: 12) {
                        Button("Compare") { comparison = item }
                        Button("Open") { NSWorkspace.shared.open(output) }
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([output]) }
                    }.buttonStyle(.link).font(.system(size: 11))
                }
            }
            Spacer(minLength: 0)
            if !model.running {
                Button { model.items.removeAll { $0.id == item.id } } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Remove \(item.url.lastPathComponent)")
            }
        }.padding(.vertical, 13)
    }
}

func size(_ bytes: Int64) -> String { ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }

struct PDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.document = PDFDocument(url: url)
        return view
    }
    func updateNSView(_ view: PDFView, context: Context) {
        if view.document?.documentURL != url { view.document = PDFDocument(url: url) }
    }
}

struct FilePreview: View {
    let url: URL
    var body: some View {
        if url.pathExtension.lowercased() == "pdf" { PDFPreview(url: url) }
        else { ImagePreview(url: url) }
    }
}

final class FittingImageView: NSImageView {
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric) }
}

struct ImagePreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> NSImageView {
        let view = FittingImageView()
        view.imageScaling = .scaleProportionallyUpOrDown
        view.imageAlignment = .alignCenter
        view.animates = true
        view.image = NSImage(contentsOf: url)
        return view
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSImageView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 400, height: proposal.height ?? 500)
    }
    func updateNSView(_ view: NSImageView, context: Context) {
        if view.image?.name() != url.path {
            view.image = NSImage(contentsOf: url)
            view.image?.setName(url.path)
        }
    }
}

struct ComparisonView: View {
    let item: FileItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Compare quality").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 16) {
                VStack { Text("Original · \(size(item.size))").font(.headline); FilePreview(url: item.url).frame(maxWidth: .infinity, maxHeight: .infinity).clipped() }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let output = item.result?.output {
                    VStack { Text("Compressed · \(size(item.result!.outputBytes))").font(.headline); FilePreview(url: output).frame(maxWidth: .infinity, maxHeight: .infinity).clipped() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }.padding(22).frame(width: 940, height: 670).background(Color(nsColor: .windowBackgroundColor))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Cancelling via the UI ends a running Ghostscript job before quit.
        .terminateNow
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

#if !UI_PREVIEW
@main
#endif
struct PDFPressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("PDF Press", id: "main") { ContentView() }
            .defaultSize(width: 960, height: 760)
            .windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
