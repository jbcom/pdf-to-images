# pdf-to-images Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [x]`) syntax for tracking.

**Goal:** Replace the single-page `sips`-based Automator workflow with a portable Swift engine that renders every PDF page to JPG or PNG plus a montage, wrapped by four macOS Quick Actions, with release-please CI/CD.

**Architecture:** One `pdf-to-images.swift` engine (PDFKit + CoreGraphics, zero Homebrew deps) renders pages and builds montages. Four thin wrappers (Automator workflow + Shortcut, for each of jpg/png) call the engine with a hard-pinned `--format`. GitHub Actions: `ci.yml` runs a deterministic primary-color integration test on macOS, `release.yml` runs release-please, `cd.yml` zips the four wrappers onto each Release.

**Tech Stack:** Swift 6 (Xcode Command Line Tools), PDFKit, CoreGraphics/ImageIO, Automator `.workflow` plists, macOS Shortcuts, GitHub Actions, release-please.

---

## Background for the implementing engineer

- **No Homebrew, ever.** The engine uses only frameworks bundled with macOS. `swift` itself ships with the Xcode Command Line Tools; if a user lacks them, invoking `swift` triggers the OS "install developer tools" popup — that is the *only* acceptable install prompt.
- **Spec:** `docs/superpowers/specs/2026-05-22-pdf-to-jpg-every-page-design.md`. Read it before starting.
- **Repo is already un-forked** to `jbcom/pdf-to-images` (standalone, `isFork=false`). History preserved. Do not re-run any `gh repo delete`.
- **`swift` path:** `swift` is on PATH via Xcode; scripts invoke it as `swift` (the wrappers add a CLT-presence check).
- **All GitHub Action `uses:` are SHA-pinned.** SHAs in this plan were resolved live from GitHub on 2026-05-22. If a task adds a new action, resolve its SHA with `gh api repos/<owner>/<repo>/git/ref/tags/<tag>` rather than guessing.
- **Conventional Commits.** Each task ends in one commit.

## File Structure

| File | Responsibility |
|---|---|
| `pdf-to-images.swift` | The engine: arg parsing, PDF→page images, montage. The only logic file. |
| `tests/make-fixture.swift` | Generates the deterministic primary-color test PDF. |
| `tests/run-integration-test.sh` | Drives the engine on the fixture, asserts pixels + geometry, both formats. |
| `tests/check-pixels.swift` | Helper: reads an image, prints the RGB of its center (or a given point). Used by the test script. |
| `wrappers/dispatcher.sh.tmpl` | Single source for the wrapper shell body; `{{FORMAT}}` placeholder. |
| `build-wrappers.sh` | Renders the template + assembles the four wrapper bundles from `wrappers/`. |
| `Convert PDF to JPG.workflow/` | Automator Quick Action, jpg. Engine bundled in `Contents/`. |
| `Convert PDF to PNG.workflow/` | Automator Quick Action, png. |
| `Convert PDF to JPG.shortcut` | Shortcuts Quick Action, jpg (built via shortcuts-playground). |
| `Convert PDF to PNG.shortcut` | Shortcuts Quick Action, png. |
| `version.txt` | Version string, bumped by release-please. |
| `release-please-config.json` | release-please config (`simple` type). |
| `.release-please-manifest.json` | release-please version manifest. |
| `.github/workflows/ci.yml` | PR: typecheck + integration test on macOS. |
| `.github/workflows/release.yml` | main push: release-please. |
| `.github/workflows/cd.yml` | post-Release: zip + attach the four wrappers. |
| `.github/dependabot.yml` | Monthly github-actions bumps. |
| `LICENSE` | MIT, crediting the original author. |
| `README.md` | Rewritten: Releases install, jpg/png, montage, attribution. |

The old `Convert PDF to JPG.workflow/` is overwritten in place (Task 8); the old `download_zip.png` / `thumbnail.png` / `video.mp4` are kept until the README rewrite (Task 12) decides their fate.

---

## Task 1: Engine skeleton — argument parsing

**Files:**
- Create: `pdf-to-images.swift`
- Test: `tests/run-integration-test.sh` (created later; arg parsing is checked manually here)

- [x] **Step 1: Write the engine skeleton with format parsing**

Create `pdf-to-images.swift`:

```swift
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

struct Arguments {
    var format: OutputFormat
    var pdfPaths: [String]
}

func parseArguments(_ argv: [String]) -> Result<Arguments, String> {
    var format: OutputFormat = .jpg
    var pdfPaths: [String] = []
    var i = 0
    while i < argv.count {
        let arg = argv[i]
        if arg == "--format" {
            guard i + 1 < argv.count else {
                return .failure("--format requires a value (jpg or png)")
            }
            guard let parsed = OutputFormat(rawValue: argv[i + 1].lowercased()) else {
                return .failure("unknown format '\(argv[i + 1])' (expected jpg or png)")
            }
            format = parsed
            i += 2
        } else {
            pdfPaths.append(arg)
            i += 1
        }
    }
    guard !pdfPaths.isEmpty else {
        return .failure("no PDF files given")
    }
    return .success(Arguments(format: format, pdfPaths: pdfPaths))
}

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
switch parseArguments(argv) {
case .failure(let message):
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
case .success(let args):
    FileHandle.standardError.write(Data("parsed: format=\(args.format.rawValue) pdfs=\(args.pdfPaths.count)\n".utf8))
    exit(0)
}
```

- [x] **Step 2: Verify it typechecks and parses**

