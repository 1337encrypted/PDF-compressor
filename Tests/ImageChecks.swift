import Foundation
import ImageIO
import UniformTypeIdentifiers

func imageSource(_ url: URL) throws -> CGImageSource {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw CompressionError.message("Test image unreadable") }
    return source
}
func normalizedPixels(_ url: URL, frame: Int = 0) throws -> Data {
    let source = try imageSource(url)
    guard let image = CGImageSourceCreateImageAtIndex(source, frame, nil),
          let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
        throw CompressionError.message("Test pixels unreadable")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Data(bytes: context.data!, count: image.width * image.height * 4)
}

func checkImages(_ root: URL) throws {
    let fm = FileManager.default
    let destination = root.appendingPathComponent("images")
    try fm.createDirectory(at: destination, withIntermediateDirectories: true)
    let png = root.appendingPathComponent("transparent.png")
    let pngHash = try digest(png)
    let transparent = try Compressor.compress(input: png, directory: destination, quality: .balanced, cancellation: Cancellation())
    try require(transparent.output != nil, "Uncompressed PNG shrinks")
    try require(try normalizedPixels(png) == normalizedPixels(transparent.output!), "PNG pixel/alpha preservation")
    try require(try digest(png) == pngHash, "PNG original preserved")
    print("PASS: PNG compression preserves every pixel and transparency")

    let photo = root.appendingPathComponent("photo.jpg")
    var sizes: [Int64] = []
    for quality in Quality.allCases {
        let result = try Compressor.compress(input: photo, directory: destination, quality: quality, cancellation: Cancellation())
        try require(result.output != nil, "JPEG shrinks with \(quality.title)")
        sizes.append(result.outputBytes)
        let decoded = CGImageSourceCreateImageAtIndex(try imageSource(result.output!), 0, nil)!
        try require(decoded.width == 960 && decoded.height == 640, "JPEG dimensions preserved")
    }
    try require(sizes[0] > sizes[1] && sizes[1] > sizes[2], "JPEG quality presets change output size")
    print("PASS: JPEG quality presets: \(sizes)")

    let rotated = root.appendingPathComponent("rotated.jpg")
    let rotation = try Compressor.compress(input: rotated, directory: destination, quality: .balanced, cancellation: Cancellation())
    let properties = CGImageSourceCopyPropertiesAtIndex(try imageSource(rotation.output!), 0, nil) as! [String: Any]
    try require((properties[kCGImagePropertyOrientation as String] as? NSNumber)?.intValue == 6, "EXIF rotation retained")
    let resized = try Compressor.compress(input: rotated, directory: destination, quality: .balanced, cancellation: Cancellation(), imageOptions: ImageOptions(maxDimension: 320))
    let thumbnail = CGImageSourceCreateImageAtIndex(try imageSource(resized.output!), 0, nil)!
    try require(thumbnail.width == 213 && thumbnail.height == 320, "Resize applies EXIF orientation and long-edge limit")
    print("PASS: Rotated JPEG orientation and resizing")

    let collision = try Compressor.compress(input: png, directory: destination, quality: .balanced, cancellation: Cancellation())
    try require(collision.output != transparent.output, "Image output collision gets a new filename")
    try require(try normalizedPixels(transparent.output!) == normalizedPixels(png), "Existing image unchanged")

    for name in ["photo.bmp", "photo.webp", "transparent.webp", "photo.tiff", "animated.gif", "animated.png", "multipage.tiff"] {
        let input = root.appendingPathComponent(name)
        let result = try Compressor.compress(input: input, directory: destination, quality: .balanced, cancellation: Cancellation())
        let output = result.output ?? input
        let before = try imageSource(input)
        let after = try imageSource(output)
        try require(CGImageSourceGetCount(before) == CGImageSourceGetCount(after), "Frames/pages preserved in \(name)")
        if name.hasPrefix("animated") {
            for index in 0..<CGImageSourceGetCount(before) {
                try require(try normalizedPixels(input, frame: index) == normalizedPixels(output, frame: index), "Animation frame colors preserved")
                let a = CGImageSourceCopyPropertiesAtIndex(before, index, nil)! as NSDictionary
                let b = CGImageSourceCopyPropertiesAtIndex(after, index, nil)! as NSDictionary
                let key = name.hasSuffix("gif") ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
                let delay = name.hasSuffix("gif") ? kCGImagePropertyGIFUnclampedDelayTime : kCGImagePropertyAPNGUnclampedDelayTime
                let originalDelay = (a[key] as? NSDictionary)?[delay] as? NSNumber
                let outputDelay = (b[key] as? NSDictionary)?[delay] as? NSNumber
                try require(originalDelay == outputDelay, "Animation frame duration preserved")
            }
            let key = name.hasSuffix("gif") ? kCGImagePropertyGIFDictionary : kCGImagePropertyPNGDictionary
            let loop = name.hasSuffix("gif") ? kCGImagePropertyGIFLoopCount : kCGImagePropertyAPNGLoopCount
            let a = CGImageSourceCopyProperties(before, nil) as NSDictionary?
            let b = CGImageSourceCopyProperties(after, nil) as NSDictionary?
            try require((a?[key] as? NSDictionary)?[loop] as? NSNumber == (b?[key] as? NSDictionary)?[loop] as? NSNumber, "Animation loop count preserved")
        }
        if name.hasPrefix("transparent") {
            if result.output != nil { try require(output.pathExtension == "png", "Transparent WebP becomes PNG when smaller") }
            try require(try normalizedPixels(input) == normalizedPixels(output), "WebP alpha preserved")
        }
        print("PASS: \(name): \(result.inputBytes) → \(result.outputBytes) bytes; \(CGImageSourceGetCount(after)) frame(s)")
    }

    let encoders = CGImageDestinationCopyTypeIdentifiers() as! [String]
    for (type, ext) in [(UTType.heic.identifier, "heic")] where encoders.contains(type) {
        let input = root.appendingPathComponent("photo.\(ext)")
        let image = CGImageSourceCreateImageAtIndex(try imageSource(photo), 0, nil)!
        let writer = CGImageDestinationCreateWithURL(input as CFURL, type as CFString, 1, nil)!
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        try require(CGImageDestinationFinalize(writer), "Create \(ext) fixture")
        let result = try Compressor.compress(input: input, directory: destination, quality: .balanced, cancellation: Cancellation())
        try require(result.output != nil, "\(ext) compression should shrink the fixture")
        print("PASS: \(ext): \(result.inputBytes) → \(result.outputBytes) bytes")
    }
    let avif = root.appendingPathComponent("photo.avif")
    if fm.fileExists(atPath: avif.path), ImageCompressor.allowedTypes.contains(where: { $0.identifier == "public.avif" }) {
        let result = try Compressor.compress(input: avif, directory: destination, quality: .balanced, cancellation: Cancellation())
        try require(result.output != nil && result.output?.pathExtension == "jpeg", "AVIF becomes a smaller JPEG")
        print("PASS: AVIF input: \(result.inputBytes) → \(result.outputBytes) bytes")
    }
    for format in [ImageFormat.png, .jpeg, .heic] {
        let result = try Compressor.compress(input: photo, directory: destination, quality: .balanced, cancellation: Cancellation(), imageOptions: ImageOptions(format: format, maxDimension: 320))
        try require(result.output != nil, "Explicit \(format.title) output should shrink a resized photo")
        let source = try imageSource(result.output!)
        try require(CGImageSourceGetType(source)! as String == format.type!, "Selected format matches encoded data")
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil)!
        try require(max(image.width, image.height) == 320, "Explicit output format honors resize")
        print("PASS: Explicit \(format.title) image format and resize")
    }
    for name in ["animated.png", "multipage.tiff"] {
        let input = root.appendingPathComponent(name)
        let result = try Compressor.compress(input: input, directory: destination, quality: .balanced, cancellation: Cancellation(), imageOptions: ImageOptions(maxDimension: 128))
        let source = try imageSource(result.output!)
        try require(CGImageSourceGetCount(source) == 2, "Resize preserves frames/pages")
        for index in 0..<2 {
            let image = CGImageSourceCreateImageAtIndex(source, index, nil)!
            try require(max(image.width, image.height) == 128, "All frames/pages resized consistently")
        }
        print("PASS: Multi-frame resize for \(name)")
    }
    try expectFailure("Transparency cannot be silently removed for JPEG") {
        _ = try Compressor.compress(input: png, directory: destination, quality: .balanced, cancellation: Cancellation(), imageOptions: ImageOptions(format: .jpeg))
    }
    try expectFailure("Animation cannot be silently flattened") {
        _ = try Compressor.compress(input: root.appendingPathComponent("animated.gif"), directory: destination, quality: .balanced, cancellation: Cancellation(), imageOptions: ImageOptions(format: .jpeg))
    }
    try expectFailure("Broken image") { _ = try Compressor.kind(root.appendingPathComponent("broken.png")) }
    let token = Cancellation()
    token.cancel()
    try expectFailure("Image cancellation") { _ = try Compressor.compress(input: png, directory: destination, quality: .balanced, cancellation: token) }
    try expectFailure("Missing image output folder") { _ = try Compressor.compress(input: png, directory: root.appendingPathComponent("missing"), quality: .balanced, cancellation: Cancellation()) }
    let tiny = try Compressor.compress(input: root.appendingPathComponent("tiny.png"), directory: destination, quality: .balanced, cancellation: Cancellation())
    try require(tiny.outputBytes <= tiny.inputBytes, "Images never save larger candidates")
    print("PASS: Tiny image keeps only smaller output")
}
