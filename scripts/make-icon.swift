// Draws the QuotaPilot app icon: a quota gauge whose needle is a paper plane ("pilot").
// Usage: swift scripts/make-icon.swift assets/AppIcon-1024.png
import AppKit

let size: CGFloat = 1024
let output = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let space = CGColorSpaceCreateDeviceRGB()
func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor { CGColor(red: r/255, green: g/255, blue: b/255, alpha: a) }

// macOS icon grid: 824 pt rounded square centred on a 1024 canvas, with a soft shadow.
let inset: CGFloat = 100
let tile = CGRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0, 0, 0, 0.35))
ctx.addPath(tilePath); ctx.setFillColor(rgb(16, 20, 40)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(tilePath); ctx.clip()
let background = CGGradient(colorsSpace: space, colors: [rgb(30, 36, 78), rgb(12, 16, 34)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(background, start: CGPoint(x: tile.minX, y: tile.maxY), end: CGPoint(x: tile.maxX, y: tile.minY), options: [])
// Subtle top highlight.
let glow = CGGradient(colorsSpace: space, colors: [rgb(120, 140, 255, 0.22), rgb(120, 140, 255, 0)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(glow, startCenter: CGPoint(x: size/2, y: tile.maxY), startRadius: 0,
                       endCenter: CGPoint(x: size/2, y: tile.maxY), endRadius: 520, options: [])

// Gauge: 240° arc, teal → green → amber → coral, with a dim track.
let center = CGPoint(x: size/2, y: size/2 - 30)
let radius: CGFloat = 270
let start = CGFloat.pi * 1.25, end = -CGFloat.pi * 0.25   // from lower-left, clockwise to lower-right
ctx.setLineCap(.round)
ctx.setLineWidth(58)
ctx.setStrokeColor(rgb(255, 255, 255, 0.10))
ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true); ctx.strokePath()
let stops: [(CGFloat, CGColor)] = [(0, rgb(45, 212, 191)), (0.45, rgb(132, 204, 22)), (0.75, rgb(250, 190, 40)), (1, rgb(248, 113, 113))]
let segments = 120
let filled: CGFloat = 0.72   // fill to about 72 % of the arc
func mix(_ t: CGFloat) -> CGColor {
    var i = 0; while i < stops.count - 2 && t > stops[i + 1].0 { i += 1 }
    let (t0, c0) = stops[i], (t1, c1) = stops[i + 1]
    let u = max(0, min(1, (t - t0) / (t1 - t0)))
    let a = c0.components!, b = c1.components!
    return CGColor(red: a[0] + (b[0]-a[0])*u, green: a[1] + (b[1]-a[1])*u, blue: a[2] + (b[2]-a[2])*u, alpha: 1)
}
for s in 0..<segments where CGFloat(s) / CGFloat(segments) < filled {
    let t0 = CGFloat(s) / CGFloat(segments), t1 = CGFloat(s + 1) / CGFloat(segments) + 0.004
    let a0 = start - (start - end) * t0, a1 = start - (start - end) * min(t1, filled)
    ctx.setStrokeColor(mix(t0))
    ctx.setLineCap(s == 0 ? .round : .butt)
    ctx.addArc(center: center, radius: radius, startAngle: a0, endAngle: a1, clockwise: true); ctx.strokePath()
}
// Round cap at the end of the filled part.
let tipAngle = start - (start - end) * filled
ctx.setFillColor(mix(filled))
ctx.fillEllipse(in: CGRect(x: center.x + cos(tipAngle) * radius - 29, y: center.y + sin(tipAngle) * radius - 29, width: 58, height: 58))

// Tick marks.
ctx.setStrokeColor(rgb(255, 255, 255, 0.35)); ctx.setLineWidth(10); ctx.setLineCap(.round)
for k in 0...4 {
    let a = start - (start - end) * CGFloat(k) / 4
    ctx.move(to: CGPoint(x: center.x + cos(a) * (radius - 70), y: center.y + sin(a) * (radius - 70)))
    ctx.addLine(to: CGPoint(x: center.x + cos(a) * (radius - 100), y: center.y + sin(a) * (radius - 100)))
    ctx.strokePath()
}

// Needle: a paper plane pointing at the gauge tip.
ctx.saveGState()
ctx.translateBy(x: center.x, y: center.y)
ctx.rotate(by: tipAngle)
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: rgb(0, 0, 0, 0.45))
let plane = CGMutablePath()
plane.move(to: CGPoint(x: 205, y: 0))          // nose
plane.addLine(to: CGPoint(x: -70, y: 92))       // upper wing tip
plane.addLine(to: CGPoint(x: -18, y: 0))        // tail notch
plane.addLine(to: CGPoint(x: -70, y: -92))      // lower wing tip
plane.closeSubpath()
ctx.addPath(plane); ctx.setFillColor(rgb(255, 255, 255)); ctx.fillPath()
ctx.setShadow(offset: .zero, blur: 0, color: nil)
let fold = CGMutablePath()                       // shaded lower half for a folded-paper look
fold.move(to: CGPoint(x: 205, y: 0)); fold.addLine(to: CGPoint(x: -18, y: 0)); fold.addLine(to: CGPoint(x: -70, y: -92)); fold.closeSubpath()
ctx.addPath(fold); ctx.setFillColor(rgb(200, 210, 240)); ctx.fillPath()
ctx.restoreGState()
// Hub.
ctx.setFillColor(rgb(12, 16, 34)); ctx.fillEllipse(in: CGRect(x: center.x - 30, y: center.y - 30, width: 60, height: 60))
ctx.setFillColor(rgb(255, 255, 255)); ctx.fillEllipse(in: CGRect(x: center.x - 16, y: center.y - 16, width: 32, height: 32))
ctx.restoreGState()
image.unlockFocus()

let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