Run:
```bash
swiftc -typecheck pdf-to-images.swift
swift pdf-to-images.swift --format png a.pdf b.pdf ; echo "exit=$?"
swift pdf-to-images.swift --format bogus a.pdf ; echo "exit=$?"
swift pdf-to-images.swift ; echo "exit=$?"
```
Expected: typecheck silent (exit 0); first run prints `parsed: format=png pdfs=2` exit=0; second prints `error: unknown format 'bogus' ...` exit=2; third prints `error: no PDF files given` exit=2.

- [x] **Step 3: Commit**

```bash
git add pdf-to-images.swift
git commit -m "feat: pdf-to-images engine skeleton with --format parsing"
```

---

## Task 2: Engine — render every page to images

**Files:**
- Modify: `pdf-to-images.swift`

- [x] **Step 1: Add the page-rendering core**

In `pdf-to-images.swift`, **above the `// MARK: - Entry point` section**, insert:

```swift
// MARK: - Rendering

let renderDPI: CGFloat = 144.0
let jpegQuality: CGFloat = 0.85

/// Render a single PDF page to a CGImage at renderDPI on a white background.
func renderPage(_ page: PDFPage) -> CGImage? {
    let bounds = page.bounds(for: .mediaBox)
    let scale = renderDPI / 72.0
    let pixelWidth = Int((bounds.width * scale).rounded())
    let pixelHeight = Int((bounds.height * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0 else { return nil }

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil,
        width: pixelWidth,
        height: pixelHeight,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -bounds.origin.x, y: -bounds.origin.y)
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
```

- [x] **Step 2: Add the per-PDF processing function**

In `pdf-to-images.swift`, **above `// MARK: - Entry point`** and below the rendering section, insert:

```swift
// MARK: - Per-PDF processing

struct PDFResult {
    let name: String
    let pageCount: Int
    let pagesDir: URL
    let pageImages: [URL]
}

/// Process one PDF: render every page into <name>_pages/. Returns nil on failure.
func processPDF(at path: String, format: OutputFormat) -> PDFResult? {
    let pdfURL = URL(fileURLWithPath: path)
    guard let doc = PDFDocument(url: pdfURL) else {
        FileHandle.standardError.write(Data("error: cannot open PDF '\(path)'\n".utf8))
        return nil
    }
    let pageCount = doc.pageCount
    guard pageCount > 0 else {
        FileHandle.standardError.write(Data("error: PDF '\(path)' has no pages\n".utf8))
        return nil
    }

    let baseName = pdfURL.deletingPathExtension().lastPathComponent
    let parentDir = pdfURL.deletingLastPathComponent()
    let pagesDir = parentDir.appendingPathComponent("\(baseName)_pages", isDirectory: true)

    // Overwrite cleanly: remove any existing subdir, recreate fresh.
    try? FileManager.default.removeItem(at: pagesDir)
    do {
        try FileManager.default.createDirectory(at: pagesDir, withIntermediateDirectories: true)
    } catch {
        FileHandle.standardError.write(Data("error: cannot create '\(pagesDir.path)': \(error)\n".utf8))
        return nil
    }

    let padWidth = String(pageCount).count
    var pageImages: [URL] = []
    for index in 0..<pageCount {
        guard let page = doc.page(at: index), let image = renderPage(page) else {
            FileHandle.standardError.write(Data("error: cannot render page \(index + 1) of '\(path)'\n".utf8))
            continue
        }
        let pageNumber = String(format: "%0\(padWidth)d", index + 1)
        let pageURL = pagesDir.appendingPathComponent("page-\(pageNumber).\(format.fileExtension)")
        if writeImage(image, to: pageURL, format: format) {
            pageImages.append(pageURL)
        } else {
            FileHandle.standardError.write(Data("error: cannot write '\(pageURL.path)'\n".utf8))
        }
    }

    guard !pageImages.isEmpty else { return nil }
    return PDFResult(name: baseName, pageCount: pageImages.count, pagesDir: pagesDir, pageImages: pageImages)
}
```

- [x] **Step 3: Wire processing into the entry point**

In `pdf-to-images.swift`, replace the `case .success(let args):` block with:

```swift
case .success(let args):
    var anySucceeded = false
    for path in args.pdfPaths {
        guard let result = processPDF(at: path, format: args.format) else { continue }
        anySucceeded = true
        print("\(result.name): \(result.pageCount) page(s) in \(result.pagesDir.lastPathComponent)")
    }
    exit(anySucceeded ? 0 : 1)
}
```

- [x] **Step 4: Verify it typechecks**

Run: `swiftc -typecheck pdf-to-images.swift`
Expected: silent, exit 0.

- [x] **Step 5: Commit**

```bash
git add pdf-to-images.swift
git commit -m "feat: render every PDF page to per-page images"
```

---

## Task 3: Engine — montage

**Files:**
- Modify: `pdf-to-images.swift`

- [x] **Step 1: Add the montage builder**

In `pdf-to-images.swift`, in the `// MARK: - Rendering` section, **below `writeImage`**, insert:

```swift
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

    let colorSpace = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: canvasW, height: canvasH,
        bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
    ) else { return nil }

    // Gray separator background, then white cells.
    ctx.setFillColor(CGColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))

    for (index, image) in pageImages.enumerated() {
        let col = index % cols
        let row = index / cols
        // CoreGraphics origin is bottom-left; lay rows out top-to-bottom.
        let cellX = montageSeparator + CGFloat(col) * cellW
        let cellY = CGFloat(canvasH) - cellH - CGFloat(row) * cellH
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
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
```

- [x] **Step 2: Call the montage builder from `processPDF`**

In `pdf-to-images.swift`, in `processPDF`, replace:

```swift
    guard !pageImages.isEmpty else { return nil }
    return PDFResult(name: baseName, pageCount: pageImages.count, pagesDir: pagesDir, pageImages: pageImages)
```

with:

