import AppKit

// Draws the 강의녹음 app icon at 1024×1024 on the macOS grid (824pt squircle, 100pt margin): a red
// record button carrying a white waveform, on the same studio grey as the NotchAI icon.
// Regenerate the app icon with scripts/icon/make-appiconset.sh.
let S: CGFloat = 1024
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let space = CGColorSpace(name: CGColorSpace.sRGB)!

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0, 0, 0, 0.30))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0.85, 0.87, 0.9)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let bg = CGGradient(colorsSpace: space, colors: [rgb(0.95, 0.96, 0.975), rgb(0.80, 0.82, 0.86)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// Record button: red disc with a soft glow and a floor shadow.
let c = CGPoint(x: 512, y: 500), r: CGFloat = 250
let glow = CGGradient(colorsSpace: space, colors: [rgb(0.851, 0.176, 0.212, 0.30), rgb(0.851, 0.176, 0.212, 0)] as CFArray, locations: [0.55, 1])!
ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: r * 1.45, options: [])
ctx.setFillColor(rgb(0.2, 0.22, 0.28, 0.16))
ctx.fillEllipse(in: CGRect(x: c.x - r * 0.72, y: c.y + r * 1.12, width: r * 1.44, height: r * 0.16))
ctx.saveGState()
ctx.addEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)); ctx.clip()
let disc = CGGradient(colorsSpace: space, colors: [rgb(0.93, 0.33, 0.35), rgb(0.80, 0.14, 0.18)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(disc, start: CGPoint(x: c.x, y: c.y - r), end: CGPoint(x: c.x, y: c.y + r), options: [])
let hi = CGGradient(colorsSpace: space, colors: [rgb(1, 1, 1, 0.30), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(hi, start: CGPoint(x: c.x, y: c.y - r), end: CGPoint(x: c.x, y: c.y), options: [])
ctx.restoreGState()

// Waveform: seven rounded bars, tallest in the middle.
let heights: [CGFloat] = [0.26, 0.50, 0.78, 1.0, 0.70, 0.44, 0.24]
let barW: CGFloat = 36, gap: CGFloat = 22, maxH: CGFloat = 250
let total = CGFloat(heights.count) * barW + CGFloat(heights.count - 1) * gap
ctx.setFillColor(rgb(1, 1, 1, 0.97))
for (i, h) in heights.enumerated() {
    let x = c.x - total / 2 + CGFloat(i) * (barW + gap)
    let height = maxH * h
    let bar = CGRect(x: x, y: c.y - height / 2, width: barW, height: height)
    ctx.addPath(CGPath(roundedRect: bar, cornerWidth: barW / 2, cornerHeight: barW / 2, transform: nil)); ctx.fillPath()
}
ctx.restoreGState()
ctx.addPath(tilePath); ctx.setStrokeColor(rgb(1, 1, 1, 0.55)); ctx.setLineWidth(3); ctx.strokePath()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "recorder_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)
