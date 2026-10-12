import Foundation
import ImageIO
import UniformTypeIdentifiers

enum FileKind { case pdf, image }

enum ImageFormat: String, CaseIterable, Identifiable {
    case automatic, jpeg, png, heic
    var id: String { rawValue }
    var title: String { switch self { case .automatic: "Automatic"; case .jpeg: "JPEG"; case .png: "PNG"; case .heic: "HEIC" } }
    var type: String? { switch self { case .automatic: nil; case .jpeg: UTType.jpeg.identifier; case .png: UTType.png.identifier; case .heic: UTType.heic.identifier } }
}

struct ImageOptions {
    var format: ImageFormat = .automatic
    var maxDimension: Int = 0
}

enum ImageCompressor {
    static let supportedIdentifiers = [UTType.png.identifier, UTType.jpeg.identifier, UTType.heic.identifier,
        "public.heif", UTType.tiff.identifier, UTType.bmp.identifier, UTType.gif.identifier,
        UTType.webP.identifier, "public.avif"]
    static var allowedTypes: [UTType] {
        let readable = CGImageSourceCopyTypeIdentifiers() as! [String]
        return supportedIdentifiers.filter { readable.contains($0) }.compactMap { UTType($0) }
    }
    static func source(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary),
              let type = CGImageSourceGetType(source) as String?, supportedIdentifiers.contains(type),
              CGImageSourceGetCount(source) > 0 else {
            throw CompressionError.message("Choose a readable PDF, PNG, JPEG, HEIC, TIFF, BMP, GIF, WebP, or AVIF file.")
        }
        return source
    }
    static func validate(_ url: URL) throws {
        let image = try source(url)
        guard CGImageSourceCopyPropertiesAtIndex(image, 0, nil) != nil else {
            throw CompressionError.message("This image could not be read.")
        }
    }
    static func hasAlpha(_ image: CGImage) -> Bool {
        [.first, .last, .premultipliedFirst, .premultipliedLast, .alphaOnly].contains(image.alphaInfo)
    }
    static func compress(input: URL, directory: URL, quality: Quality, options: ImageOptions, cancellation: Cancellation) throws -> CompressionResult {
        try cancellation.check()
        let source = try source(input)
        let inputType = CGImageSourceGetType(source)! as String
        let count = CGImageSourceGetCount(source)
        let encoders = CGImageDestinationCopyTypeIdentifiers() as! [String]
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CompressionError.message("Choose an existing output folder.")
        }
        guard let first = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw CompressionError.message("This image could not be decoded.")
        }
        let outputType: String
        if let chosen = options.format.type { outputType = chosen }
        else if [UTType.bmp.identifier, UTType.webP.identifier, "public.avif"].contains(inputType) {
            outputType = hasAlpha(first) ? UTType.png.identifier : UTType.jpeg.identifier
        } else if inputType == "public.heif" { outputType = UTType.heic.identifier }
        else { outputType = inputType }
        guard encoders.contains(outputType) else {
            throw CompressionError.message("This Mac cannot write that image format. Choose PNG or JPEG.")
        }
        // Preserve all frames or pages; never silently flatten animations or multipage TIFFs.
        if count > 1 && (outputType != inputType || ![UTType.gif.identifier, UTType.png.identifier, UTType.tiff.identifier].contains(outputType)) {
            throw CompressionError.message("This image has multiple frames or pages. Use Automatic to preserve its format.")
        }
        if outputType == UTType.jpeg.identifier && hasAlpha(first) {
            throw CompressionError.message("JPEG cannot preserve transparency. Choose Automatic, PNG, or HEIC.")
        }
        let originalExtension = input.pathExtension.lowercased()
        let ext = UTType(filenameExtension: originalExtension)?.identifier == outputType
            ? originalExtension : (UTType(outputType)?.preferredFilenameExtension ?? "png")
        let scratch = fm.temporaryDirectory.appendingPathComponent("PDFPress-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }
        let candidate = scratch.appendingPathComponent("compressed.\(ext)")
        guard let destination = CGImageDestinationCreateWithURL(candidate as CFURL, outputType as CFString, count, nil) else {
            throw CompressionError.message("The compressed image could not be created.")
        }
        if var global = CGImageSourceCopyProperties(source, nil) as? [String: Any] {
            // FrameInfo carries decoder timing values that otherwise override
            // per-frame encoder properties. Let AddImage supply frame durations.
            if var png = global[kCGImagePropertyPNGDictionary as String] as? [String: Any] {
                png.removeValue(forKey: kCGImagePropertyAPNGFrameInfoArray as String)
                png.removeValue(forKey: kCGImagePropertyAPNGCanvasPixelWidth as String)
                png.removeValue(forKey: kCGImagePropertyAPNGCanvasPixelHeight as String)
                global[kCGImagePropertyPNGDictionary as String] = png
            }
            if var gif = global[kCGImagePropertyGIFDictionary as String] as? [String: Any] {
                gif.removeValue(forKey: kCGImagePropertyGIFFrameInfoArray as String)
                global[kCGImagePropertyGIFDictionary as String] = gif
            }
            CGImageDestinationSetProperties(destination, global as CFDictionary)
        }
        var expectedSizes: [(Int, Int)] = []
        var expectedOrientations: [Int] = []
        for index in 0..<count {
            try cancellation.check()
            guard var props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [String: Any],
                  let full = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                throw CompressionError.message("An image frame could not be read. Your original is unchanged.")
            }
            let originalOrientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            let resized = options.maxDimension > 0 && max(full.width, full.height) > options.maxDimension
            let image: CGImage
            if resized {
                let settings: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: options.maxDimension]
                guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, index, settings as CFDictionary) else {
                    throw CompressionError.message("The image could not be resized.")
                }
                image = thumbnail
                props[kCGImagePropertyOrientation as String] = 1
                // Remove stale orientation and dimensions inside EXIF/TIFF after applying rotation.
                if var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] {
                    tiff[kCGImagePropertyTIFFOrientation as String] = 1
                    props[kCGImagePropertyTIFFDictionary as String] = tiff
                }
                if var exif = props[kCGImagePropertyExifDictionary as String] as? [String: Any] {
                    exif[kCGImagePropertyExifPixelXDimension as String] = image.width
                    exif[kCGImagePropertyExifPixelYDimension as String] = image.height
                    props[kCGImagePropertyExifDictionary as String] = exif
                }
            } else { image = full }
            props[kCGImagePropertyPixelWidth as String] = image.width
            props[kCGImagePropertyPixelHeight as String] = image.height
            props[kCGImageDestinationLossyCompressionQuality as String] = quality.imageQuality
            if outputType == UTType.png.identifier {
                var png = props[kCGImagePropertyPNGDictionary as String] as? [String: Any] ?? [:]
                png[kCGImagePropertyPNGCompressionFilter as String] = 0xf8
                // The APNG writer quantizes float32 delays to milliseconds.
                // Round to the nearest millisecond and bias away from the lower
                // boundary to avoid truncating 120 ms to 119 ms on write.
                if let delay = png[kCGImagePropertyAPNGUnclampedDelayTime as String] as? NSNumber {
                    let duration = (delay.doubleValue * 1000).rounded() / 1000 + 0.000001
                    png[kCGImagePropertyAPNGDelayTime as String] = duration
                    png[kCGImagePropertyAPNGUnclampedDelayTime as String] = duration
                }
                props[kCGImagePropertyPNGDictionary as String] = png
            }
            if outputType == UTType.tiff.identifier {
                var tiff = props[kCGImagePropertyTIFFDictionary as String] as? [String: Any] ?? [:]
                tiff[kCGImagePropertyTIFFCompression as String] = 5 // LZW, lossless.
                props[kCGImagePropertyTIFFDictionary as String] = tiff
            }
            if outputType == UTType.jpeg.identifier && hasAlpha(image) {
                throw CompressionError.message("JPEG cannot preserve transparency. Choose PNG instead.")
            }
            CGImageDestinationAddImage(destination, image, props as CFDictionary)
            expectedSizes.append((image.width, image.height))
            expectedOrientations.append(resized ? 1 : originalOrientation)
        }
        try cancellation.check()
        guard CGImageDestinationFinalize(destination) else {
            throw CompressionError.message("Image compression failed. Your original is unchanged.")
        }
        try cancellation.check()
        guard let verified = CGImageSourceCreateWithURL(candidate as CFURL, nil),
              CGImageSourceGetCount(verified) == count else {
            throw CompressionError.message("The compressed image could not be verified. Your original is unchanged.")
        }
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(verified, index, nil),
                  image.width == expectedSizes[index].0, image.height == expectedSizes[index].1 else {
                throw CompressionError.message("Image dimensions changed unexpectedly. Your original is unchanged.")
            }
            let props = CGImageSourceCopyPropertiesAtIndex(verified, index, nil) as? [String: Any] ?? [:]
            let orientation = (props[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue ?? 1
            guard orientation == expectedOrientations[index] else {
                throw CompressionError.message("Image orientation changed unexpectedly. Choose PNG or JPEG.")
            }
            if let original = CGImageSourceCreateImageAtIndex(source, index, nil), hasAlpha(original), !hasAlpha(image) {
                throw CompressionError.message("The output lost transparency. Choose PNG to preserve it.")
            }
        }
        return try Compressor.save(candidate: candidate, input: input, directory: directory, cancellation: cancellation)
    }
}
