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
