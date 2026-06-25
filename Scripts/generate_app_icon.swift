#!/usr/bin/env swift
import AppKit
import Foundation

let outputDir = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: "Zones/Resources/Assets.xcassets/AppIcon.appiconset", isDirectory: true)

let sizes: [(name: String, size: Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let corner = size * 0.18
    let background = NSBezierPath(roundedRect: rect.insetBy(dx: size * 0.04, dy: size * 0.04), xRadius: corner, yRadius: corner)
    NSColor.white.setFill()
    background.fill()

    NSColor.black.setStroke()
    background.lineWidth = max(1, size * 0.03)
    background.stroke()

    let inset = rect.insetBy(dx: size * 0.14, dy: size * 0.14)
    let columns = 3
    let columnWidth = inset.width / CGFloat(columns)

    for index in 1..<columns {
        let x = inset.minX + columnWidth * CGFloat(index)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: x, y: inset.minY))
        path.line(to: NSPoint(x: x, y: inset.maxY))
        path.lineWidth = max(1, size * 0.05)
        path.stroke()
    }

    let border = NSBezierPath(rect: inset)
    border.lineWidth = max(1, size * 0.04)
    border.stroke()

    image.unlockFocus()
    return image
}

func savePNG(_ image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let data = rep.representation(using: .png, properties: [:]) else {
        fputs("Failed to encode PNG\n", stderr)
        exit(1)
    }
    try? data.write(to: url)
}

try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

for entry in sizes {
    let image = drawIcon(size: CGFloat(entry.size))
    savePNG(image, to: outputDir.appendingPathComponent(entry.name))
}

let contents = """
{
  "images" : [
    { "filename" : "icon_16x16.png", "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png", "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png", "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png", "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png", "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
"""

try contents.write(to: outputDir.appendingPathComponent("Contents.json"), atomically: true, encoding: .utf8)
print("Generated app icons in \(outputDir.path)")
