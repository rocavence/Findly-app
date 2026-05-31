#!/usr/bin/env swift
//
// Render Findly's app icon at 1024×1024 as Resources/icon-1024.png.
// Run via `swift Scripts/make-icon.swift` from the project root.
//

import AppKit
import CoreGraphics

let size: CGFloat = 1024
let inset: CGFloat = 96
let squircleCorner: CGFloat = 228   // matches macOS Tahoe app squircle proportion

let space = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(
    data: nil,
    width: Int(size),
    height: Int(size),
    bitsPerComponent: 8,
    bytesPerRow: 0,
    space: space,
    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
) else {
    fatalError("Failed to create CGContext")
}

let bounds = CGRect(x: 0, y: 0, width: size, height: size)
ctx.clear(bounds)

// Squircle: the rounded-square outer shape of every macOS icon.
let squircleRect = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let squirclePath = CGPath(roundedRect: squircleRect, cornerWidth: squircleCorner, cornerHeight: squircleCorner, transform: nil)

// Background: blue gradient.
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

let bgColors = [
    NSColor(red: 0.22, green: 0.58, blue: 1.00, alpha: 1.0).cgColor,
    NSColor(red: 0.05, green: 0.28, blue: 0.85, alpha: 1.0).cgColor
] as CFArray
let bgGradient = CGGradient(colorsSpace: space, colors: bgColors, locations: [0.0, 1.0])!
ctx.drawLinearGradient(
    bgGradient,
    start: CGPoint(x: squircleRect.minX, y: squircleRect.maxY),
    end:   CGPoint(x: squircleRect.maxX, y: squircleRect.minY),
    options: []
)

// Subtle top glow (Liquid-Glass-ish sheen).
let sheenColors = [
    NSColor.white.withAlphaComponent(0.18).cgColor,
    NSColor.white.withAlphaComponent(0.0).cgColor
] as CFArray
let sheen = CGGradient(colorsSpace: space, colors: sheenColors, locations: [0.0, 0.55])!
ctx.drawLinearGradient(
    sheen,
    start: CGPoint(x: squircleRect.midX, y: squircleRect.maxY),
    end:   CGPoint(x: squircleRect.midX, y: squircleRect.midY),
    options: []
)
ctx.restoreGState()

// Inner drawer sliding out from the right edge of the squircle. Inside it we
// paint a Miller-column file browser so the icon reads as what Findly is — a
// drawer of files — not just a blank window.
let winHeight: CGFloat = squircleRect.height * 0.68
let winWidth:  CGFloat = squircleRect.width  * 0.66
let winY = squircleRect.midY - winHeight / 2
let winX = squircleRect.maxX - winWidth + 60   // sticks past the right edge
let winRect = CGRect(x: winX, y: winY, width: winWidth, height: winHeight)
let winCorner: CGFloat = 72
let winPath = CGPath(roundedRect: winRect, cornerWidth: winCorner, cornerHeight: winCorner, transform: nil)

// Brand blue reused for the selection highlight and a file accent.
let brandBlue = NSColor(red: 0.16, green: 0.55, blue: 1.00, alpha: 1.0)

func fillRoundedRect(_ r: CGRect, radius: CGFloat, color: NSColor) {
    ctx.setFillColor(color.cgColor)
    ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.fillPath()
}

// Clip everything we draw next to the squircle so the drawer is partially hidden.
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

// Soft drop shadow toward the lower-left for depth.
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: -12, height: -20),
    blur: 40,
    color: NSColor.black.withAlphaComponent(0.32).cgColor
)
ctx.setFillColor(NSColor(white: 0.98, alpha: 1.0).cgColor)
ctx.addPath(winPath)
ctx.fillPath()
ctx.restoreGState()

// Everything from here is clipped to the drawer's rounded shape.
ctx.saveGState()
ctx.addPath(winPath)
ctx.clip()

// Title bar with a search pill — a nod to "Find"ly.
let titleH: CGFloat = 116
let titleRect = CGRect(x: winRect.minX, y: winRect.maxY - titleH, width: winRect.width, height: titleH)
ctx.setFillColor(NSColor(white: 0.93, alpha: 1.0).cgColor)
ctx.fill(titleRect)
// Hairline under the title bar.
ctx.setFillColor(NSColor(white: 0.80, alpha: 1.0).cgColor)
ctx.fill(CGRect(x: titleRect.minX, y: titleRect.minY, width: titleRect.width, height: 3))

