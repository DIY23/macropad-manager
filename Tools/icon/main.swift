import Foundation
import AppKit

// Draws the app icon at 1024x1024 and writes icon_1024.png.
// Big Sur style: squircle plate, key grid, one encoder.

let S: CGFloat = 1024
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
guard let ctx = NSGraphicsContext.current?.cgContext else { exit(1) }

let inset: CGFloat = 64
let rect = CGRect(x: inset, y: inset, width: S - inset * 2, height: S - inset * 2)
let radius = rect.width * 0.2237

let squircle = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

// Drop shadow under the plate
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 40,
              color: NSColor.black.withAlphaComponent(0.35).cgColor)
ctx.addPath(squircle)
ctx.setFillColor(NSColor(calibratedRed: 0.10, green: 0.42, blue: 0.24, alpha: 1).cgColor)
ctx.fillPath()
ctx.restoreGState()

// Plate gradient
ctx.saveGState()
ctx.addPath(squircle)
ctx.clip()
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                      colors: [NSColor(calibratedRed: 0.22, green: 0.80, blue: 0.42, alpha: 1).cgColor,
                               NSColor(calibratedRed: 0.06, green: 0.40, blue: 0.22, alpha: 1).cgColor] as CFArray,
                      locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])

// Key grid: 3 columns x 3 rows on the left
let cols = 3, rows = 3
let gridX = rect.minX + rect.width * 0.10
let gridY = rect.minY + rect.height * 0.12
let gridW = rect.width * 0.52
let gap = gridW * 0.085
let cell = (gridW - gap * CGFloat(cols - 1)) / CGFloat(cols)
for r in 0..<rows {
    for c in 0..<cols {
        let x = gridX + CGFloat(c) * (cell + gap)
        let y = gridY + CGFloat(rows - 1 - r) * (cell + gap)
        let k = CGRect(x: x, y: y, width: cell, height: cell)
        let path = CGPath(roundedRect: k, cornerWidth: cell * 0.20, cornerHeight: cell * 0.20, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(NSColor(calibratedRed: 0.13, green: 0.15, blue: 0.16, alpha: 1).cgColor)
        ctx.fillPath()
        // top highlight
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
        ctx.fill(CGRect(x: k.minX, y: k.midY, width: k.width, height: k.height * 0.5))
        ctx.restoreGState()
    }
}

// The encoder: metallic circle on the right, slightly larger (as on the pad)
let knobR = rect.width * 0.155
let knobC = CGPoint(x: rect.maxX - rect.width * 0.215, y: rect.minY + rect.height * 0.30)
let knobRect = CGRect(x: knobC.x - knobR, y: knobC.y - knobR, width: knobR * 2, height: knobR * 2)
let angular = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                         colors: [NSColor(white: 0.95, alpha: 1).cgColor,
                                  NSColor(white: 0.55, alpha: 1).cgColor,
                                  NSColor(white: 0.90, alpha: 1).cgColor,
                                  NSColor(white: 0.45, alpha: 1).cgColor] as CFArray,
                         locations: [0, 0.35, 0.65, 1])!
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 18,
              color: NSColor.black.withAlphaComponent(0.45).cgColor)
ctx.addEllipse(in: knobRect); ctx.clip()
ctx.drawLinearGradient(angular, start: CGPoint(x: knobRect.minX, y: knobRect.maxY),
                       end: CGPoint(x: knobRect.maxX, y: knobRect.minY), options: [])
ctx.restoreGState()
ctx.addEllipse(in: knobRect)
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.55).cgColor)
ctx.setLineWidth(6); ctx.strokePath()

// knob indicator
ctx.saveGState()
ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.92).cgColor)
ctx.setLineWidth(10); ctx.setLineCap(.round)
ctx.move(to: CGPoint(x: knobC.x, y: knobC.y + knobR * 0.42))
ctx.addLine(to: CGPoint(x: knobC.x, y: knobC.y + knobR * 0.86))
ctx.strokePath()
ctx.restoreGState()

ctx.restoreGState()   // end squircle clip

img.unlockFocus()

let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
