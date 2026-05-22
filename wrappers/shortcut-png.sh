#!/bin/zsh
# pdf-to-images Shortcut dispatcher. The format and the engine source are
# substituted at build time by build-wrappers.sh.
#
# A .shortcut is a single signed file, not a bundle, so it cannot carry a
# sibling engine script. Instead the full engine source is embedded below and
# written to a temp file at run time. Receives PDF file paths as positional
# arguments from the Quick Action.
#
# Runs safely both interactively (Finder Quick Action) and non-interactively
# (agents, CI, other scripts). It NEVER opens a blocking modal dialog: user
# messaging goes through non-blocking notifications, and stderr always carries
# the full text. Set PDF_TO_IMAGES_QUIET=1 to suppress notifications entirely.

FORMAT="png"

# notify <title> <message>
# Always writes to stderr. Additionally posts a non-blocking macOS notification
# unless PDF_TO_IMAGES_QUIET is set. Never blocks — no `display alert`.
# The title/message are passed to osascript as `run` arguments, never
# interpolated into the AppleScript source, so quotes in a filename or error
# message cannot break the command.
notify() {
  print -r -- "$1: $2" >&2
  [ -n "${PDF_TO_IMAGES_QUIET:-}" ] && return 0
  osascript -e 'on run {t, m}' \
            -e 'display notification m with title t' \
            -e 'end run' \
            -- "$1" "$2" >/dev/null 2>&1 || true
}

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
  notify "PDF to ${FORMAT:u}" "Xcode developer tools required. Run this action again after macOS finishes installing them."
  # Trigger the macOS "install developer tools" popup — only when interactive.
  # Headless callers (PDF_TO_IMAGES_QUIET set) must not spawn an install GUI.
  [ -z "${PDF_TO_IMAGES_QUIET:-}" ] && /usr/bin/swift --version >/dev/null 2>&1
  exit 1
fi

# Write the embedded engine to a temp file, run it, clean up.
ENGINE="$(/usr/bin/mktemp -t pdf-to-images).swift"
trap 'rm -f "$ENGINE"' EXIT

/bin/cat > "$ENGINE" <<'PDF_TO_IMAGES_ENGINE'
#!/usr/bin/env swift
import Foundation
import PDFKit
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Output format

enum OutputFormat: String {
    case jpg
    case png

    var fileExtension: String { rawValue }

    var utType: CFString {
        switch self {
        case .jpg: return UTType.jpeg.identifier as CFString
        case .png: return UTType.png.identifier as CFString
        }
    }
}

// MARK: - Argument parsing

enum ParseError: Error, CustomStringConvertible {
    case missingFormatValue
    case unknownFormat(String)
    case noPDFsGiven

    var description: String {
        switch self {
        case .missingFormatValue:
            return "--format requires a value (jpg or png)"
        case .unknownFormat(let value):
            return "unknown format '\(value)' (expected jpg or png)"
        case .noPDFsGiven:
            return "no PDF files given"
        }
    }
}

struct Arguments {
    var format: OutputFormat
    var pdfPaths: [String]
}

func parseArguments(_ argv: [String]) -> Result<Arguments, ParseError> {
    var format: OutputFormat = .jpg
    var pdfPaths: [String] = []
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        if arg == "--format" {
            guard i + 1 < argv.count else {
                return .failure(.missingFormatValue)
            }
            guard let parsed = OutputFormat(rawValue: argv[i + 1].lowercased()) else {
                return .failure(.unknownFormat(argv[i + 1]))
            }
            format = parsed
            i += 2
        } else {
            pdfPaths.append(arg)
            i += 1
        }
    }
    guard !pdfPaths.isEmpty else {
        return .failure(.noPDFsGiven)
    }
    return .success(Arguments(format: format, pdfPaths: pdfPaths))
}

// MARK: - Rendering

let renderDPI: CGFloat = 144.0
let jpegQuality: CGFloat = 0.85

/// One explicit sRGB color space shared by every render context and fill color.
/// Using a single space end-to-end avoids color-space conversion, which would
/// otherwise shift vivid colors (pure red would rasterize as 255,38,0).
let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

/// Build an opaque sRGB color. Components are sRGB R,G,B in 0...1.
func sRGBColor(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    return CGColor(colorSpace: sRGBColorSpace, components: [r, g, b, 1])!
}

