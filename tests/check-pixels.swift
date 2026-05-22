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
// Clamp to the valid pixel range so fracX/fracY = 1.0 never samples off-image.
let px = min(max(Int(Double(w) * fracX), 0), max(w - 1, 0))
let py = min(max(Int(Double(h) * fracY), 0), max(h - 1, 0))
ctx.draw(image, in: CGRect(x: -px, y: -(h - 1 - py), width: w, height: h))
print("\(w)x\(h) \(pixel[0]) \(pixel[1]) \(pixel[2])")
