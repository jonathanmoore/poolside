// Draws the app icon. Run: swiftc -o /tmp/app_icon tools/app_icon.swift && /tmp/app_icon out.png light|dark|tinted
import AppKit

// Usage: run <out.png> <variant: light|dark|tinted>
let out = CommandLine.arguments[1]
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "light"
let size = 1024.0
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
                    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
// Flip so y grows downward like a design canvas.
ctx.translateBy(x: 0, y: size); ctx.scaleBy(x: 1, y: -1)

func c(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
func linear(_ colors: [CGColor], _ from: CGPoint, _ to: CGPoint) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radial(_ colors: [CGColor], _ center: CGPoint, _ radius: Double) {
    let g = CGGradient(colorsSpace: cs, colors: colors as CFArray, locations: nil)!
    ctx.drawRadialGradient(g, startCenter: center, startRadius: 0, endCenter: center, endRadius: radius, options: [])
}

let dark = variant == "dark"
let tinted = variant == "tinted"

// Background
if tinted {
    linear([c(0.1, 0.1, 0.1), c(0, 0, 0)], CGPoint(x: 0, y: 0), CGPoint(x: 0, y: size))
} else if dark {
    linear([c(0.02, 0.06, 0.14), c(0.0, 0.16, 0.28)], CGPoint(x: 0, y: 0), CGPoint(x: 0, y: size))
} else {
    linear([c(0.0, 0.33, 0.72), c(0.0, 0.55, 0.9), c(0.1, 0.78, 0.92)], CGPoint(x: 0, y: 0), CGPoint(x: 0, y: size))
}

// The app's dial, in white: faint 270° track, bright arc to the target, round knob.
// Placed so the dial's visible shape (taller above its center than below, because of the
// open gap at the bottom) sits in the middle of the icon.
let dial = CGPoint(x: 512, y: 540)
let radius = 215.0
let ring = 54.0
let arcStart = 135.0, arcSweep = 270.0, setTo = 0.62
func arcPath(_ from: Double, _ to: Double) -> CGPath {
    let p = CGMutablePath()
    // y is flipped, so increasing angles run clockwise on screen, like the app.
    p.addArc(center: dial, radius: radius, startAngle: from * .pi / 180, endAngle: to * .pi / 180, clockwise: false)
    return p
}
func strokeArc(_ path: CGPath, alpha: Double) {
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(path); ctx.setLineWidth(ring); ctx.setLineCap(.round)
    ctx.setStrokeColor(c(1, 1, 1, 1)); ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.setAlpha(1)
}
strokeArc(arcPath(arcStart, arcStart + arcSweep), alpha: tinted ? 0.35 : 0.3)
strokeArc(arcPath(arcStart, arcStart + arcSweep * setTo), alpha: 1)
let knobAngle = (arcStart + arcSweep * setTo) * .pi / 180
let knob = CGPoint(x: dial.x + radius * cos(knobAngle), y: dial.y + radius * sin(knobAngle))
ctx.setShadow(offset: CGSize(width: 0, height: 8), blur: 24, color: c(0, 0.1, 0.3, dark || tinted ? 0.5 : 0.3))
ctx.setFillColor(c(1, 1, 1, 1))
ctx.fillEllipse(in: CGRect(x: knob.x - 46, y: knob.y - 46, width: 92, height: 92))
ctx.setShadow(offset: .zero, blur: 0, color: nil)

// Water: three waves that stop short of the dial, with round ends, leaving clear space around it.
let clearance = radius + ring / 2 + 70 // from the dial's center to where a wave's line stops
func wavePath(y: Double) -> CGPath {
    let path = CGMutablePath()
    var drawing = false
    var x = -60.0
    while x <= size + 60 {
        let p = CGPoint(x: x, y: y + 24 * sin((x - 100) / 340 * 2 * .pi))
        let inside = hypot(p.x - dial.x, p.y - dial.y) < clearance
        if inside { drawing = false }
        else if drawing { path.addLine(to: p) }
        else { path.move(to: p); drawing = true }
        x += 2
    }
    return path
}
for (y, alpha) in [(620.0, 1.0), (745.0, 0.75), (870.0, 0.5)] {
    ctx.setAlpha(alpha)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    ctx.addPath(wavePath(y: y)); ctx.setLineWidth(44); ctx.setLineCap(.round); ctx.setLineJoin(.round)
    ctx.setStrokeColor(c(1, 1, 1, 1)); ctx.strokePath()
    ctx.endTransparencyLayer()
    ctx.setAlpha(1)
}

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
