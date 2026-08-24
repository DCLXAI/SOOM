#!/usr/bin/env swift
import AppKit
import Foundation

let manager = FileManager.default
let scriptDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let iconset = scriptDirectory.appendingPathComponent("SOOM.iconset", isDirectory: true)
let output = scriptDirectory.appendingPathComponent("SOOM.icns")

try? manager.removeItem(at: iconset)
try manager.createDirectory(at: iconset, withIntermediateDirectories: true)

let variants: [(String, Int)] = [
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

func drawIcon(size: Int) throws -> Data {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { throw NSError(domain: "SOOMIcon", code: 1) }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw NSError(domain: "SOOMIcon", code: 2)
    }
    NSGraphicsContext.current = context
    context.cgContext.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)

    let tile = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 220, yRadius: 220)
    let gradient = NSGradient(colors: [
        NSColor(red: 0.49, green: 0.31, blue: 1.0, alpha: 1),
        NSColor(red: 0.28, green: 0.25, blue: 0.92, alpha: 1)
    ])!
    gradient.draw(in: tile, angle: -48)

    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
    shadow.shadowBlurRadius = 38
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    shadow.set()

    func arc(radius: CGFloat, start: CGFloat, end: CGFloat, width: CGFloat) {
        let path = NSBezierPath()
        path.appendArc(withCenter: NSPoint(x: 512, y: 512), radius: radius, startAngle: start, endAngle: end)
        path.lineWidth = width
        path.lineCapStyle = .round
        NSColor.white.setStroke()
        path.stroke()
    }

    arc(radius: 260, start: -48, end: 154, width: 112)
    arc(radius: 148, start: 132, end: 326, width: 112)
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: 474, y: 474, width: 76, height: 76)).fill()
    NSColor(red: 1.0, green: 0.35, blue: 0.25, alpha: 1).setFill()
    NSBezierPath(ovalIn: NSRect(x: 724, y: 744, width: 116, height: 116)).fill()

    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "SOOMIcon", code: 3)
    }
    return data
}

for (name, size) in variants {
    try drawIcon(size: size).write(to: iconset.appendingPathComponent(name), options: .atomic)
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.path]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else { throw NSError(domain: "SOOMIcon", code: 4) }
try? manager.removeItem(at: iconset)
print(output.path)