/// Render a single PDF page to a CGImage at renderDPI on a white background.
func renderPage(_ page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = renderDPI / 72.0
    let pixelWidth = Int((bounds.width * scale).rounded())
    let pixelHeight = Int((bounds.height * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }

    let colorSpace = sRGBColorSpace
    guard let ctx = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    ctx.setFillColor(sRGBColor(1, 1, 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
    // PDFPage.draw(with:to:) maps PDF coordinate space into the context;
    // no explicit Y-flip is needed — the API absorbs it.
    page.draw(with: .mediaBox, to: ctx)
    return ctx.makeImage()
}

/// Encode a CGImage to disk in the given format.
func writeImage(_ image: CGImage, to url: URL, format: OutputFormat) -> Bool {
    guard let dest = CGImageDestinationCreateWithURL(
        url as CFURL, format.utType, 1, nil
    ) else { return false }
    var props: [CFString: Any] = [:]
    if format == .jpg {
        props[kCGImageDestinationLossyCompressionQuality] = jpegQuality
    }
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    return CGImageDestinationFinalize(dest)
}

let montageThumbWidth: CGFloat = 400.0
let montageSeparator: CGFloat = 4.0

/// Build a near-square grid montage of the given page images.
/// Returns the encoded montage CGImage, or nil on failure.
func buildMontage(pageImages: [CGImage]) -> CGImage? {
    let n = pageImages.count
    guard n > 0 else { return nil }
    let cols = Int(ceil(Double(n).squareRoot()))
    let rows = Int(ceil(Double(n) / Double(cols)))

    // Uniform cell: thumbWidth wide, height from the tallest scaled page.
    var cellHeight: CGFloat = 0
    var scaledSizes: [CGSize] = []
    for image in pageImages {
        let w = CGFloat(image.width)
        let h = CGFloat(image.height)
        let scale = montageThumbWidth / w
        let size = CGSize(width: montageThumbWidth, height: (h * scale).rounded())
        scaledSizes.append(size)
        cellHeight = max(cellHeight, size.height)
    }

    let cellW = montageThumbWidth + montageSeparator
    let cellH = cellHeight + montageSeparator
    let canvasW = Int(cellW * CGFloat(cols) + montageSeparator)
    let canvasH = Int(cellH * CGFloat(rows) + montageSeparator)

    let colorSpace = sRGBColorSpace
    guard let ctx = CGContext(
        data: nil, width: canvasW, height: canvasH,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    // Gray separator background, then white cells.
    ctx.setFillColor(sRGBColor(0.8, 0.8, 0.8))
    ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

    for (index, image) in pageImages.enumerated() {
        let col = index % cols
        let row = index / cols
        // CoreGraphics origin is bottom-left; lay rows out top-to-bottom.
        let cellX = montageSeparator + CGFloat(col) * cellW
        let cellY = CGFloat(canvasH) - cellH - CGFloat(row) * cellH
        ctx.setFillColor(sRGBColor(1, 1, 1))
        ctx.fill(CGRect(x: cellX, y: cellY + montageSeparator,
                        width: montageThumbWidth, height: cellHeight))
        let size = scaledSizes[index]
        // Center the page within the uniform cell.
        let drawX = cellX
        let drawY = cellY + montageSeparator + (cellHeight - size.height) / 2
        ctx.draw(image, in: CGRect(x: drawX, y: drawY,
                                   width: size.width, height: size.height))
    }
    return ctx.makeImage()
}

// MARK: - Per-PDF processing

struct PDFResult {
    let name: String
    let pageCount: Int
    let pagesDir: URL
    let pageImages: [URL]
    let montageURL: URL?
}

/// Process one PDF: render every page into <name>_pages/. Returns nil on failure.
func processPDF(at path: String, format: OutputFormat) -> PDFResult? {
    let pdfURL = URL(fileURLWithPath: path)

    // Pre-flight the path so the error names the actual problem, not a
    // generic "cannot open" — a wrapper surfaces this text in an alert.
    let fm = FileManager.default
    var isDirectory: ObjCBool = false
    guard fm.fileExists(atPath: path, isDirectory: &isDirectory) else {
        FileHandle.standardError.write(Data("error: file not found: '\(path)'\n".utf8))
        return nil
    }
    if isDirectory.boolValue {
        FileHandle.standardError.write(Data("error: not a file (is a directory): '\(path)'\n".utf8))
        return nil
    }

    guard let doc = PDFDocument(url: pdfURL) else {
        FileHandle.standardError.write(Data("error: not a valid PDF: '\(path)'\n".utf8))
        return nil
    }
    let pageCount = doc.pageCount
    guard pageCount > 0 else {
        FileHandle.standardError.write(Data("error: PDF has no pages: '\(path)'\n".utf8))
        return nil
    }

    let baseName = pdfURL.deletingPathExtension().lastPathComponent
    let parentDir = pdfURL.deletingLastPathComponent()
    let pagesDir = parentDir.appendingPathComponent("\(baseName)_pages", isDirectory: true)

    // Overwrite cleanly: remove any existing subdir, recreate fresh. A failed
    // removal must not be ignored — leftover stale images would corrupt output.
    if fm.fileExists(atPath: pagesDir.path) {
        do {
            try fm.removeItem(at: pagesDir)
        } catch {
            FileHandle.standardError.write(Data("error: cannot remove '\(pagesDir.path)': \(error)\n".utf8))
            return nil
        }
    }
    do {
        try fm.createDirectory(at: pagesDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("error: cannot create '\(pagesDir.path)': \(error)\n".utf8))
        return nil
    }

    let padWidth = String(pageCount).count
    var pageImages: [URL] = []
    // Keep the rendered CGImages so the montage reuses them directly instead of
    // re-reading and re-decoding every page from disk.
    var pageCGImages: [CGImage] = []
    for index in 0..<pageCount {
        guard let page = doc.page(at: index), let image = renderPage(page) else {
            // "Render every page" is the contract — a single failure fails the
            // whole PDF rather than silently producing an incomplete set.
            FileHandle.standardError.write(Data("error: cannot render page \(index + 1) of '\(path)'\n".utf8))
            return nil
        }
        let pageNumber = String(format: "%0\(padWidth)d", index + 1)
        let pageURL = pagesDir.appendingPathComponent("page-\(pageNumber).\(format.fileExtension)")
        guard writeImage(image, to: pageURL, format: format) else {
            FileHandle.standardError.write(Data("error: cannot write '\(pageURL.path)'\n".utf8))
            return nil
        }
        pageImages.append(pageURL)
        pageCGImages.append(image)
    }

    // Montage: skip for single-page PDFs (it would just duplicate the page).
    var montageURL: URL? = nil
    if pageCGImages.count > 1, let montage = buildMontage(pageImages: pageCGImages) {
        let url = parentDir.appendingPathComponent("\(baseName)_montage.\(format.fileExtension)")
        if writeImage(montage, to: url, format: format) {
            montageURL = url
        } else {
            FileHandle.standardError.write(Data("error: cannot write montage for '\(path)'\n".utf8))
        }
    }

    return PDFResult(name: baseName, pageCount: pageImages.count,
                     pagesDir: pagesDir, pageImages: pageImages, montageURL: montageURL)
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
switch parseArguments(argv) {
case .failure(let error):
    FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
    exit(2)
case .success(let args):
    var anySucceeded = false
    for path in args.pdfPaths {
        guard let result = processPDF(at: path, format: args.format) else { continue }
        anySucceeded = true
        let montageNote = result.montageURL != nil ? " + montage" : ""
        print("\(result.name): \(result.pageCount) page(s) in \(result.pagesDir.lastPathComponent)\(montageNote)")
    }
    exit(anySucceeded ? 0 : 1)
}
PDF_TO_IMAGES_ENGINE

OUTPUT="$(/usr/bin/swift "$ENGINE" --format "$FORMAT" "$@" 2>&1)"
STATUS=$?
# Drop CoreGraphics' own CG_PDF_VERBOSE chatter from what we show the user.
OUTPUT="$(printf '%s\n' "$OUTPUT" | /usr/bin/grep -v 'CG_PDF_VERBOSE' || true)"

if [ $STATUS -eq 0 ]; then
  notify "PDF to ${FORMAT:u}" "$OUTPUT"
else
  notify "PDF to ${FORMAT:u} failed" "$OUTPUT"
fi
exit $STATUS
