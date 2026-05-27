#!/usr/bin/swift
import AppKit

NSApplication.shared // initialise AppKit

let size = 1024
let s = CGFloat(size)

guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: size, pixelsHigh: size,
    bitsPerSample: 8, samplesPerPixel: 4,
    hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
) else { print("Failed to create bitmap"); exit(1) }

let nsCtx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = nsCtx
let ctx = nsCtx.cgContext

// ── Background ───────────────────────────────────────────────
let r = s * 0.22
let bgPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                    cornerWidth: r, cornerHeight: r, transform: nil)
ctx.addPath(bgPath)
ctx.setFillColor(CGColor(red: 0.12, green: 0.10, blue: 0.20, alpha: 1.0))
ctx.fillPath()
ctx.addPath(bgPath)
ctx.clip()

// ── Hex grid ─────────────────────────────────────────────────
let hexR: CGFloat = s * 0.053
let colStep = hexR * 1.5
let rowStep = hexR * sqrt(3.0)

ctx.setStrokeColor(CGColor(red: 0.96, green: 0.62, blue: 0.04, alpha: 0.15))
ctx.setLineWidth(s * 0.006)

var col = 0
var px: CGFloat = hexR
while px < s + hexR {
    let yOff: CGFloat = (col % 2 == 0) ? 0 : rowStep / 2
    var py: CGFloat = yOff
    while py < s + rowStep {
        for i in 0..<6 {
            let a = CGFloat(i) * .pi / 3
            let pt = CGPoint(x: px + hexR * cos(a), y: py + hexR * sin(a))
            i == 0 ? ctx.move(to: pt) : ctx.addLine(to: pt)
        }
        ctx.closePath()
        py += rowStep
    }
    px += colStep
    col += 1
}
ctx.strokePath()

// ── Brain emoji ───────────────────────────────────────────────
let fontSize = s * 0.58
let font = NSFont.systemFont(ofSize: fontSize)
let attrStr = NSAttributedString(string: "🧠", attributes: [.font: font])
let ts = attrStr.size()
attrStr.draw(at: NSPoint(x: (s - ts.width) / 2, y: (s - ts.height) / 2 + s * 0.015))

// ── Save ─────────────────────────────────────────────────────
guard let png = rep.representation(using: .png, properties: [:]) else {
    print("Failed to encode PNG"); exit(1)
}
let out = "/Users/johanwilander/prepo/Hivemind/Hivemind/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png"
try! png.write(to: URL(fileURLWithPath: out))
print("Icon written to \(out)")