// Content geometry: anchor to the visible (un-clipped) part of the drawer.
let pad: CGFloat = 46
let contentMinX = winRect.minX + pad
let contentMaxX = squircleRect.maxX - pad
let contentWidth = contentMaxX - contentMinX

// Search pill in the title bar.
let pillH: CGFloat = 60
let pillRect = CGRect(x: contentMinX, y: titleRect.midY - pillH / 2, width: contentWidth, height: pillH)
fillRoundedRect(pillRect, radius: pillH / 2, color: NSColor(white: 0.99, alpha: 1.0))
// Magnifier glyph: a small ring + handle on the left of the pill.
ctx.setStrokeColor(brandBlue.cgColor)
ctx.setLineCap(.round)
let ringR: CGFloat = 15
let ringC = CGPoint(x: pillRect.minX + 34, y: pillRect.midY)
ctx.setLineWidth(7)
ctx.strokeEllipse(in: CGRect(x: ringC.x - ringR, y: ringC.y - ringR, width: ringR * 2, height: ringR * 2))
ctx.move(to: CGPoint(x: ringC.x + ringR * 0.72, y: ringC.y - ringR * 0.72))
ctx.addLine(to: CGPoint(x: ringC.x + ringR * 1.5, y: ringC.y - ringR * 1.5))
ctx.strokePath()

// Two Miller columns of file rows below the title bar.
let colGap: CGFloat = 28
let col1Width = contentWidth * 0.52
let col2X = contentMinX + col1Width + colGap
let col2Width = contentMaxX - col2X

let rowH: CGFloat = 56
let rowGap: CGFloat = 26
let rowRadius: CGFloat = 14
let listTop = titleRect.minY - 40          // first row's top edge
let iconSize: CGFloat = 38

func drawRow(x: CGFloat, top: CGFloat, width: CGFloat,
             selected: Bool, iconColor: NSColor) {
    let rowRect = CGRect(x: x - 14, y: top - rowH, width: width + 28, height: rowH)
    if selected {
        fillRoundedRect(rowRect, radius: rowRadius, color: brandBlue)
    }
    // File icon swatch.
    let iconRect = CGRect(x: x, y: rowRect.midY - iconSize / 2, width: iconSize, height: iconSize)
    fillRoundedRect(iconRect, radius: 8, color: selected ? NSColor.white : iconColor)
    // File name bar.
    let barH: CGFloat = 18
    let barX = iconRect.maxX + 20
    let barRect = CGRect(x: barX, y: rowRect.midY - barH / 2, width: x + width - barX, height: barH)
    fillRoundedRect(barRect, radius: barH / 2,
                    color: selected ? NSColor.white : NSColor(white: 0.78, alpha: 1.0))
}

let col1Icons = [brandBlue, NSColor(white: 0.72, alpha: 1.0), NSColor(white: 0.72, alpha: 1.0),
                 NSColor(red: 0.45, green: 0.78, blue: 0.42, alpha: 1.0), NSColor(white: 0.72, alpha: 1.0)]
for (i, color) in col1Icons.enumerated() {
    let top = listTop - CGFloat(i) * (rowH + rowGap)
    drawRow(x: contentMinX, top: top, width: col1Width - 14, selected: i == 1, iconColor: color)
}

// Second column (the drilled-into folder) — fewer rows, lighter.
let col2Icons = [NSColor(white: 0.72, alpha: 1.0),
                 NSColor(red: 1.00, green: 0.74, blue: 0.30, alpha: 1.0),
                 NSColor(white: 0.72, alpha: 1.0)]
for (i, color) in col2Icons.enumerated() {
    let top = listTop - CGFloat(i) * (rowH + rowGap)
    drawRow(x: col2X, top: top, width: col2Width - 14, selected: false, iconColor: color)
}

ctx.restoreGState() // end drawer clip
ctx.restoreGState() // end squircle clip

// Save PNG.
guard let cg = ctx.makeImage() else { fatalError("makeImage failed") }
let rep = NSBitmapImageRep(cgImage: cg)
let data = rep.representation(using: .png, properties: [:])!
let outURL = URL(fileURLWithPath: "Resources/icon-1024.png")
try data.write(to: outURL)
print("Wrote \(outURL.path)")
