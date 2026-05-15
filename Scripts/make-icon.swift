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

// Inner "window" sliding out from the right edge of the squircle.
let winHeight: CGFloat = squircleRect.height * 0.62
let winWidth:  CGFloat = squircleRect.width  * 0.50
let winY = squircleRect.midY - winHeight / 2
let winX = squircleRect.maxX - winWidth + 88   // sticks past the right edge
let winRect = CGRect(x: winX, y: winY, width: winWidth, height: winHeight)
let winCorner: CGFloat = 72
let winPath = CGPath(roundedRect: winRect, cornerWidth: winCorner, cornerHeight: winCorner, transform: nil)

// Clip everything we draw next to the squircle so the window is partially hidden.
ctx.saveGState()
ctx.addPath(squirclePath)
ctx.clip()

// Soft drop shadow toward the lower-left for depth.
ctx.saveGState()
ctx.setShadow(
    offset: CGSize(width: -10, height: -18),
    blur: 36,
    color: NSColor.black.withAlphaComponent(0.35).cgColor
)
ctx.setFillColor(NSColor.white.withAlphaComponent(0.97).cgColor)
ctx.addPath(winPath)
ctx.fillPath()
ctx.restoreGState()

// A faint horizontal "title bar" stripe to read as a window.
let titleRect = CGRect(x: winRect.minX, y: winRect.maxY - 78, width: winRect.width, height: 78)
ctx.saveGState()
ctx.addPath(winPath)
ctx.clip()
ctx.setFillColor(NSColor(white: 0.88, alpha: 1.0).cgColor)
ctx.fill(titleRect)
ctx.restoreGState()

ctx.restoreGState() // end squircle clip

// Save PNG.
guard let cg = ctx.makeImage() else { fatalError("makeImage failed") }
let rep = NSBitmapImageRep(cgImage: cg)
let data = rep.representation(using: .png, properties: [:])!
let outURL = URL(fileURLWithPath: "Resources/icon-1024.png")
try data.write(to: outURL)
print("Wrote \(outURL.path)")
