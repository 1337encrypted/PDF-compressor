# PDF Press

A local PDF and image compressor for Apple Silicon Macs running macOS 14 or later.

## Launch

Double-click **PDF Press.app**, or run `open "PDF Press.app"` from this folder. You can also copy the built app into your Applications folder.

## Use

1. Drop PDFs or images into the window, or click to choose files. Mixed batches are supported.
2. Choose **High quality**, **Balanced**, or **Smallest file**. Balanced is the default.
3. For images, optionally select an output format and a maximum size. **Original dimensions** preserves the image size; resizing limits the longest edge and never enlarges an image.
4. Optionally choose an output folder.
5. Click **Compress files**. Review the size reduction, compare the original and result, or open the result.

Copies are named `original-compressed.ext`. Existing files and originals are never overwritten. A numeric suffix resolves name collisions. If compression makes a file larger, the candidate is discarded and the app shows **Already compact**.

## Supported formats

| Input | Automatic output | Notes |
| --- | --- | --- |
| PDF | PDF | Ghostscript required; text normally remains selectable |
| PNG | PNG | Lossless when not resized; transparency preserved |
| JPEG/JPG | JPEG/JPG | Quality presets adjust lossy encoding |
| HEIC/HEIF | HEIC | Native macOS encoding |
| TIFF/TIF | TIFF/TIF | Lossless LZW compression; pages preserved |
| BMP | JPEG or PNG | PNG used when transparency is present |
| WebP | JPEG or PNG | Static images; PNG used when transparency is present |
| GIF | GIF | Frames, timing, and loop count preserved |
| Animated PNG | PNG | Frames and loop count preserved; duration rounds to the native encoder's millisecond precision |
| AVIF | JPEG or PNG | Static images; available when macOS can decode it |

The file picker includes only formats readable on the current Mac. Image output options are **Automatic**, **JPEG**, **PNG**, and **HEIC**. Choosing JPEG for a transparent image produces a clear error rather than removing transparency. Converting multi-frame or multi-page files into single-frame formats is rejected; use Automatic for supported GIF/APNG/TIFF files. Other multi-frame containers, including animated WebP and HEIC image sequences, are not supported.

PNG and TIFF are optimized losslessly unless resized; already optimized files may have little or no size reduction. JPEG/HEIC quality presets are 90%, 75%, and 50%. These are encoder settings, not promises of a particular file size or visual quality. PDF presets are 300, 150, and 72 dpi. Lower quality can soften images. Protected PDFs and PDFs with form or signature fields are rejected; export a flat, unprotected copy first.

## Stack and requirements

- SwiftUI and AppKit for the native Mac interface.
- PDFKit for PDF previews and page validation.
- ImageIO and CoreGraphics for image compression, resizing, orientation, and frame validation.
- Ghostscript for PDFs, installed separately through Homebrew: `brew install ghostscript`.
- Images work without Ghostscript. No images or documents are uploaded.
- Swift command-line tools are needed only to build or run the developer tests.

## Build

Run `bash build.sh`. The build creates an Apple Silicon app with a local ad-hoc signature. It is not notarized for public distribution.

The icon source is `Assets/AppIcon.png`. The build packages all standard macOS icon sizes into `.icns` and copies the same design into the in-app header. Build caches and the generated app are excluded from Git.

## Tests

Install Pillow, reportlab, and pypdf in a Python environment, then run:

```bash
PYTHON_BIN=/path/to/python bash test.sh
```

The integration checks cover PDFs, every JPEG quality preset, exact PNG pixels and transparency, image orientation and resizing, BMP/WebP/AVIF conversion, animation timing and loops, TIFF pages, HEIC when available, collision handling, invalid inputs, cancellation, and skipping larger outputs.

`Tests/AppChecks.swift` can be compiled with `-D UI_PREVIEW` alongside the application sources. It exercises the actual mixed-batch model, confirms that the in-app icon loads, and renders the empty and completed-batch views for visual review. Run this in a test `.app` bundle that includes `BrandIcon.png` in its resources.
