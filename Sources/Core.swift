import AppKit

// MARK: - Color

struct RGBA: Equatable {
    var r: UInt8, g: UInt8, b: UInt8, a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ c: NSColor) {
        let s = c.usingColorSpace(.sRGB) ?? c
        func q(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
        r = q(s.redComponent); g = q(s.greenComponent); b = q(s.blueComponent); a = q(s.alphaComponent)
    }

    var ns: NSColor {
        NSColor(srgbRed: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: CGFloat(a) / 255)
    }
    var cg: CGColor { ns.cgColor }
    /// Little-endian memory order R,G,B,A (matches premultipliedLast bitmap contexts for opaque colors)
    var packed: UInt32 { UInt32(r) | UInt32(g) << 8 | UInt32(b) << 16 | UInt32(a) << 24 }

    static let white = RGBA(255, 255, 255)
    static let black = RGBA(0, 0, 0)
}

// MARK: - Drawing helper

/// Draws an upright CGImage into `rect` of a y-down (flipped) context.
func drawCG(_ img: CGImage, in rect: CGRect, on c: CGContext) {
    c.saveGState()
    c.translateBy(x: rect.minX, y: rect.maxY)
    c.scaleBy(x: 1, y: -1)
    c.draw(img, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
    c.restoreGState()
}

// MARK: - Bitmap (the pixel canvas)

final class Bitmap {
    private(set) var ctx: CGContext
    private var cached: CGImage?
    static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!

    var width: Int { ctx.width }
    var height: Int { ctx.height }
    var bounds: CGRect { CGRect(x: 0, y: 0, width: width, height: height) }

    static func makeContext(_ w: Int, _ h: Int) -> CGContext {
        let w = max(1, w), h = max(1, h)
        let c = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                          space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        c.translateBy(x: 0, y: CGFloat(h))
        c.scaleBy(x: 1, y: -1)           // y-down, row 0 = top
        c.interpolationQuality = .none
        return c
    }

    init(width: Int, height: Int, fill: RGBA? = .white) {
        ctx = Bitmap.makeContext(width, height)
        if let f = fill {
            ctx.setFillColor(f.cg)
            ctx.fill(bounds)
        }
    }

    /// Image composited over white (so transparent PNGs open like they do in Paint).
    convenience init(image: CGImage) {
        self.init(width: image.width, height: image.height, fill: .white)
        drawCG(image, in: bounds, on: ctx)
    }

    var image: CGImage {
        if cached == nil { cached = ctx.makeImage() }
        return cached!
    }

    func touch() { cached = nil }

    func replace(with img: CGImage) {
        ctx = Bitmap.makeContext(img.width, img.height)
        ctx.setBlendMode(.copy)
        drawCG(img, in: bounds, on: ctx)
        ctx.setBlendMode(.normal)
        cached = nil
    }

    /// Change canvas size, keeping the top-left content, filling new area with `fill`.
    func resizeCanvas(width w: Int, height h: Int, fill: RGBA) {
        let old = image
        ctx = Bitmap.makeContext(w, h)
        ctx.setFillColor(fill.cg)
        ctx.fill(bounds)
        drawCG(old, in: CGRect(x: 0, y: 0, width: old.width, height: old.height), on: ctx)
        cached = nil
    }

    func pixel(_ x: Int, _ y: Int) -> RGBA? {
        guard x >= 0, y >= 0, x < width, y < height, let data = ctx.data else { return nil }
        let stride = ctx.bytesPerRow / 4
        let v = data.assumingMemoryBound(to: UInt32.self)[y * stride + x]
        let a = UInt8(v >> 24 & 0xFF)
        // un-premultiply for picking
        func un(_ c: UInt32) -> UInt8 { a == 0 ? 0 : UInt8(min(255, Int(c) * 255 / Int(a))) }
        return RGBA(un(v & 0xFF), un(v >> 8 & 0xFF), un(v >> 16 & 0xFF), a)
    }

    func floodFill(x sx: Int, y sy: Int, color: RGBA) {
        guard sx >= 0, sy >= 0, sx < width, sy < height, let data = ctx.data else { return }
        let w = width, h = height
        let stride = ctx.bytesPerRow / 4
        let p = data.assumingMemoryBound(to: UInt32.self)
        let target = p[sy * stride + sx]
        let newV = color.packed
        if target == newV { return }
        var stack: [(Int, Int)] = [(sx, sy)]
        while let (x0, y) = stack.popLast() {
            var x = x0
            while x >= 0 && p[y * stride + x] == target { x -= 1 }
            x += 1
            var above = false, below = false
            while x < w && p[y * stride + x] == target {
                p[y * stride + x] = newV
                if y > 0 {
                    let m = p[(y - 1) * stride + x] == target
                    if m && !above { stack.append((x, y - 1)); above = true } else if !m { above = false }
                }
                if y < h - 1 {
                    let m = p[(y + 1) * stride + x] == target
                    if m && !below { stack.append((x, y + 1)); below = true } else if !m { below = false }
                }
                x += 1
            }
        }
        cached = nil
    }

    // MARK: static image helpers

    static func transformed(_ img: CGImage, newW: Int, newH: Int, _ t: CGAffineTransform) -> CGImage {
        let b = Bitmap(width: newW, height: newH, fill: nil)
        b.ctx.concatenate(t)
        drawCG(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height), on: b.ctx)
        return b.image
    }

    static func scaled(_ img: CGImage, width w: Int, height h: Int) -> CGImage {
        let b = Bitmap(width: w, height: h, fill: nil)
        b.ctx.interpolationQuality = (w < img.width || h < img.height) ? .high : .none
        drawCG(img, in: b.bounds, on: b.ctx)
        return b.image
    }

    static func rotatedRight(_ i: CGImage) -> CGImage {
        transformed(i, newW: i.height, newH: i.width, CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: CGFloat(i.height), ty: 0))
    }
    static func rotatedLeft(_ i: CGImage) -> CGImage {
        transformed(i, newW: i.height, newH: i.width, CGAffineTransform(a: 0, b: -1, c: 1, d: 0, tx: 0, ty: CGFloat(i.width)))
    }
    static func rotated180(_ i: CGImage) -> CGImage {
        transformed(i, newW: i.width, newH: i.height, CGAffineTransform(a: -1, b: 0, c: 0, d: -1, tx: CGFloat(i.width), ty: CGFloat(i.height)))
    }
    static func flippedH(_ i: CGImage) -> CGImage {
        transformed(i, newW: i.width, newH: i.height, CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: CGFloat(i.width), ty: 0))
    }
    static func flippedV(_ i: CGImage) -> CGImage {
        transformed(i, newW: i.width, newH: i.height, CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(i.height)))
    }

    /// Makes every pixel equal to `bg` transparent.
    static func keyedOut(_ img: CGImage, bg: RGBA) -> CGImage {
        let b = Bitmap(width: img.width, height: img.height, fill: nil)
        drawCG(img, in: b.bounds, on: b.ctx)
        if let data = b.ctx.data {
            let stride = b.ctx.bytesPerRow / 4
            let p = data.assumingMemoryBound(to: UInt32.self)
            let key = bg.packed
            for y in 0..<b.height { for x in 0..<b.width where p[y * stride + x] == key { p[y * stride + x] = 0 } }
        }
        b.touch()
        return b.image
    }
}