```swift
    guard !pageImages.isEmpty else { return nil }

    // Montage: skip for single-page PDFs (it would just duplicate the page).
    var montageURL: URL? = nil
    if pageImages.count > 1 {
        let cgImages = pageImages.compactMap { url -> CGImage? in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
            return CGImageSourceCreateImageAtIndex(src, 0, nil)
        }
        if cgImages.count == pageImages.count, let montage = buildMontage(pageImages: cgImages) {
            let url = parentDir.appendingPathComponent("\(baseName)_montage.\(format.fileExtension)")
            if writeImage(montage, to: url, format: format) {
                montageURL = url
            } else {
                FileHandle.standardError.write(Data("error: cannot write montage for '\(path)'\n".utf8))
            }
        }
    }

    return PDFResult(name: baseName, pageCount: pageImages.count,
                     pagesDir: pagesDir, pageImages: pageImages, montageURL: montageURL)
```

- [x] **Step 3: Extend `PDFResult` and the summary line**

In `pdf-to-images.swift`, replace the `struct PDFResult` definition with:

```swift
struct PDFResult {
    let name: String
    let pageCount: Int
    let pagesDir: URL
    let pageImages: [URL]
    let montageURL: URL?
}
```

Then in the entry point, replace the `print(...)` line with:

```swift
        let montageNote = result.montageURL != nil ? " + montage" : ""
        print("\(result.name): \(result.pageCount) page(s) in \(result.pagesDir.lastPathComponent)\(montageNote)")
```

- [x] **Step 4: Verify it typechecks**

Run: `swiftc -typecheck pdf-to-images.swift`
Expected: silent, exit 0.

- [x] **Step 5: Commit**

```bash
git add pdf-to-images.swift
git commit -m "feat: build near-square montage of all pages"
```

---

## Task 4: Test fixture generator

**Files:**
- Create: `tests/make-fixture.swift`

- [x] **Step 1: Write the fixture generator**

Create `tests/make-fixture.swift`:

```swift
#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Generates a deterministic multi-page PDF: each page a solid primary fill.
// Usage: swift tests/make-fixture.swift <output.pdf> [pageCount]
// Default pageCount = 5 -> red, green, blue, yellow, magenta.

let fills: [(name: String, color: CGColor)] = [
    ("red",     CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
    ("green",   CGColor(red: 0, green: 1, blue: 0, alpha: 1)),
    ("blue",    CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
    ("yellow",  CGColor(red: 1, green: 1, blue: 0, alpha: 1)),
    ("magenta", CGColor(red: 1, green: 0, blue: 1, alpha: 1)),
]

let argv = Array(CommandLine.arguments.dropFirst())
guard let outPath = argv.first else {
    FileHandle.standardError.write(Data("usage: make-fixture.swift <output.pdf> [pageCount]\n".utf8))
    exit(2)
}
let pageCount = argv.count > 1 ? (Int(argv[1]) ?? 5) : 5
guard pageCount >= 1 && pageCount <= fills.count else {
    FileHandle.standardError.write(Data("pageCount must be 1...\(fills.count)\n".utf8))
    exit(2)
}

let pageRect = CGRect(x: 0, y: 0, width: 612, height: 792) // US Letter at 72dpi
var mediaBox = pageRect
guard let ctx = CGContext(consumer: CGDataConsumer(url: URL(fileURLWithPath: outPath) as CFURL)!,
                          mediaBox: &mediaBox, nil) else {
    FileHandle.standardError.write(Data("cannot create PDF context\n".utf8))
    exit(1)
}
for i in 0..<pageCount {
    ctx.beginPDFPage(nil)
    ctx.setFillColor(fills[i].color)
    ctx.fill(pageRect)
    ctx.endPDFPage()
}
ctx.closePDF()
print("wrote \(pageCount)-page fixture to \(outPath)")
```

- [x] **Step 2: Verify it runs**

Run:
```bash
swift tests/make-fixture.swift /tmp/fixture.pdf 5 && ls -l /tmp/fixture.pdf
```
Expected: prints `wrote 5-page fixture to /tmp/fixture.pdf`, file exists and is non-empty.

- [x] **Step 3: Commit**

```bash
git add tests/make-fixture.swift
git commit -m "test: deterministic primary-color PDF fixture generator"
```

---

## Task 5: Pixel-check helper

**Files:**
- Create: `tests/check-pixels.swift`

- [x] **Step 1: Write the pixel reader**

Create `tests/check-pixels.swift`:

```swift
#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO

// Reads an image and prints "WIDTHxHEIGHT R G B" for the pixel at a fractional
// position (default center 0.5 0.5). Used by run-integration-test.sh.
// Usage: swift tests/check-pixels.swift <image> [fracX fracY]

let argv = Array(CommandLine.arguments.dropFirst())
guard let imgPath = argv.first else {
    FileHandle.standardError.write(Data("usage: check-pixels.swift <image> [fracX fracY]\n".utf8))
    exit(2)
}
let fracX = argv.count > 1 ? (Double(argv[1]) ?? 0.5) : 0.5
let fracY = argv.count > 2 ? (Double(argv[2]) ?? 0.5) : 0.5

guard let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: imgPath) as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
    FileHandle.standardError.write(Data("cannot read image '\(imgPath)'\n".utf8))
    exit(1)
}

let w = image.width
let h = image.height
let colorSpace = CGColorSpaceCreateDeviceRGB()
var pixel = [UInt8](repeating: 0, count: 4)
guard let ctx = CGContext(data: &pixel, width: 1, height: 1, bitsPerComponent: 8,
                          bytesPerRow: 4, space: colorSpace,
                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
    FileHandle.standardError.write(Data("cannot create 1x1 context\n".utf8))
    exit(1)
}
// Draw the image offset so the target pixel lands at (0,0) of the 1x1 context.
let px = Int(Double(w) * fracX)
let py = Int(Double(h) * fracY)
ctx.draw(image, in: CGRect(x: -px, y: -(h - 1 - py), width: w, height: h))
print("\(w)x\(h) \(pixel[0]) \(pixel[1]) \(pixel[2])")
```

