import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

private let ink = Color(red: 0.12, green: 0.20, blue: 0.27)
private let accent = Color(red: 0.04, green: 0.39, blue: 0.49)

struct PDFItem: Identifiable {
    let id = UUID()
    let url: URL
    let size: Int64
    var status = "Ready"
    var result: CompressionResult?
    var failed = false
}

@MainActor final class AppModel: ObservableObject {
    @Published var items: [PDFItem] = []
    @Published var quality: Quality = .balanced
    @Published var folder: URL?
    @Published var running = false
    @Published var processed = 0
    @Published var engineAvailable = Compressor.executable() != nil
    @Published var alert: String?
    private var cancellation = Cancellation()

    var total: Int64 { items.reduce(0) { $0 + $1.size } }
    var saved: Int64 { items.reduce(0) { $0 + (($1.result?.inputBytes ?? 0) - ($1.result?.outputBytes ?? 0)) } }
    var pending: [PDFItem] { items.filter { $0.result == nil && !$0.failed } }
    func add(_ urls: [URL]) {
        guard !running else { return }
        var rejected = 0
        for url in urls {
            let canonical = url.standardizedFileURL.resolvingSymlinksInPath()
            if items.contains(where: { $0.url == canonical }) { continue }
            do {
                _ = try Compressor.document(canonical)
                items.append(PDFItem(url: canonical, size: try Compressor.bytes(canonical)))
            } catch { rejected += 1; alert = error.localizedDescription }
        }
        if rejected > 1 { alert = "\(rejected) files could not be added. Choose readable, unprotected PDFs." }
    }
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.pdf]
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
        guard engineAvailable, !running, !pending.isEmpty else { return }
        running = true
        processed = 0
        cancellation = Cancellation()
        let queue = pending
        let destination = folder
        let profile = quality
        let token = cancellation
        Task {
            for item in queue {
                if token.isCancelled { break }
                update(item.id, status: "Compressing…")
                let outcome = await Task.detached(priority: .userInitiated) { () -> Result<CompressionResult, Error> in
                    Result { try Compressor.compress(input: item.url, directory: destination ?? item.url.deletingLastPathComponent(), quality: profile, cancellation: token) }
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

struct ContentView: View {
    @StateObject var model = AppModel()
    @State private var targeted = false
    @State private var comparison: PDFItem?
    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "doc.zipper").font(.system(size: 30, weight: .medium)).foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PDF Press").font(.system(size: 28, weight: .bold, design: .rounded)).foregroundStyle(ink)
                    Text("Less size. More room.").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                Spacer()
                Label("On your Mac", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            HStack(alignment: .top, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    dropZone
                    HStack {
                        Text(model.items.isEmpty ? "Your PDFs" : "\(model.items.count) PDFs · \(size(model.total))").font(.system(size: 13, weight: .semibold))
                        Spacer()
                        if !model.items.isEmpty {
                            Button("Clear") { model.items.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary).disabled(model.running)
                        }
                    }
                    if model.items.isEmpty {
                        VStack(spacing: 8) {
                            Text("Start with one PDF, or a whole batch.").font(.system(size: 14, weight: .medium))
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
                settings.frame(width: 238)
            }
            Divider()
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.saved > 0 ? "\(size(model.saved)) saved" : "Your originals stay untouched").font(.system(size: 13, weight: .semibold))
                    Text(model.running ? "Working on \(min(model.processed + 1, model.items.count)) of \(model.items.count)…" : "Files stay on this Mac. Nothing is uploaded.").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                if model.running {
                    ProgressView().controlSize(.small)
                    Button("Cancel") { model.cancel() }
                } else {
                    if model.items.contains(where: { $0.failed }) { Button("Retry failed") { model.retryFailures() } }
                    Button { model.start() } label: {
                        Text("Compress PDFs").font(.system(size: 14, weight: .semibold)).padding(.horizontal, 16).padding(.vertical, 8)
                    }.buttonStyle(.borderedProminent).tint(accent).keyboardShortcut(.return, modifiers: [.command])
                        .disabled(model.pending.isEmpty || !model.engineAvailable)
                }
            }
        }.padding(28).frame(minWidth: 840, minHeight: 610).background(Color(nsColor: .windowBackgroundColor))
            .alert("PDF Press", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
                Button("OK") { model.alert = nil }
            } message: { Text(model.alert ?? "") }
            .sheet(item: $comparison) { item in ComparisonView(item: item) }
    }
    private var dropZone: some View {
        Button { model.chooseFiles() } label: {
            VStack(spacing: 9) {
                Image(systemName: "arrow.down.doc").font(.system(size: 31, weight: .light))
                Text("Drop PDFs here").font(.system(size: 18, weight: .semibold, design: .rounded))
                Text("or click to choose files").font(.system(size: 12)).foregroundStyle(.secondary)
            }.foregroundStyle(accent).frame(maxWidth: .infinity).frame(height: 150)
                .background(accent.opacity(targeted ? 0.13 : 0.04), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(accent.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        }.buttonStyle(.plain).disabled(model.running).accessibilityLabel("Choose PDFs or drop them here")
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
        VStack(alignment: .leading, spacing: 20) {
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
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(model.quality == quality ? accent.opacity(0.09) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).disabled(model.running).accessibilityAddTraits(model.quality == quality ? .isSelected : [])
                }
            }
            Text("Lower resolution makes images softer. Text usually stays selectable. PDFs that are already compact may not shrink.").font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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
                    Text("Install Ghostscript in Terminal:").font(.system(size: 11))
                    Text("brew install ghostscript").font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                    Button("Check again") { model.engineAvailable = Compressor.executable() != nil }
                }.padding(12).background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
            }
            Spacer(minLength: 0)
        }
    }
    private func fileRow(_ item: PDFItem) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: item.failed ? "exclamationmark.circle" : item.result != nil ? "checkmark.circle" : "doc.text").font(.system(size: 19)).foregroundStyle(item.failed ? .orange : accent).padding(.top, 2)
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

struct ComparisonView: View {
    let item: PDFItem
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Compare quality").font(.title2.weight(.semibold))
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack(spacing: 16) {
                VStack { Text("Original · \(size(item.size))").font(.headline); PDFPreview(url: item.url) }
                if let output = item.result?.output {
                    VStack { Text("Compressed · \(size(item.result!.outputBytes))").font(.headline); PDFPreview(url: output) }
                }
            }
        }.padding(22).frame(width: 940, height: 670)
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

@main struct PDFPressApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        Window("PDF Press", id: "main") { ContentView() }
            .defaultSize(width: 900, height: 650)
            .windowResizability(.contentMinSize)
            .commands { CommandGroup(replacing: .newItem) {} }
    }
}
