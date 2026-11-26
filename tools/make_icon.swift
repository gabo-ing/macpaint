// Renders the app icon: swift tools/make_icon.swift <out.png>   (then see tools/make_icns.sh)
import AppKit

let S: CGFloat = 1024
let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                           hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

func col(_ r: Int, _ g: Int, _ b: Int) -> NSColor { NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1) }

// squircle-ish tile with shadow
let tile = NSRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: 185, yRadius: 185)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 28, color: NSColor.black.withAlphaComponent(0.35).cgColor)
col(255, 255, 255).setFill(); tilePath.fill()
ctx.restoreGState()
tilePath.addClip()
NSGradient(starting: col(120, 190, 245), ending: col(24, 110, 200))!.draw(in: tile, angle: 90)

// white canvas sheet
let sheet = NSRect(x: 190, y: 290, width: 644, height: 470)
let sheetPath = NSBezierPath(roundedRect: sheet, xRadius: 30, yRadius: 30)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.3).cgColor)
NSColor.white.setFill(); sheetPath.fill()
ctx.restoreGState()

// pixel-art style stroke on the sheet (a nod to pixel-level editing)
let px: CGFloat = 34
let pixels: [(Int, Int, NSColor)] = [
    (0, 1, col(237, 28, 36)), (1, 2, col(237, 28, 36)), (2, 3, col(255, 127, 39)), (3, 3, col(255, 127, 39)),
    (4, 2, col(255, 242, 0)), (5, 1, col(34, 177, 76)), (6, 1, col(34, 177, 76)), (7, 2, col(0, 162, 232)),
    (8, 3, col(63, 72, 204)), (9, 3, col(163, 73, 164)), (10, 2, col(163, 73, 164))
]
let ox = sheet.minX + 70, oy = sheet.minY + 190
for (x, y, c) in pixels {
    c.setFill()
    NSRect(x: ox + CGFloat(x) * px, y: oy + CGFloat(y) * px, width: px, height: px).fill()
}
// pixel grid
NSColor(white: 0, alpha: 0.10).setStroke()
for i in 0...11 { let p = NSBezierPath(); p.move(to: NSPoint(x: ox + CGFloat(i) * px, y: oy)); p.line(to: NSPoint(x: ox + CGFloat(i) * px, y: oy + 5 * px)); p.lineWidth = 1.5; p.stroke() }
for j in 0...5 { let p = NSBezierPath(); p.move(to: NSPoint(x: ox, y: oy + CGFloat(j) * px)); p.line(to: NSPoint(x: ox + 11 * px, y: oy + CGFloat(j) * px)); p.lineWidth = 1.5; p.stroke() }

// palette swatches along the bottom of the sheet
let sw: [NSColor] = [col(0,0,0), col(237,28,36), col(255,127,39), col(255,242,0), col(34,177,76), col(0,162,232), col(63,72,204), col(163,73,164)]
for (i, c) in sw.enumerated() {
    let r = NSRect(x: sheet.minX + 54 + CGFloat(i) * 72, y: sheet.minY + 40, width: 56, height: 56)
    c.setFill(); NSBezierPath(roundedRect: r, xRadius: 10, yRadius: 10).fill()
    NSColor(white: 0, alpha: 0.25).setStroke(); let b = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 1), xRadius: 9, yRadius: 9); b.lineWidth = 2; b.stroke()
}

// pencil, diagonal over the corner of the sheet
ctx.saveGState()
ctx.translateBy(x: 812, y: 372)
ctx.rotate(by: .pi / 4)
let body = NSRect(x: -34, y: 40, width: 68, height: 330)
col(255, 201, 14).setFill(); NSBezierPath(rect: body).fill()
col(224, 160, 0).setFill(); NSBezierPath(rect: NSRect(x: 6, y: 40, width: 28, height: 330)).fill()
col(245, 130, 140).setFill(); NSBezierPath(rect: NSRect(x: -34, y: 340, width: 68, height: 50)).fill()
col(170, 175, 185).setFill(); NSBezierPath(rect: NSRect(x: -34, y: 322, width: 68, height: 18)).fill()
let tip = NSBezierPath(); tip.move(to: NSPoint(x: -34, y: 40)); tip.line(to: NSPoint(x: 34, y: 40)); tip.line(to: NSPoint(x: 0, y: -45)); tip.close()
col(240, 205, 160).setFill(); tip.fill()
let lead = NSBezierPath(); lead.move(to: NSPoint(x: -12, y: -3)); lead.line(to: NSPoint(x: 12, y: -3)); lead.line(to: NSPoint(x: 0, y: -45)); lead.close()
col(40, 40, 45).setFill(); lead.fill()
ctx.restoreGState()

NSGraphicsContext.restoreGraphicsState()
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon_1024.png"
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