- [x] **Step 2: Verify it reads a known image**

Run:
```bash
swift tests/make-fixture.swift /tmp/fixture.pdf 1
swift pdf-to-images.swift --format png /tmp/fixture.pdf
swift tests/check-pixels.swift /tmp/fixture_pages/page-1.png
```
Expected: last command prints something like `1224x1584 255 0 0` (red page 1, 144 DPI doubles 612x792). RGB must be `255 0 0` (PNG is lossless).

- [x] **Step 3: Commit**

```bash
git add tests/check-pixels.swift
git commit -m "test: image center-pixel reader helper"
```

---

## Task 6: Integration test script

**Files:**
- Create: `tests/run-integration-test.sh`

- [x] **Step 1: Write the integration test**

Create `tests/run-integration-test.sh`:

```bash
#!/usr/bin/env bash
# Integration test for pdf-to-images.swift.
# Generates a 5-page primary-color PDF, runs the engine in both formats,
# and asserts page count, per-page fill colors, and montage geometry.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENGINE="$REPO_ROOT/pdf-to-images.swift"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Expected fills, page order: red green blue yellow magenta.
EXPECTED_RGB=("255 0 0" "0 255 0" "0 0 255" "255 255 0" "255 0 255")

fail() { echo "FAIL: $*" >&2; exit 1; }

# Color comparison with per-channel tolerance.
rgb_matches() {
  # args: "r g b" "r g b" tolerance
  local a=($1) b=($2) tol=$3
  for i in 0 1 2; do
    local d=$(( ${a[$i]} - ${b[$i]} ))
    d=${d#-}
    (( d > tol )) && return 1
  done
  return 0
}

for FORMAT in jpg png; do
  echo "=== format: $FORMAT ==="
  PDF="$WORK/sample_$FORMAT.pdf"
  swift "$REPO_ROOT/tests/make-fixture.swift" "$PDF" 5 >/dev/null
  swift "$ENGINE" --format "$FORMAT" "$PDF" >/dev/null

  PAGES_DIR="$WORK/sample_${FORMAT}_pages"
  [ -d "$PAGES_DIR" ] || fail "$FORMAT: pages dir missing"

  # PNG is lossless -> tolerance 0; JPG -> small tolerance.
  if [ "$FORMAT" = png ]; then TOL=0; else TOL=24; fi

  for n in 1 2 3 4 5; do
    PAGE="$PAGES_DIR/page-$n.$FORMAT"
    [ -f "$PAGE" ] || fail "$FORMAT: $PAGE missing"
    GOT=$(swift "$REPO_ROOT/tests/check-pixels.swift" "$PAGE" | cut -d' ' -f2-)
    WANT="${EXPECTED_RGB[$((n-1))]}"
    rgb_matches "$GOT" "$WANT" "$TOL" \
      || fail "$FORMAT: page $n fill = ($GOT), expected ($WANT)"
    echo "  page $n fill ok ($GOT)"
  done

  MONTAGE="$WORK/sample_${FORMAT}_montage.$FORMAT"
  [ -f "$MONTAGE" ] || fail "$FORMAT: montage missing"
  # 5 pages -> cols=ceil(sqrt(5))=3, rows=ceil(5/3)=2. Sample cell (row0,col0)
  # center -> page 1 (red). Fractional center of top-left cell ~ (0.167, 0.25).
  CELL_RGB=$(swift "$REPO_ROOT/tests/check-pixels.swift" "$MONTAGE" 0.167 0.25 | cut -d' ' -f2-)
  rgb_matches "$CELL_RGB" "255 0 0" "$TOL" \
    || fail "$FORMAT: montage top-left cell = ($CELL_RGB), expected red"
  echo "  montage top-left cell ok ($CELL_RGB)"
done

echo "ALL INTEGRATION TESTS PASSED"
```

- [x] **Step 2: Make it executable and run it**

Run:
```bash
chmod +x tests/run-integration-test.sh
./tests/run-integration-test.sh
```
Expected: prints per-page "fill ok" lines for both formats and finally `ALL INTEGRATION TESTS PASSED`, exit 0.

If the montage cell sample fails, adjust the fractional coordinates: the test comment documents the grid math (cols=3, rows=2 for 5 pages); the top-left cell center is at `x ≈ 0.5/3`, `y ≈ 0.5/2` from the top. `check-pixels.swift` measures `fracY` from the top.

- [x] **Step 3: Commit**

```bash
git add tests/run-integration-test.sh
git commit -m "test: primary-color integration test for both formats"
```

---

## Task 7: Wrapper dispatcher template + build script

**Files:**
- Create: `wrappers/dispatcher.sh.tmpl`
- Create: `build-wrappers.sh`

- [x] **Step 1: Write the dispatcher template**

Create `wrappers/dispatcher.sh.tmpl`:

