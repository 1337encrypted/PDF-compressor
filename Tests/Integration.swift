import Foundation
import PDFKit
import CryptoKit
import Darwin

func require(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw CompressionError.message("CHECK FAILED: \(message)") }
}
func digest(_ url: URL) throws -> String {
    SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
}
func expectFailure(_ label: String, _ operation: () throws -> Void) throws {
    var failed = false
    do { try operation() } catch { failed = true }
    try require(failed, label)
    print("PASS: \(label)")
}

@main struct Integration {
    static func main() throws {
        setbuf(stdout, nil)
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let source = root.appendingPathComponent("sample with spaces.pdf")
        let originalHash = try digest(source)
        for quality in Quality.allCases {
            let directory = root.appendingPathComponent(quality.rawValue)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let result = try Compressor.compress(input: source, directory: directory, quality: quality, cancellation: Cancellation())
            try require(result.output != nil, "Image-heavy PDF should shrink")
            let pdf = PDFDocument(url: result.output!)!
            try require(pdf.pageCount == 2, "Both pages retained")
            try require(pdf.string?.contains("This text should remain selectable") == true, "Text retained")
            print("PASS: \(quality.title): \(result.inputBytes) → \(result.outputBytes) bytes")
        }
        let balanced = root.appendingPathComponent("balanced")
        let existing = balanced.appendingPathComponent("sample with spaces-compressed.pdf")
        let existingHash = try digest(existing)
        let second = try Compressor.compress(input: source, directory: balanced, quality: .balanced, cancellation: Cancellation())
        try require(second.output?.lastPathComponent == "sample with spaces-compressed-2.pdf", "Collision gets new name")
        try require(try digest(existing) == existingHash, "Existing file unchanged")
        try require(try digest(source) == originalHash, "Original unchanged")
        print("PASS: Original preservation and output collision")
        let tiny = try Compressor.compress(input: root.appendingPathComponent("tiny.pdf"), directory: root, quality: .balanced, cancellation: Cancellation())
        try require(tiny.output == nil, "Larger candidate discarded")
        print("PASS: Already compact PDF skips larger output")
        for name in ["invalid.pdf", "protected.pdf", "form.pdf"] {
            try expectFailure("Reject \(name)") {
                _ = try Compressor.compress(input: root.appendingPathComponent(name), directory: root, quality: .balanced, cancellation: Cancellation())
            }
        }
        let cancelled = Cancellation()
        cancelled.cancel()
        try expectFailure("Cancellation") { _ = try Compressor.compress(input: source, directory: root, quality: .balanced, cancellation: cancelled) }
        try expectFailure("Missing output folder") { _ = try Compressor.compress(input: source, directory: root.appendingPathComponent("missing"), quality: .balanced, cancellation: Cancellation()) }
        try checkImages(root)
        print("All integration checks passed.")
    }
}