// MARK: - Tools & settings

enum Tool: Equatable { case select, freeSelect, pencil, fill, text, eraser, picker, magnifier, brush, shape }

enum BrushKind: Int, CaseIterable {
    case brush, calligraphy1, calligraphy2, airbrush, oil, crayon, marker, naturalPencil, watercolor
    var name: String {
        switch self {
        case .brush: return "Brush"
        case .calligraphy1: return "Calligraphy brush 1"
        case .calligraphy2: return "Calligraphy brush 2"
        case .airbrush: return "Airbrush"
        case .oil: return "Oil brush"
        case .crayon: return "Crayon"
        case .marker: return "Marker"
        case .naturalPencil: return "Natural pencil"
        case .watercolor: return "Watercolor brush"
        }
    }
}

enum ShapeKind: Int, CaseIterable {
    case line, curve, oval, rectangle, roundedRectangle, polygon
    case triangle, rightTriangle, diamond, pentagon, hexagon, arrowRight
    case arrowLeft, arrowUp, arrowDown, star4, star5, star6
}

extension Notification.Name {
    static let paintSettings = Notification.Name("PaintSettingsChanged")
}

final class Settings {
    static let shared = Settings()

    var tool: Tool = .pencil { didSet { post() } }
    var brush: BrushKind = .brush { didSet { post() } }
    var shape: ShapeKind = .line { didSet { post() } }
    var outline = true { didSet { post() } }
    var fill = false { didSet { post() } }
    var size = 3 { didSet { post() } }
    var color1 = RGBA.black { didSet { post() } }
    var color2 = RGBA.white { didSet { post() } }
    var activeSlot = 1 { didSet { post() } }