```bash
#!/bin/zsh
# pdf-to-images wrapper dispatcher. {{FORMAT}} is substituted at build time.
# Receives PDF file paths as positional arguments from the Quick Action.

FORMAT="{{FORMAT}}"

# Locate the engine bundled next to this script.
SCRIPT_DIR="${0:A:h}"
ENGINE="$SCRIPT_DIR/pdf-to-images.swift"

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
  osascript -e 'display alert "Developer tools required" message "Click Install when macOS prompts, then run this action again."' >/dev/null 2>&1 || true
  # Trigger the macOS "install developer tools" popup.
  /usr/bin/swift --version >/dev/null 2>&1
  exit 1
fi

if [ ! -f "$ENGINE" ]; then
  osascript -e 'display alert "pdf-to-images" message "Engine script not found next to the workflow."' >/dev/null 2>&1 || true
  exit 1
fi

OUTPUT="$(/usr/bin/swift "$ENGINE" --format "$FORMAT" "$@" 2>&1)"
STATUS=$?

if [ $STATUS -eq 0 ]; then
  osascript -e "display notification \"$OUTPUT\" with title \"PDF to ${FORMAT:u}\"" >/dev/null 2>&1 || true
else
  osascript -e "display alert \"PDF to ${FORMAT:u} failed\" message \"$OUTPUT\"" >/dev/null 2>&1 || true
fi
exit $STATUS
```

- [x] **Step 2: Write the wrapper build script**

Create `build-wrappers.sh`:

```bash
#!/usr/bin/env bash
# Assembles the four Quick Action wrappers from the template + engine.
# Automator .workflow bundles are built here; .shortcut files are built
# separately via the shortcuts-playground skill and committed directly.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMPL="$REPO_ROOT/wrappers/dispatcher.sh.tmpl"
ENGINE="$REPO_ROOT/pdf-to-images.swift"

build_workflow() {
  local format="$1" upper="$2"
  local wf="$REPO_ROOT/Convert PDF to $upper.workflow"
  local contents="$wf/Contents"
  rm -rf "$wf"
  mkdir -p "$contents"

  # Bundle the engine inside the workflow.
  cp "$ENGINE" "$contents/pdf-to-images.swift"

  # Render the dispatcher for this format.
  local dispatcher
  dispatcher="$(sed "s/{{FORMAT}}/$format/g" "$TMPL")"

  # Escape for embedding in the plist <string>.
  local esc
  esc="$(printf '%s' "$dispatcher" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')"

  cat > "$contents/document.wflow" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>AMApplicationBuild</key><string>523</string>
	<key>AMApplicationVersion</key><string>2.10</string>
	<key>AMDocumentVersion</key><string>2</string>
	<key>actions</key>
	<array>
		<dict>
			<key>action</key>
			<dict>
				<key>AMAccepts</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Optional</key><true/>
					<key>Types</key>
					<array><string>com.apple.cocoa.path</string></array>
				</dict>
				<key>AMActionVersion</key><string>2.0.3</string>
				<key>AMProvides</key>
				<dict>
					<key>Container</key><string>List</string>
					<key>Types</key>
					<array><string>com.apple.cocoa.path</string></array>
				</dict>
				<key>ActionBundlePath</key>
				<string>/System/Library/Automator/Run Shell Script.action</string>
				<key>ActionName</key><string>Run Shell Script</string>
				<key>ActionParameters</key>
				<dict>
					<key>COMMAND_STRING</key>
					<string>$esc</string>
					<key>CheckedForUserDefaultShell</key><true/>
					<key>inputMethod</key><integer>1</integer>
					<key>shell</key><string>/bin/zsh</string>
					<key>source</key><string></string>
				</dict>
				<key>BundleIdentifier</key><string>com.apple.RunShellScript</string>
				<key>CFBundleVersion</key><string>2.0.3</string>
				<key>Class Name</key><string>RunShellScriptAction</string>
				<key>InputUUID</key><string>00000000-0000-0000-0000-000000000001</string>
				<key>OutputUUID</key><string>00000000-0000-0000-0000-000000000002</string>
				<key>UUID</key><string>00000000-0000-0000-0000-000000000003</string>
			</dict>
		</dict>
	</array>
	<key>connectors</key><dict/>
	<key>workflowMetaData</key>
	<dict>
		<key>applicationBundleID</key><string>com.apple.finder</string>
		<key>inputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject.PDF</string>
		<key>outputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>presentationMode</key><integer>15</integer>
		<key>processesInput</key><false/>
		<key>serviceApplicationBundleID</key><string>com.apple.finder</string>
		<key>serviceInputTypeIdentifier</key>
		<string>com.apple.Automator.fileSystemObject.PDF</string>
		<key>serviceOutputTypeIdentifier</key>
		<string>com.apple.Automator.nothing</string>
		<key>serviceProcessesInput</key><false/>
		<key>systemImageName</key><string>NSActionTemplate</string>
		<key>useAutomaticInputType</key><false/>
		<key>workflowTypeIdentifier</key>
		<string>com.apple.Automator.servicesMenu</string>
	</dict>
</dict>
</plist>
PLIST

  cat > "$contents/Info.plist" <<INFO
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>NSServices</key>
	<array>
		<dict>
			<key>NSMenuItem</key>
			<dict><key>default</key><string>Convert PDF to $upper</string></dict>
			<key>NSMessage</key><string>runWorkflowAsService</string>
			<key>NSRequiredContext</key>
			<dict><key>NSApplicationIdentifier</key><string>com.apple.finder</string></dict>
			<key>NSSendFileTypes</key>
			<array><string>com.adobe.pdf</string></array>
		</dict>
	</array>
</dict>
</plist>
INFO

  echo "built: $wf"
}

build_workflow jpg JPG
build_workflow png PNG
echo "workflows built. Shortcuts are built via the shortcuts-playground skill."
```

Note the input type change vs. the original: `AMAccepts`/`AMProvides` use
`com.apple.cocoa.path` (file paths), and `NSSendFileTypes` is restricted to
`com.adobe.pdf` so the Quick Action only appears for PDFs — closing audit
item #4 (non-PDF inputs).

- [x] **Step 3: Run the build and verify the workflows**

