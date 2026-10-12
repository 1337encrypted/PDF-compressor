import Foundation
import PDFKit

enum Quality: String, CaseIterable, Identifiable {
    case high, balanced, small
    var id: String { rawValue }
    var title: String { switch self { case .high: "High quality"; case .balanced: "Balanced"; case .small: "Smallest file" } }
    var detail: String { switch self { case .high: "300 dpi · for printing"; case .balanced: "150 dpi · everyday sharing"; case .small: "72 dpi · screen reading" } }
    var preset: String { switch self { case .high: "/printer"; case .balanced: "/ebook"; case .small: "/screen" } }
}

enum CompressionError: LocalizedError {
    case message(String), cancelled
    var errorDescription: String? {
        switch self { case .message(let text): text; case .cancelled: "Cancelled" }
    }
}

final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return stopped }
    func attach(_ newProcess: Process) {
        lock.lock(); defer { lock.unlock() }
        process = newProcess
        if stopped && newProcess.isRunning { newProcess.terminate() }
    }
    func detach() { lock.lock(); process = nil; lock.unlock() }
    func cancel() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if let process, process.isRunning { process.terminate() }
    }
    func check() throws { if isCancelled { throw CompressionError.cancelled } }
}

struct CompressionResult {
    let inputBytes: Int64
    let outputBytes: Int64
    let output: URL?
}

enum Compressor {
    static func executable() -> URL? {
        let paths = ["/opt/homebrew/bin/gs", "/usr/local/bin/gs"] +
            (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map { "\($0)/gs" }
        return paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }).map { URL(fileURLWithPath: $0) }
    }
    static func bytes(_ url: URL) throws -> Int64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    static func document(_ url: URL) throws -> PDFDocument {
        guard url.pathExtension.lowercased() == "pdf", let doc = PDFDocument(url: url), doc.pageCount > 0 else {
            throw CompressionError.message("This file is not a readable PDF.")
        }
        guard !doc.isEncrypted else {
            throw CompressionError.message("This PDF is password protected. Export an unprotected copy first.")
        }
        return doc
    }
    static func compress(input: URL, directory: URL, quality: Quality, cancellation: Cancellation) throws -> CompressionResult {
        try cancellation.check()
        let original = try document(input)
        for index in 0..<original.pageCount {
            if original.page(at: index)?.annotations.contains(where: { $0.type == "Widget" }) == true {
                throw CompressionError.message("This PDF has form or signature fields. Export a flat copy before compressing.")
            }
        }
        guard let gs = executable() else { throw CompressionError.message("Install Ghostscript to enable compression: brew install ghostscript") }
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CompressionError.message("Choose an existing output folder.")
        }
        let inputBytes = try bytes(input)
        let scratch = fm.temporaryDirectory.appendingPathComponent("PDFPress-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let candidate = scratch.appendingPathComponent("compressed.pdf")
        let logURL = scratch.appendingPathComponent("engine.log")
        fm.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        defer { try? log.close() }
        let process = Process()
        process.executableURL = gs
        process.arguments = ["-sDEVICE=pdfwrite", "-dSAFER", "-dBATCH", "-dNOPAUSE", "-dQUIET",
            "-dPDFSETTINGS=\(quality.preset)", "-dAutoRotatePages=/None", "-dDetectDuplicateImages=true",
            "-sOutputFile=\(candidate.path)", "-f", input.path]
        process.standardOutput = log
        process.standardError = log
        try process.run()
        cancellation.attach(process)
        process.waitUntilExit()
        cancellation.detach()
        try cancellation.check()
        guard process.terminationStatus == 0 else {
            throw CompressionError.message("Compression failed. Try exporting a fresh PDF from Preview.")
        }
        guard let compressed = PDFDocument(url: candidate), !compressed.isLocked,
              compressed.pageCount == original.pageCount else {
            throw CompressionError.message("The compressed PDF could not be verified. Your original is unchanged.")
        }
        for index in 0..<original.pageCount {
            guard let before = original.page(at: index)?.bounds(for: .mediaBox),
                  let after = compressed.page(at: index)?.bounds(for: .mediaBox),
                  abs(before.width - after.width) < 1, abs(before.height - after.height) < 1 else {
                throw CompressionError.message("Page sizes changed during compression. Your original is unchanged.")
            }
        }
        let outputBytes = try bytes(candidate)
        guard outputBytes < inputBytes else { return CompressionResult(inputBytes: inputBytes, outputBytes: inputBytes, output: nil) }
        try cancellation.check()
        // copyItem refuses to overwrite an existing file, including collisions with another process.
        let stem = input.deletingPathExtension().lastPathComponent + "-compressed"
        for suffix in 0..<10000 {
            let name = suffix == 0 ? "\(stem).pdf" : "\(stem)-\(suffix + 1).pdf"
            let destination = directory.appendingPathComponent(name)
            do {
                try fm.copyItem(at: candidate, to: destination)
                return CompressionResult(inputBytes: inputBytes, outputBytes: outputBytes, output: destination)
            } catch {
                if (error as NSError).code == NSFileWriteFileExistsError { continue }
                throw CompressionError.message("Could not save the PDF. Choose a folder you can write to.")
            }
        }
        throw CompressionError.message("Too many files with this name. Choose another output folder.")
    }
}