    var antialias = true { didSet { post() } }
    var transparentSelection = false { didSet { post() } }
    var showGrid = true { didSet { post() } }
    var showStatusBar = true { didSet { post() } }
    var wheelZooms = false { didSet { post() } }

    var fontName = "Helvetica" { didSet { post() } }
    var fontSize = 14 { didSet { post() } }     // points, drawn at 96 dpi like Paint
    var bold = false { didSet { post() } }
    var italic = false { didSet { post() } }
    var underline = false { didSet { post() } }
    var textTransparent = true { didSet { post() } }

    func post() { NotificationCenter.default.post(name: .paintSettings, object: nil) }
}

// MARK: - Shape geometry

private let arrowRightPts: [CGPoint] = [
    CGPoint(x: 0, y: 0.3), CGPoint(x: 0.6, y: 0.3), CGPoint(x: 0.6, y: 0), CGPoint(x: 1, y: 0.5),
    CGPoint(x: 0.6, y: 1), CGPoint(x: 0.6, y: 0.7), CGPoint(x: 0, y: 0.7)
]

private func starPts(_ n: Int, inner: CGFloat) -> [CGPoint] {
    var pts: [CGPoint] = []
    for i in 0..<(n * 2) {
        let ang = -CGFloat.pi / 2 + CGFloat(i) * CGFloat.pi / CGFloat(n)
        let r: CGFloat = i % 2 == 0 ? 0.5 : 0.5 * inner
        pts.append(CGPoint(x: 0.5 + r * cos(ang), y: 0.5 + r * sin(ang)))
    }
    return pts
}

func unitPolygon(_ k: ShapeKind) -> [CGPoint]? {
    switch k {
    case .triangle: return [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    case .rightTriangle: return [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)]
    case .diamond: return [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.5, y: 1), CGPoint(x: 0, y: 0.5)]
    case .pentagon: return [CGPoint(x: 0.5, y: 0), CGPoint(x: 1, y: 0.38), CGPoint(x: 0.81, y: 1), CGPoint(x: 0.19, y: 1), CGPoint(x: 0, y: 0.38)]
    case .hexagon: return [CGPoint(x: 0.25, y: 0), CGPoint(x: 0.75, y: 0), CGPoint(x: 1, y: 0.5), CGPoint(x: 0.75, y: 1), CGPoint(x: 0.25, y: 1), CGPoint(x: 0, y: 0.5)]
    case .arrowRight: return arrowRightPts
    case .arrowLeft: return arrowRightPts.map { CGPoint(x: 1 - $0.x, y: $0.y) }
    case .arrowUp: return arrowRightPts.map { CGPoint(x: $0.y, y: 1 - $0.x) }
    case .arrowDown: return arrowRightPts.map { CGPoint(x: $0.y, y: $0.x) }
    case .star4: return starPts(4, inner: 0.4)
    case .star5: return starPts(5, inner: 0.4)
    case .star6: return starPts(6, inner: 0.55)
    default: return nil
    }
}