Run:
```bash
chmod +x build-wrappers.sh
./build-wrappers.sh
plutil -lint "Convert PDF to JPG.workflow/Contents/document.wflow"
plutil -lint "Convert PDF to JPG.workflow/Contents/Info.plist"
plutil -lint "Convert PDF to PNG.workflow/Contents/document.wflow"
ls "Convert PDF to JPG.workflow/Contents/"
```
Expected: `built:` lines for both; all `plutil -lint` print `OK`; the `Contents/` listing shows `document.wflow`, `Info.plist`, `pdf-to-images.swift`.

- [x] **Step 4: Commit**

```bash
git add wrappers/dispatcher.sh.tmpl build-wrappers.sh "Convert PDF to JPG.workflow" "Convert PDF to PNG.workflow"
git commit -m "feat: build JPG and PNG Automator Quick Action wrappers"
```

---

## Task 8: Remove the old workflow remnants

**Files:**
- Delete: old `Convert PDF to JPG.workflow/Contents/QuickLook/` if present and stale

- [x] **Step 1: Confirm the rebuilt workflow replaced the old one**

Run:
```bash
grep -l "sips" "Convert PDF to JPG.workflow/Contents/document.wflow" && echo "STALE" || echo "clean"
git status --short
```
Expected: prints `clean` (the rebuilt `document.wflow` has no `sips`). `git status` shows the workflow dirs as modified/added from Task 7.

- [x] **Step 2: Remove a stale QuickLook thumbnail if it survived the rebuild**

The `build-wrappers.sh` `rm -rf` already removes the whole bundle before
rebuilding, so no `QuickLook/Thumbnail.png` remains. Verify:

```bash
test -e "Convert PDF to JPG.workflow/Contents/QuickLook" && echo "present" || echo "absent"
```
Expected: `absent`. If `present`, run `git rm -r "Convert PDF to JPG.workflow/Contents/QuickLook"`.

- [x] **Step 3: Commit (only if Step 2 removed anything)**

```bash
git add -A && git commit -m "chore: drop stale QuickLook thumbnail from workflow bundle"
```

If nothing was removed, skip this commit.

---

## Task 9: Shortcuts — JPG and PNG Quick Actions

**Files:**
- Create: `Convert PDF to JPG.shortcut`
- Create: `Convert PDF to PNG.shortcut`

- [x] **Step 1: Build the JPG Shortcut**

Invoke the shortcuts-playground build command:

```
/shortcuts-playground:build Quick Action named "Convert PDF to JPG" that receives PDF files from Quick Actions in Finder, runs a Run Shell Script action with shell /bin/zsh that passes the input file paths as arguments, and whose script body is the contents of wrappers/dispatcher.sh.tmpl with {{FORMAT}} replaced by jpg and the engine path pointing at a sibling pdf-to-images.swift
```

Save the resulting `.shortcut` file to the repo root as `Convert PDF to JPG.shortcut`.

- [x] **Step 2: Build the PNG Shortcut**

```
/shortcuts-playground:build Quick Action named "Convert PDF to PNG" identical to the JPG one but with {{FORMAT}} replaced by png
```

Save to repo root as `Convert PDF to PNG.shortcut`.

- [x] **Step 3: Verify the Shortcuts are well-formed**

Run:
```bash
file "Convert PDF to JPG.shortcut" "Convert PDF to PNG.shortcut"
```
Expected: both report as data/plist files (signed `.shortcut` archives). The shortcuts-playground skill validates structure during the build; if it reports errors, fix them before committing.

- [x] **Step 4: Commit**

```bash
git add "Convert PDF to JPG.shortcut" "Convert PDF to PNG.shortcut"
git commit -m "feat: add JPG and PNG Shortcuts Quick Actions"
```

---

## Task 10: release-please configuration

**Files:**
- Create: `version.txt`
- Create: `release-please-config.json`
- Create: `.release-please-manifest.json`

- [x] **Step 1: Create the version file**

Create `version.txt`:

```
1.0.0
```

- [x] **Step 2: Create the release-please config**

Create `release-please-config.json`:

```json
{
  "$schema": "https://raw.githubusercontent.com/googleapis/release-please/main/schemas/config.json",
  "release-type": "simple",
  "include-v-in-tag": true,
  "draft": false,
  "prerelease": false,
  "packages": {
    ".": {
      "release-type": "simple",
      "package-name": "pdf-to-images",
      "changelog-path": "CHANGELOG.md",
      "extra-files": ["version.txt"]
    }
  },
  "changelog-sections": [
    { "type": "feat", "section": "Features" },
    { "type": "fix", "section": "Bug Fixes" },
    { "type": "perf", "section": "Performance Improvements" },
    { "type": "refactor", "section": "Code Refactoring" },
    { "type": "test", "section": "Tests" },
    { "type": "build", "section": "Build System" },
    { "type": "ci", "section": "Continuous Integration" },
    { "type": "docs", "section": "Documentation" },
    { "type": "chore", "section": "Miscellaneous Chores", "hidden": true },
    { "type": "style", "section": "Styles", "hidden": true }
  ]
}
```

- [x] **Step 3: Create the manifest**

Create `.release-please-manifest.json`:

```json
{
  ".": "1.0.0"
}
```

- [x] **Step 4: Mark version.txt for release-please tracking**

release-please's `simple` updater replaces a version string in `extra-files`
only when the file contains a recognizable version. `version.txt` containing a
bare `1.0.0` is updated automatically. No annotation comment is needed for a
plain version file.

Verify the JSON is valid (`plutil -lint` only validates plists, not JSON —
use a JSON parser):
```bash
python3 -c "import json; json.load(open('release-please-config.json')); print('config OK')"
python3 -c "import json; json.load(open('.release-please-manifest.json')); print('manifest OK')"
```
Expected: `config OK` and `manifest OK`.

