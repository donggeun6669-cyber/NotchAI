import AppKit

// Draws the NotchAI app icon at 1024×1024 on the macOS grid (824pt squircle, 100pt margin): the notch
// with Claude and GPT hanging from it. Regenerate the app icon with scripts/icon/make-appiconset.sh.
let S: CGFloat = 1024
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
let claude: (r: CGFloat, g: CGFloat, b: CGFloat) = (r: 0.88, g: 0.48, b: 0.29)
let gpt: (r: CGFloat, g: CGFloat, b: CGFloat) = (r: 0.063, g: 0.639, b: 0.498)
let eye = rgb(0.10, 0.08, 0.07)
let blush = rgb(1.0, 0.60, 0.66, 0.80)

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(S), pixelsHigh: Int(S), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
let ctx = NSGraphicsContext(bitmapImageRep: rep)!.cgContext
// Top-left origin, like the app's layer code.
ctx.translateBy(x: 0, y: S); ctx.scaleBy(x: 1, y: -1)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

// Drop shadow of the tile (standard macOS icon shadow).
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 28, color: rgb(0, 0, 0, 0.30))
ctx.addPath(tilePath); ctx.setFillColor(rgb(0.85, 0.87, 0.9)); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
// Cool grey studio wall, as on the Ribbon Studio desktop.
let bg = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(0.95, 0.96, 0.975), rgb(0.80, 0.82, 0.86)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 924), options: [])

// The notch: hangs from the top edge, concave fillets where it meets the edge.
let nw: CGFloat = 420, nh: CGFloat = 172, nr: CGFloat = 62, fr: CGFloat = 34
let nl = 512 - nw / 2, nrgt = 512 + nw / 2, top: CGFloat = 100, nb = top + nh
let notch = CGMutablePath()
notch.move(to: CGPoint(x: nl - fr, y: top - 2))
notch.addLine(to: CGPoint(x: nrgt + fr, y: top - 2))
notch.addLine(to: CGPoint(x: nrgt + fr, y: top))
notch.addQuadCurve(to: CGPoint(x: nrgt, y: top + fr), control: CGPoint(x: nrgt, y: top))
notch.addLine(to: CGPoint(x: nrgt, y: nb - nr))
notch.addQuadCurve(to: CGPoint(x: nrgt - nr, y: nb), control: CGPoint(x: nrgt, y: nb))
notch.addLine(to: CGPoint(x: nl + nr, y: nb))
notch.addQuadCurve(to: CGPoint(x: nl, y: nb - nr), control: CGPoint(x: nl, y: nb))
notch.addLine(to: CGPoint(x: nl, y: top + fr))
notch.addQuadCurve(to: CGPoint(x: nl - fr, y: top), control: CGPoint(x: nl, y: top))
notch.closeSubpath()
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 30, color: rgb(0, 0, 0, 0.28))
ctx.addPath(notch); ctx.setFillColor(rgb(0.02, 0.02, 0.025)); ctx.fillPath()
ctx.restoreGState()
// Camera lens.
ctx.setFillColor(rgb(0.13, 0.14, 0.17)); ctx.fillEllipse(in: CGRect(x: 512 - 17, y: 150, width: 34, height: 34))
ctx.setFillColor(rgb(0.25, 0.30, 0.42, 0.8)); ctx.fillEllipse(in: CGRect(x: 512 - 7, y: 160, width: 12, height: 12))

func glow(center c: CGPoint, size s: CGFloat, color: (r: CGFloat, g: CGFloat, b: CGFloat)) {
    // Glow.
    let glow = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(color.r, color.g, color.b, 0.30), rgb(color.r, color.g, color.b, 0)] as CFArray, locations: [0.4, 1])!
    ctx.drawRadialGradient(glow, startCenter: c, startRadius: 0, endCenter: c, endRadius: s * 0.72, options: [])
}

