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
        print("\(result.name): \(result.pageCount) page(s) in \(result.pagesDir.lastPathComponent)")
    }
    exit(anySucceeded ? 0 : 1)
}