- [x] **Step 5: Commit**

```bash
git add version.txt release-please-config.json .release-please-manifest.json
git commit -m "build: add release-please configuration"
```

---

## Task 11: GitHub Actions workflows

**Files:**
- Create: `.github/workflows/ci.yml`
- Create: `.github/workflows/release.yml`
- Create: `.github/workflows/cd.yml`
- Create: `.github/dependabot.yml`

- [x] **Step 1: Create the CI workflow**

Create `.github/workflows/ci.yml`:

```yaml
name: CI

on:
  pull_request:

permissions:
  contents: read

concurrency:
  group: ci-${{ github.event.pull_request.number || github.ref }}
  cancel-in-progress: true

jobs:
  test:
    name: Typecheck and integration test
    runs-on: macos-latest
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - name: Swift version
        run: swift --version

      - name: Typecheck engine
        run: swiftc -typecheck pdf-to-images.swift

      - name: Typecheck test helpers
        run: |
          swiftc -typecheck tests/make-fixture.swift
          swiftc -typecheck tests/check-pixels.swift

      - name: Integration test
        run: ./tests/run-integration-test.sh
```

- [x] **Step 2: Create the release workflow**

Create `.github/workflows/release.yml`:

```yaml
name: Release

on:
  push:
    branches:
      - main

permissions:
  contents: write
  pull-requests: write

concurrency:
  group: release
  cancel-in-progress: false

jobs:
  release-please:
    name: release-please
    runs-on: ubuntu-latest
    outputs:
      release_created: ${{ steps.release.outputs.release_created }}
      tag_name: ${{ steps.release.outputs.tag_name }}
    steps:
      - name: release-please
        id: release
        uses: googleapis/release-please-action@45996ed1f6d02564a971a2fa1b5860e934307cf7 # v5.0.0
        with:
          token: ${{ secrets.CI_GITHUB_TOKEN }}
          config-file: release-please-config.json
          manifest-file: .release-please-manifest.json
```

- [x] **Step 3: Create the CD workflow**

Create `.github/workflows/cd.yml`:

```yaml
name: Deploy Release Artifacts

on:
  workflow_run:
    workflows:
      - Release
    types:
      - completed
    branches:
      - main
  workflow_dispatch:

permissions:
  contents: write

concurrency:
  group: cd
  cancel-in-progress: false

jobs:
  attach-artifacts:
    name: Zip and attach wrappers
    runs-on: macos-latest
    if: ${{ github.event_name == 'workflow_dispatch' || github.event.workflow_run.conclusion == 'success' }}
    steps:
      - name: Checkout
        uses: actions/checkout@de0fac2e4500dabe0009e67214ff5f5447ce83dd # v6.0.2

      - name: Resolve latest release tag
        id: rel
        run: |
          TAG="$(gh release view --json tagName --jq .tagName)"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Build wrappers
        run: ./build-wrappers.sh

      - name: Zip wrappers
        run: |
          mkdir -p dist
          for name in "Convert PDF to JPG.workflow" "Convert PDF to PNG.workflow" \
                      "Convert PDF to JPG.shortcut" "Convert PDF to PNG.shortcut"; do
            [ -e "$name" ] || { echo "missing: $name" >&2; exit 1; }
            ditto -c -k --sequesterRsrc --keepParent "$name" "dist/${name// /-}.zip"
          done
          ls -l dist

      - name: Attach to release
        uses: softprops/action-gh-release@b4309332981a82ec1c5618f44dd2e27cc8bfbfda # v3.0.0
        with:
          tag_name: ${{ steps.rel.outputs.tag }}
          files: dist/*.zip
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}
```

- [x] **Step 4: Create dependabot config**

Create `.github/dependabot.yml`:

```yaml
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: monthly
      day: monday
      time: '06:00'
      timezone: America/Los_Angeles
    open-pull-requests-limit: 5
    labels:
      - dependencies
      - github-actions
    commit-message:
      prefix: ci
      include: scope
```

- [x] **Step 5: Validate the YAML**

Run:
```bash
for f in .github/workflows/ci.yml .github/workflows/release.yml .github/workflows/cd.yml .github/dependabot.yml; do
  python3 -c "import yaml,sys; yaml.safe_load(open('$f')); print('$f OK')"
done
```
Expected: four `OK` lines.

- [x] **Step 6: Commit**

```bash
git add .github
git commit -m "ci: add CI, release-please, and release-artifact workflows"
```

---

## Task 12: LICENSE and README

**Files:**
- Create: `LICENSE`
- Modify: `README.md` (full rewrite)
- Delete: `download_zip.png`, `thumbnail.png` if no longer referenced

- [x] **Step 1: Create the MIT LICENSE crediting the original author**

Create `LICENSE`:

```
MIT License

Copyright (c) 2024 sanjeed5 (original author)
Copyright (c) 2026 Jon Bogaty

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [x] **Step 2: Rewrite the README**

Replace the entire contents of `README.md` with:

```markdown
# pdf-to-images

Convert **every page** of a PDF into JPG or PNG images — plus a montage of all
pages — straight from the macOS Finder. Local, private, zero dependencies.

