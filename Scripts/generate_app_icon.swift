#!/usr/bin/env swift
import AppKit
import CoreGraphics
import Foundation

// Generates the full macOS .appiconset for ClaudeUsageVisualizer.
// Design: squircle background with a soft purple→teal gradient (matches the
// burn-rate palette), centered circular gauge with a 270° arc and a needle
// pointing into the "warm" zone (≈70%). Flat, modern macOS Big Sur+ style.

let outDir = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first
    ?? "ClaudeUsageVisualizer/Resources/Assets.xcassets/AppIcon.appiconset")

let sizes: [Int] = [16, 32, 64, 128, 256, 512, 1024]

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rect = CGRect(x: 0, y: 0, width: s, height: s)
    // Draw into a fixed-pixel CGContext. NSImage.lockFocus() picks up the
    // screen's backing scale, which silently doubles output on Retina —
    // actool then rejects the whole icon set as size-mismatched.
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(
        data: nil,
        width: size,
        height: size,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("CGContext create failed for \(size)") }

    // 1. Squircle background with gradient.
    let inset: CGFloat = s * 0.10
    let bgRect = rect.insetBy(dx: inset, dy: inset)
    let corner: CGFloat = bgRect.width * 0.225 // macOS Big Sur squircle ratio
    let bgPath = CGPath(roundedRect: bgRect, cornerWidth: corner, cornerHeight: corner, transform: nil)

    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.42, green: 0.31, blue: 0.78, alpha: 1).cgColor, // purple
        NSColor(srgbRed: 0.13, green: 0.55, blue: 0.78, alpha: 1).cgColor, // teal-blue
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(
        gradient,
        start: CGPoint(x: bgRect.minX, y: bgRect.maxY),
        end: CGPoint(x: bgRect.maxX, y: bgRect.minY),
        options: []
    )
    ctx.restoreGState()

    // 2. Subtle inner highlight (top edge sheen).
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let sheenColors = [
        NSColor(white: 1, alpha: 0.18).cgColor,
        NSColor(white: 1, alpha: 0.0).cgColor,
    ] as CFArray
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheenColors, locations: [0, 1])!
    ctx.drawLinearGradient(
        sheen,
        start: CGPoint(x: bgRect.midX, y: bgRect.maxY),
        end: CGPoint(x: bgRect.midX, y: bgRect.midY),
        options: []
    )
    ctx.restoreGState()

    // 3. Gauge arc — 270° sweep, opens downward.
    let center = CGPoint(x: rect.midX, y: rect.midY)
    let arcRadius = bgRect.width * 0.32
    let arcWidth = bgRect.width * 0.085
    let startDeg: CGFloat = 135  // bottom-left
    let endDeg: CGFloat = 405    // bottom-right (270° sweep counter-clockwise becomes clockwise here)

    // Background track (semi-transparent white).
    ctx.saveGState()
    ctx.setLineWidth(arcWidth)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor(white: 1, alpha: 0.25).cgColor)
    ctx.addArc(
        center: center,
        radius: arcRadius,
        startAngle: startDeg * .pi / 180,
        endAngle: endDeg * .pi / 180,
        clockwise: false
    )
    ctx.strokePath()
    ctx.restoreGState()

    // Filled portion (≈70% of sweep) — orange/yellow burn gradient.
    let fillFraction: CGFloat = 0.70
    let fillEndDeg = startDeg + (endDeg - startDeg) * fillFraction

    ctx.saveGState()
    ctx.setLineWidth(arcWidth)
    ctx.setLineCap(.round)
    // Solid orange — gradient-stroking an arc is fiddly; a vivid solid reads
    // better at 16×16 anyway.
    ctx.setStrokeColor(NSColor(srgbRed: 1.0, green: 0.78, blue: 0.20, alpha: 1).cgColor)
    ctx.addArc(
        center: center,
        radius: arcRadius,
        startAngle: startDeg * .pi / 180,
        endAngle: fillEndDeg * .pi / 180,
        clockwise: false
    )
    ctx.strokePath()
    ctx.restoreGState()

    // 4. Center dot.
    let dotRadius = arcWidth * 0.55
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillEllipse(in: CGRect(
        x: center.x - dotRadius,
        y: center.y - dotRadius,
        width: dotRadius * 2,
        height: dotRadius * 2
    ))

    // 5. Needle pointing at fill end angle.
    let needleAngle = fillEndDeg * .pi / 180
    let needleLen = arcRadius * 0.92
    let needleEnd = CGPoint(
        x: center.x + cos(needleAngle) * needleLen,
        y: center.y + sin(needleAngle) * needleLen
    )
    ctx.saveGState()
    ctx.setLineWidth(arcWidth * 0.32)
    ctx.setLineCap(.round)
    ctx.setStrokeColor(NSColor.white.cgColor)
    ctx.move(to: center)
    ctx.addLine(to: needleEnd)
    ctx.strokePath()
    ctx.restoreGState()

    guard let cgImage = ctx.makeImage() else {
        fatalError("makeImage failed for size \(size)")
    }
    let rep = NSBitmapImageRep(cgImage: cgImage)
    guard let png = rep.representation(using: .png, properties: [:]) else {
        fatalError("PNG encode failed for size \(size)")
    }
    return png
}

let fm = FileManager.default
try? fm.createDirectory(at: outDir, withIntermediateDirectories: true)

for size in sizes {
    let data = render(size: size)
    let url = outDir.appendingPathComponent("icon_\(size).png")
    try data.write(to: url)
    print("wrote \(url.lastPathComponent) (\(data.count) bytes)")
}

// Emit Contents.json mapping every slot to a file.
let manifest: [String: Any] = [
    "images": [
        ["idiom": "mac", "scale": "1x", "size": "16x16",   "filename": "icon_16.png"],
        ["idiom": "mac", "scale": "2x", "size": "16x16",   "filename": "icon_32.png"],
        ["idiom": "mac", "scale": "1x", "size": "32x32",   "filename": "icon_32.png"],
        ["idiom": "mac", "scale": "2x", "size": "32x32",   "filename": "icon_64.png"],
        ["idiom": "mac", "scale": "1x", "size": "128x128", "filename": "icon_128.png"],
        ["idiom": "mac", "scale": "2x", "size": "128x128", "filename": "icon_256.png"],
        ["idiom": "mac", "scale": "1x", "size": "256x256", "filename": "icon_256.png"],
        ["idiom": "mac", "scale": "2x", "size": "256x256", "filename": "icon_512.png"],
        ["idiom": "mac", "scale": "1x", "size": "512x512", "filename": "icon_512.png"],
        ["idiom": "mac", "scale": "2x", "size": "512x512", "filename": "icon_1024.png"],
    ],
    "info": ["author": "xcode", "version": 1],
]
let json = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
try json.write(to: outDir.appendingPathComponent("Contents.json"))
print("wrote Contents.json")
