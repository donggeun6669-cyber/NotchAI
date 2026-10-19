import AppKit

// Draws the NotchDesk app icon at 1024×1024 on the macOS grid (824pt squircle, 100pt margin):
// the notch opened into a small dark panel with three weeks of calendar and a record button.
// Regenerate with: scripts/icon/make-appiconset.sh scripts/icon/draw-notchdesk-icon.swift NotchDesk/Resources/Assets.xcassets/AppIcon.appiconset
let S: CGFloat = 1024
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let red = rgb(0.851, 0.176, 0.212)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)   // top-left origin

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0, 0, 0, 0.30))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0.85, 0.87, 0.9)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
// Cool grey wall, lighter at the top.
let wall = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0.93, 0.94, 0.96), rgb(0.78, 0.80, 0.84)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(wall, start: CGPoint(x: 0, y: 100), end: CGPoint(x: 0, y: 924), options: [])

// The opened notch: flat against the top edge, rounded at the bottom.
let panel = CGRect(x: 190, y: 100, width: 644, height: 440)
let path = CGMutablePath()
let r: CGFloat = 96
path.move(to: CGPoint(x: panel.minX, y: panel.minY))
path.addLine(to: CGPoint(x: panel.maxX, y: panel.minY))
path.addLine(to: CGPoint(x: panel.maxX, y: panel.maxY - r))
path.addQuadCurve(to: CGPoint(x: panel.maxX - r, y: panel.maxY), control: CGPoint(x: panel.maxX, y: panel.maxY))
path.addLine(to: CGPoint(x: panel.minX + r, y: panel.maxY))
path.addQuadCurve(to: CGPoint(x: panel.minX, y: panel.maxY - r), control: CGPoint(x: panel.minX, y: panel.maxY))
path.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 18), blur: 40, color: rgb(0, 0, 0, 0.35))
ctx.addPath(path); ctx.setFillColor(rgb(0.07, 0.07, 0.08)); ctx.fillPath()
ctx.restoreGState()

// Three weeks: 7 × 3 day cells, today in red.
let cell: CGFloat = 58, gap: CGFloat = 14
let gridWidth = cell * 7 + gap * 6
let origin = CGPoint(x: panel.midX - gridWidth / 2, y: 230)
for row in 0..<3 {
    for col in 0..<7 {
        let rect = CGRect(x: origin.x + CGFloat(col) * (cell + gap), y: origin.y + CGFloat(row) * (cell + gap),
                          width: cell, height: cell)
        let isToday = row == 0 && col == 2
        ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 14, cornerHeight: 14, transform: nil))
        ctx.setFillColor(isToday ? red : rgb(1, 1, 1, col == 6 ? 0.10 : 0.16))
        ctx.fillPath()
        // A few event dots.
        if [(0, 4), (1, 1), (1, 5), (2, 3)].contains(where: { $0 == (row, col) }) {
            ctx.addEllipse(in: CGRect(x: rect.midX - 6, y: rect.maxY - 18, width: 12, height: 12))
            ctx.setFillColor(rgb(1, 1, 1, 0.85)); ctx.fillPath()
        }
    }
}
// Header line above the grid.
ctx.addPath(CGPath(roundedRect: CGRect(x: origin.x, y: 168, width: 210, height: 22), cornerWidth: 11, cornerHeight: 11, transform: nil))
ctx.setFillColor(rgb(1, 1, 1, 0.75)); ctx.fillPath()

// The record button below the panel.
let button = CGRect(x: 512 - 92, y: 640, width: 184, height: 184)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 24, color: rgb(0.5, 0, 0, 0.35))
ctx.addEllipse(in: button); ctx.setFillColor(rgb(0.98, 0.98, 0.99)); ctx.fillPath()
ctx.restoreGState()
ctx.addEllipse(in: button.insetBy(dx: 38, dy: 38)); ctx.setFillColor(red); ctx.fillPath()
ctx.restoreGState()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "notchdesk-icon.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print(out)