This project began as a fork of
[sanjeed5/convert_pdf_to_jpg_on_mac](https://github.com/sanjeed5/convert_pdf_to_jpg_on_mac);
thanks to the original author for the starting point.

## What it does

Right-click a PDF in Finder → **Quick Actions** → **Convert PDF to JPG**
(or **PNG**). For `Report.pdf` you get:

- `Report_pages/` — `page-001.jpg`, `page-002.jpg`, … one image per page.
- `Report_montage.jpg` — a near-square grid of every page (skipped for
  single-page PDFs).

Rendering is 144 DPI; JPG uses quality 0.85; PNG is lossless.

## Install

Download the action you want from the
[latest release](https://github.com/jbcom/pdf-to-images/releases/latest):

| File | Installs into |
|---|---|
| `Convert-PDF-to-JPG.workflow.zip` | Automator Quick Action (JPG) |
| `Convert-PDF-to-PNG.workflow.zip` | Automator Quick Action (PNG) |
| `Convert-PDF-to-JPG.shortcut.zip` | Shortcuts Quick Action (JPG) |
| `Convert-PDF-to-PNG.shortcut.zip` | Shortcuts Quick Action (PNG) |

Unzip and double-click the `.workflow` or `.shortcut` to install it. macOS adds
it to the Quick Actions menu in Finder.

Apple is phasing Automator out in favor of Shortcuts — the `.shortcut` versions
are the forward-looking choice; the `.workflow` versions remain for older macOS.

## Requirements

- macOS (modern versions).
- The Xcode Command Line Tools. If they are missing, the first run shows the
  standard macOS "install developer tools" prompt — click Install and run the
  action again. **No Homebrew, no other downloads.**

## How it works

A single Swift script, `pdf-to-images.swift`, uses Apple's PDFKit and
CoreGraphics to render and montage pages. Each Quick Action is a thin wrapper
that calls it with a fixed `--format`. The engine has no platform-specific
dependencies, so Linux file-manager integrations are a natural future addition.

## Development

```bash
# Run the engine directly
swift pdf-to-images.swift --format png path/to/file.pdf

# Rebuild the Automator wrappers from the template + engine
./build-wrappers.sh

# Run the integration test
./tests/run-integration-test.sh
```

## License

[MIT](LICENSE). Original work © sanjeed5; modifications © Jon Bogaty.
```

- [x] **Step 3: Remove now-unreferenced images**

The rewritten README no longer references `download_zip.png` or `thumbnail.png`.
`video.mp4` is also no longer referenced. Remove them:

```bash
git rm download_zip.png thumbnail.png video.mp4
```

- [x] **Step 4: Verify no dangling references**

Run:
```bash
grep -nE 'download_zip|thumbnail\.png|video\.mp4' README.md && echo "DANGLING" || echo "clean"
```
Expected: `clean`.

- [x] **Step 5: Commit**

```bash
git add LICENSE README.md
git commit -m "docs: MIT license and rewritten README for pdf-to-images"
```

---

## Task 13: End-to-end verification

**Files:** none (verification only)

- [x] **Step 1: Full local test pass**

Run:
```bash
swiftc -typecheck pdf-to-images.swift
./tests/run-integration-test.sh
./build-wrappers.sh
plutil -lint "Convert PDF to JPG.workflow/Contents/document.wflow"
plutil -lint "Convert PDF to PNG.workflow/Contents/document.wflow"
```
Expected: typecheck silent; integration test ends `ALL INTEGRATION TESTS PASSED`; both `plutil -lint` print `OK`.

- [x] **Step 2: Real multi-page PDF smoke test**

If a real multi-page PDF is available at `/tmp/real.pdf` (or generate a larger
fixture), run both formats and eyeball the output:

```bash
swift tests/make-fixture.swift /tmp/real.pdf 4
swift pdf-to-images.swift --format jpg /tmp/real.pdf
swift pdf-to-images.swift --format png /tmp/real.pdf
ls /tmp/real_pages/
open /tmp/real_montage.jpg
```
Expected: four `page-N.jpg` and four `page-N.png` files; `real_montage.jpg` is a
2×2 grid (4 pages → cols=2, rows=2) with red/green/blue/yellow cells.

- [x] **Step 3: Confirm clean git state and push**

```bash
git status --short
git log --oneline origin/main..HEAD
git push origin main
```
Expected: clean working tree; the task commits listed; push succeeds.

- [x] **Step 4: Post-push CI verification**

After pushing, open a PR (or push triggers `release.yml` on main directly).
Verify on GitHub:
- `CI` workflow runs on any PR and passes the integration test.
- `Release` workflow runs on the push to `main` and opens a release-please PR.
- Once the release-please PR merges, `Release` creates a tag/release and
  `Deploy Release Artifacts` attaches the four wrapper zips.

If `release.yml` fails with a permissions error, confirm the org secret
`CI_GITHUB_TOKEN` is visible to `jbcom/pdf-to-images` (org secrets scoped to
"selected repositories" must include this repo).

---

## Self-Review Notes

- **Spec coverage:** engine + `--format` (Tasks 1-3), montage with single-page
  skip (Task 3), primary-color integration test both formats (Tasks 4-6, 11),
  four wrappers (Tasks 7, 9), case-insensitive extension via `deletingPathExtension`
  (Task 2), overwrite-cleanly subdir (Task 2), non-PDF input restriction (Task 7,
  `NSSendFileTypes`), release-please simple + version.txt (Task 10), 3 workflows
  SHA-pinned (Task 11), dependabot (Task 11), un-fork already done, attribution
  + README rewrite (Task 12). All spec sections map to a task.
- **Audit items:** #1 multi-page (Task 2), #2 case sensitivity (Task 2), #3
  collisions/overwrite (Task 2), #4 non-PDF input (Task 7), #5 quality/DPI
  (Task 2 constants), #6 user feedback (Task 7 notifications).
- **Type consistency:** `OutputFormat`, `PDFResult` (final 5-field shape set in
  Task 3), `processPDF`, `renderPage`, `writeImage`, `buildMontage` names are
  consistent across tasks.
```