func character(center c: CGPoint, size s: CGFloat, color: (r: CGFloat, g: CGFloat, b: CGFloat), round: Bool,
               gripSide: CGFloat, grip: CGPoint, restAngle: CGFloat) {
    let accent = rgb(color.r, color.g, color.b)
    let arm = rgb(color.r * 0.82, color.g * 0.82, color.b * 0.82)
    let body = CGRect(x: c.x - s / 2, y: c.y - s / 2, width: s, height: s)
    let bodyPath = round ? CGPath(ellipseIn: body, transform: nil)
        : CGPath(roundedRect: body, cornerWidth: s * 0.36, cornerHeight: s * 0.36, transform: nil)

    // Floor shadow.
    ctx.setFillColor(rgb(0.2, 0.22, 0.28, 0.16))
    ctx.fillEllipse(in: CGRect(x: c.x - s * 0.36, y: c.y + s * 0.56, width: s * 0.72, height: s * 0.09))

    let w = s * 0.12, hand = w * 1.4
    ctx.setLineCap(.round)
    ctx.setStrokeColor(arm); ctx.setFillColor(arm); ctx.setLineWidth(w)
    // Gripping arm: shoulder → the notch's lower edge.
    let shoulderG = CGPoint(x: c.x + gripSide * s * 0.34, y: c.y - s * 0.20)
    ctx.move(to: shoulderG); ctx.addLine(to: grip); ctx.strokePath()
    ctx.fillEllipse(in: CGRect(x: grip.x - hand / 2, y: grip.y - hand / 2, width: hand, height: hand))
    // Resting arm on the other side.
    let shoulderR = CGPoint(x: c.x - gripSide * s * 0.50, y: c.y + s * 0.04)
    let len = s * 0.30
    let end = CGPoint(x: shoulderR.x - gripSide * sin(restAngle) * len, y: shoulderR.y + cos(restAngle) * len)
    ctx.move(to: shoulderR); ctx.addLine(to: end); ctx.strokePath()
    ctx.fillEllipse(in: CGRect(x: end.x - hand / 2, y: end.y - hand / 2, width: hand, height: hand))

    // Body with the top highlight.
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    ctx.setFillColor(accent); ctx.fill(body)
    let hi = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [rgb(1, 1, 1, 0.34), rgb(1, 1, 1, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(hi, start: CGPoint(x: c.x, y: body.minY), end: CGPoint(x: c.x, y: body.minY + s * 0.55), options: [])
    ctx.restoreGState()

    // Eyes (same proportions as AICharacterView), looking up a little toward the notch.
    let ew = s * 0.13, eh = s * 0.26, gap = s * 0.2, ey = body.minY + s * 0.45
    ctx.setFillColor(eye)
    for side in [-1.0, 1.0] as [CGFloat] {
        let r = CGRect(x: c.x + side * (gap / 2 + ew / 2) - ew / 2, y: ey - eh / 2, width: ew, height: eh)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: ew / 2, cornerHeight: ew / 2, transform: nil)); ctx.fillPath()
        // Catch-light.
        ctx.setFillColor(rgb(1, 1, 1, 0.85))
        ctx.fillEllipse(in: CGRect(x: r.minX + ew * 0.22, y: r.minY + eh * 0.12, width: ew * 0.42, height: ew * 0.42))
        ctx.setFillColor(eye)
    }
    // Cheeks.
    ctx.setFillColor(blush)
    for side in [-1.0, 1.0] as [CGFloat] {
        let r = CGRect(x: c.x + side * s * 0.27 - s * 0.085, y: body.minY + s * 0.63 - s * 0.05, width: s * 0.17, height: s * 0.10)
        ctx.addPath(CGPath(roundedRect: r, cornerWidth: s * 0.05, cornerHeight: s * 0.05, transform: nil)); ctx.fillPath()
    }
}

let s: CGFloat = 296
glow(center: CGPoint(x: 356, y: 560), size: s, color: claude)
glow(center: CGPoint(x: 668, y: 560), size: s, color: gpt)
character(center: CGPoint(x: 356, y: 560), size: s, color: claude, round: false,
          gripSide: 1, grip: CGPoint(x: 356 + s * 0.30, y: nb - 4), restAngle: 0.55)
character(center: CGPoint(x: 668, y: 560), size: s, color: gpt, round: true,
          gripSide: -1, grip: CGPoint(x: 668 - s * 0.30, y: nb - 4), restAngle: 0.55)

// Glass rim.
ctx.restoreGState()
ctx.addPath(tilePath); ctx.setStrokeColor(rgb(1, 1, 1, 0.55)); ctx.setLineWidth(3); ctx.strokePath()

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote", out)
