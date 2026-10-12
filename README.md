# PDF Press

A local PDF compressor for Apple Silicon Macs running macOS 14 or later.

## Launch

Double-click **PDF Press.app**, or run:

From this folder, run:

```bash
open "PDF Press.app"
```

The app can also be copied into your Applications folder.

## Use

1. Drop PDFs into the window or click to choose files.
2. Choose High quality, Balanced, or Smallest file. Balanced is the default.
3. Optionally choose an output folder.
4. Click **Compress PDFs**.
5. Review the size reduction, compare the two PDFs, or open the result.

Outputs are named `original-compressed.pdf`. Existing files and originals are never overwritten. If a candidate is larger than the original, it is discarded and the app shows **Already compact**. Lower quality presets can soften images. Protected PDFs and PDFs with form or signature fields are rejected; export a flat, unprotected copy first.

## Stack and requirements

- SwiftUI and AppKit for the native Mac interface.
- PDFKit for previews and page validation.
- Ghostscript for compression; installed separately through Homebrew, not bundled in the app.
- Swift command-line tools are only needed to rebuild the source.

Ghostscript is installed on this Mac. On another Mac, run `brew install ghostscript` and click **Check again** in the app if prompted.

## Rebuild

From this folder, run `bash build.sh`. The build creates an Apple Silicon app with a local ad-hoc signature. It is not notarized for public distribution.

The icon source is `Assets/AppIcon.png`. The build produces every standard macOS icon size, packages an `.icns` file, and includes it in the signed app. Build caches and the generated app are excluded from Git.

## Integration checks

`Tests/make_fixtures.py` creates synthetic fixtures and requires Python with Pillow, reportlab, and pypdf. Compile `Sources/Compression.swift` with `Tests/Integration.swift`, then pass the fixture folder to the resulting executable. The checks cover all presets, retained text and pages, original preservation, output-name collisions, skipping larger outputs, invalid and protected files, forms, cancellation, and invalid destinations.
