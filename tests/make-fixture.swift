#!/usr/bin/env swift
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// Generates a deterministic multi-page PDF: each page a solid primary fill.
// Usage: swift tests/make-fixture.swift <output.pdf> [pageCount]
// Default pageCount = 5 -> red, green, blue, yellow, magenta.

// One explicit sRGB color space; colors built in it so no conversion occurs
// when filled into the PDF context (keeps the fixture pixel-exact).
let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
func srgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> CGColor {
    return CGColor(colorSpace: sRGB, components: [r, g, b, 1])!
}
let fills: [(name: String, color: CGColor)] = [
    ("red",     srgb(1, 0, 0)),
    ("green",   srgb(0, 1, 0)),
    ("blue",    srgb(0, 0, 1)),
    ("yellow",  srgb(1, 1, 0)),
    ("magenta", srgb(1, 0, 1)),
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
