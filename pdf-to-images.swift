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

// MARK: - Entry point

let argv = Array(CommandLine.arguments.dropFirst())
switch parseArguments(argv) {
case .failure(let error):
    FileHandle.standardError.write(Data("error: \(error.description)\n".utf8))
    exit(2)
case .success(let args):
    FileHandle.standardError.write(Data("parsed: format=\(args.format.rawValue) pdfs=\(args.pdfPaths.count)\n".utf8))
    exit(0)
}