/// Path for any closed shape inside `r`.
func closedShapePath(_ k: ShapeKind, in r: CGRect) -> CGPath {
    switch k {
    case .oval: return CGPath(ellipseIn: r, transform: nil)
    case .rectangle: return CGPath(rect: r, transform: nil)
    case .roundedRectangle:
        let rad = max(0, min(min(r.width, r.height) * 0.25, min(r.width, r.height) / 2))
        return CGPath(roundedRect: r, cornerWidth: rad, cornerHeight: rad, transform: nil)
    default:
        let p = CGMutablePath()
        if let pts = unitPolygon(k) {
            for (i, u) in pts.enumerated() {
                let q = CGPoint(x: r.minX + u.x * r.width, y: r.minY + u.y * r.height)
                if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
            }
            p.closeSubpath()
        }
        return p
    }
}

struct ShapeDraft {
    var kind: ShapeKind
    var p0: CGPoint
    var p1: CGPoint
    var controls: [CGPoint] = []      // curve
    var points: [CGPoint] = []        // polygon
    var polyCursor: CGPoint? = nil    // rubber band
    var outlineColor: RGBA
    var fillColor: RGBA
    var outline: Bool
    var fill: Bool
    var width: CGFloat
    var antialias: Bool
}

func renderShape(_ d: ShapeDraft, on c: CGContext) {
    c.saveGState()
    c.setShouldAntialias(d.antialias)
    c.setLineWidth(d.width)
    c.setLineJoin(.miter)
    c.setLineCap(.round)
    c.setMiterLimit(8)
    let off: CGFloat = Int(d.width) % 2 == 1 ? 0.5 : 0
    func o(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + off, y: p.y + off) }

    // Which color fills, which strokes. No outline + fill => fill uses the outline (primary) color, like Paint.
    let strokeCol = d.outlineColor.cg
    let fillCol = (d.outline ? d.fillColor : d.outlineColor).cg

    switch d.kind {
    case .line:
        c.setStrokeColor(strokeCol)
        c.move(to: o(d.p0)); c.addLine(to: o(d.p1)); c.strokePath()
    case .curve:
        c.setStrokeColor(strokeCol)
        c.move(to: o(d.p0))
        if d.controls.isEmpty {
            c.addLine(to: o(d.p1))
        } else {
            let c1 = d.controls[0], c2 = d.controls.count > 1 ? d.controls[1] : c1
            c.addCurve(to: o(d.p1), control1: o(c1), control2: o(c2))
        }
        c.strokePath()
    case .polygon:
        var pts = d.points
        if let cur = d.polyCursor { pts.append(cur) }
        guard pts.count >= 2 else { break }
        let path = CGMutablePath()
        path.move(to: o(pts[0]))
        for q in pts.dropFirst() { path.addLine(to: o(q)) }
        let closed = d.polyCursor == nil
        if closed { path.closeSubpath() }
        if closed && d.fill && pts.count >= 3 {
            c.addPath(path); c.setFillColor(fillCol); c.fillPath()
        }
        if d.outline || !closed {
            c.addPath(path); c.setStrokeColor(strokeCol); c.strokePath()
        }
    default:
        let minX = min(d.p0.x, d.p1.x), minY = min(d.p0.y, d.p1.y)
        let maxX = max(d.p0.x, d.p1.x), maxY = max(d.p0.y, d.p1.y)
        if d.outline {
            let r = CGRect(x: minX + off, y: minY + off, width: maxX - minX, height: maxY - minY)
            let path = closedShapePath(d.kind, in: r)
            if d.fill { c.addPath(path); c.setFillColor(fillCol); c.fillPath() }
            c.addPath(path); c.setStrokeColor(strokeCol); c.strokePath()
        } else if d.fill {
            let r = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            c.addPath(closedShapePath(d.kind, in: r)); c.setFillColor(fillCol); c.fillPath()
        }
    }
    c.restoreGState()
}

// MARK: - Selection model

struct Selection {
    var rect: CGRect          // image coordinates, integral
    var image: CGImage?       // floating pixels once lifted
    var path: CGPath?         // free-form mask, relative to rect.origin
    var lifted: Bool { image != nil }
}

struct DocState {
    var image: CGImage
    var sel: Selection?
}
