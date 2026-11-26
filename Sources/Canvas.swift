import AppKit
import UniformTypeIdentifiers

final class PaintScrollView: NSScrollView {
    weak var canvas: CanvasView?
    override func layout() {
        super.layout()
        canvas?.fitFrame()
    }
}

final class CanvasView: NSView, NSTextViewDelegate {
    enum Handle { case right, bottom, corner }

    let bitmap = Bitmap(width: 1152, height: 648)
    let settings = Settings.shared
    weak var scrollView: NSScrollView?

    // view geometry
    var zoom: CGFloat = 1
    let pad: CGFloat = 8
    static let levels: [CGFloat] = [0.125, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 24, 32, 48, 64]

    // document state
    var sel: Selection?
    var undoStack: [DocState] = []
    var redoStack: [DocState] = []
    var fileURL: URL?
    var isModified = false { didSet { if oldValue != isModified { onDocChange?() } } }
    var onStatus: (() -> Void)?
    var onDocChange: (() -> Void)?

    // interaction state
    var hoverPx: CGPoint?
    var hoverHandle: Handle?
    var isSecondary = false
    var dragging = false
    var lastTool: Tool = .pencil
    var toolBeforePicker: Tool = .pencil

    var strokeBase: CGImage?
    var strokePts: [CGPoint] = []
    var strokeFG = RGBA.black
    var strokeBG = RGBA.white
    var strokeKind: Tool = .pencil
    var airTimer: Timer?
    var lastP = CGPoint.zero

    var draft: ShapeDraft?
    var draftPhase = 0

    var selDragStart: CGPoint?
    var selDragRect: CGRect?
    var freePts: [CGPoint] = []
    var moveAnchor: CGPoint?
    var moveOrigin: CGPoint = .zero
    var movePending = false
    var moveCopy = false
    var lastNudge = Date.distantPast

    var resizeHandle: Handle?
    var resizeStartView = CGPoint.zero
    var resizeNewSize: (Int, Int)?

    var textView: NSTextView?
    var wheelAccum: CGFloat = 0
    var pinchAccum: CGFloat = 0

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override var isOpaque: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .paintSettings, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: geometry

    var imageRect: CGRect {
        CGRect(x: pad, y: pad, width: CGFloat(bitmap.width) * zoom, height: CGFloat(bitmap.height) * zoom)
    }
    func toImage(_ p: CGPoint) -> CGPoint { CGPoint(x: (p.x - pad) / zoom, y: (p.y - pad) / zoom) }
    func toView(_ r: CGRect) -> CGRect {
        CGRect(x: pad + r.minX * zoom, y: pad + r.minY * zoom, width: r.width * zoom, height: r.height * zoom)
    }
    func invalidate(_ imgRect: CGRect) { setNeedsDisplay(toView(imgRect).insetBy(dx: -3, dy: -3)) }
    func pixelOf(_ viewPt: CGPoint) -> CGPoint {
        let p = toImage(viewPt)
        return CGPoint(x: floor(p.x), y: floor(p.y))
    }
    func inBounds(_ p: CGPoint) -> Bool { bitmap.bounds.contains(p) }

    func fitFrame() {
        let cs = scrollView?.contentSize ?? NSSize(width: 100, height: 100)
        let w = max(cs.width, CGFloat(bitmap.width) * zoom + pad * 2 + 16)
        let h = max(cs.height, CGFloat(bitmap.height) * zoom + pad * 2 + 16)
        if abs(frame.width - w) > 0.5 || abs(frame.height - h) > 0.5 { setFrameSize(NSSize(width: w, height: h)) }
    }

    // MARK: zoom

    func nearestLevel(_ z: CGFloat) -> Int {
        var best = 0
        var bd = CGFloat.greatestFiniteMagnitude
        for (i, l) in CanvasView.levels.enumerated() where abs(log(l / z)) < bd { bd = abs(log(l / z)); best = i }
        return best
    }

    func setZoom(_ z: CGFloat, anchor: CGPoint? = nil) {
        commitText()
        guard let sv = scrollView else { zoom = z; return }
        let vis = visibleRect
        let a = anchor ?? CGPoint(x: vis.midX, y: vis.midY)
        let imgPt = CGPoint(x: (a.x - pad) / zoom, y: (a.y - pad) / zoom)
        let inVis = CGPoint(x: a.x - vis.minX, y: a.y - vis.minY)
        zoom = z
        fitFrame()
        var o = CGPoint(x: pad + imgPt.x * zoom - inVis.x, y: pad + imgPt.y * zoom - inVis.y)
        o.x = max(0, min(o.x, frame.width - vis.width))
        o.y = max(0, min(o.y, frame.height - vis.height))
        sv.contentView.scroll(to: o)
        sv.reflectScrolledClipView(sv.contentView)
        needsDisplay = true
        onStatus?()
    }

    func zoomStep(_ dir: Int, anchor: CGPoint? = nil) {
        let i = nearestLevel(zoom)
        let j = max(0, min(CanvasView.levels.count - 1, i + dir))
        if CanvasView.levels[j] != zoom { setZoom(CanvasView.levels[j], anchor: anchor) }
    }

    func zoomToFit() {
        guard let cs = scrollView?.contentSize else { return }
        let fw = (cs.width - pad * 2 - 16) / CGFloat(bitmap.width)
        let fh = (cs.height - pad * 2 - 16) / CGFloat(bitmap.height)
        let target = min(fw, fh)
        var best = CanvasView.levels[0]
        for l in CanvasView.levels where l <= target { best = l }
        setZoom(best)
    }

    override func scrollWheel(with e: NSEvent) {
        let mods = e.modifierFlags
        if mods.contains(.command) || mods.contains(.control) || settings.wheelZooms {
            if !e.momentumPhase.isEmpty { return }
            var d = e.scrollingDeltaY
            if d == 0 { d = e.scrollingDeltaX }
            if e.isDirectionInvertedFromDevice { d = -d }
            let anchor = convert(e.locationInWindow, from: nil)
            if e.hasPreciseScrollingDeltas {
                wheelAccum += d
                if abs(wheelAccum) >= 10 {
                    zoomStep(wheelAccum > 0 ? 1 : -1, anchor: anchor)
                    wheelAccum = 0
                }
            } else if d != 0 {
                zoomStep(d > 0 ? 1 : -1, anchor: anchor)
            }
        } else {
            super.scrollWheel(with: e)
        }
    }

    override func magnify(with e: NSEvent) {
        pinchAccum += e.magnification
        if abs(pinchAccum) > 0.12 {
            zoomStep(pinchAccum > 0 ? 1 : -1, anchor: convert(e.locationInWindow, from: nil))
            pinchAccum = 0
        }
    }

    // MARK: drawing the view

    override func draw(_ dirtyRect: NSRect) {
        guard let c = NSGraphicsContext.current?.cgContext else { return }
        c.setFillColor(NSColor(srgbRed: 0.79, green: 0.83, blue: 0.90, alpha: 1).cgColor)
        c.fill(dirtyRect)

        let ir = imageRect
        // subtle border
        c.setStrokeColor(NSColor(white: 0.55, alpha: 1).cgColor)
        c.setLineWidth(1)
        c.stroke(ir.insetBy(dx: -0.5, dy: -0.5))

        let vis = dirtyRect.intersection(ir)
        if !vis.isNull && vis.width > 0 && vis.height > 0 {
            let x0 = max(0, floor((vis.minX - ir.minX) / zoom)), y0 = max(0, floor((vis.minY - ir.minY) / zoom))
            let x1 = min(CGFloat(bitmap.width), ceil((vis.maxX - ir.minX) / zoom))
            let y1 = min(CGFloat(bitmap.height), ceil((vis.maxY - ir.minY) / zoom))
            let src = CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            if src.width > 0, src.height > 0, let sub = bitmap.image.cropping(to: src) {
                c.interpolationQuality = zoom < 1 ? .high : .none
                drawCG(sub, in: CGRect(x: ir.minX + x0 * zoom, y: ir.minY + y0 * zoom, width: src.width * zoom, height: src.height * zoom), on: c)
            }
        }

        // image-space overlays
        c.saveGState()
        c.translateBy(x: ir.minX, y: ir.minY)
        c.scaleBy(x: zoom, y: zoom)
        c.interpolationQuality = zoom < 1 ? .high : .none
        if let s = sel, let img = s.image { drawCG(img, in: s.rect, on: c) }
        if let d = draft { renderShape(d, on: c) }
        c.restoreGState()

        // pixel grid
        if settings.showGrid && zoom >= 8 {
            c.setFillColor(NSColor(white: 0.45, alpha: 0.28).cgColor)
            let gx0 = max(0, Int(floor((dirtyRect.minX - ir.minX) / zoom))), gx1 = min(bitmap.width, Int(ceil((dirtyRect.maxX - ir.minX) / zoom)))
            let gy0 = max(0, Int(floor((dirtyRect.minY - ir.minY) / zoom))), gy1 = min(bitmap.height, Int(ceil((dirtyRect.maxY - ir.minY) / zoom)))
            let top = max(dirtyRect.minY, ir.minY), bot = min(dirtyRect.maxY, ir.maxY)
            let left = max(dirtyRect.minX, ir.minX), right = min(dirtyRect.maxX, ir.maxX)
            if gx0 <= gx1 { for i in gx0...gx1 { c.fill(CGRect(x: ir.minX + CGFloat(i) * zoom - 0.5, y: top, width: 1, height: max(0, bot - top))) } }
            if gy0 <= gy1 { for j in gy0...gy1 { c.fill(CGRect(x: left, y: ir.minY + CGFloat(j) * zoom - 0.5, width: max(0, right - left), height: 1)) } }
        }

        // selection ants
        if let r = selDragRect, settings.tool == .select { ants(rect: toView(r), on: c) }
        if let s = sel {
            if let p = s.path {
                var t = CGAffineTransform(translationX: ir.minX + s.rect.minX * zoom, y: ir.minY + s.rect.minY * zoom).scaledBy(x: zoom, y: zoom)
                if let vp = p.copy(using: &t) { antsPath(vp, on: c) }
            } else {
                ants(rect: toView(s.rect), on: c)
            }
        }
        if settings.tool == .freeSelect, freePts.count > 1 {
            let p = CGMutablePath()
            for (i, q) in freePts.enumerated() {
                let v = CGPoint(x: ir.minX + q.x * zoom, y: ir.minY + q.y * zoom)
                if i == 0 { p.move(to: v) } else { p.addLine(to: v) }
            }
            antsPath(p, on: c)
        }

        // text box border
        if let tv = textView {
            c.setStrokeColor(NSColor(white: 0.2, alpha: 1).cgColor)
            c.setLineDash(phase: 0, lengths: [3, 3])
            c.stroke(tv.frame.insetBy(dx: -1.5, dy: -1.5))
            c.setLineDash(phase: 0, lengths: [])
        }

        // canvas resize handles
        for (r, _) in handleRects() {
            c.setFillColor(NSColor.white.cgColor)
            c.fill(r)
            c.setStrokeColor(NSColor(white: 0.25, alpha: 1).cgColor)
            c.setLineWidth(1)
            c.stroke(r.insetBy(dx: 0.5, dy: 0.5))
        }
        if let (w, h) = resizeNewSize {
            c.setStrokeColor(NSColor(white: 0.1, alpha: 1).cgColor)
            c.setLineDash(phase: 0, lengths: [4, 3])
            c.stroke(CGRect(x: ir.minX, y: ir.minY, width: CGFloat(w) * zoom, height: CGFloat(h) * zoom))
            c.setLineDash(phase: 0, lengths: [])
        }

        // tool footprint under cursor
        if let h = hoverPx, !dragging, textView == nil, resizeHandle == nil {
            drawFootprint(h, on: c)
        }
    }

    func eraserSide() -> Int { max(4, settings.size * 2) }

    func drawFootprint(_ h: CGPoint, on c: CGContext) {
        guard inBounds(h) else { return }
        var r: CGRect?
        var round = false
        switch settings.tool {
        case .pencil, .fill, .picker: r = CGRect(x: h.x, y: h.y, width: 1, height: 1)
        case .eraser:
            let s = CGFloat(eraserSide()), half = CGFloat(eraserSide() / 2)
            r = CGRect(x: h.x - half, y: h.y - half, width: s, height: s)
        case .brush:
            let s = CGFloat(settings.size)
            r = CGRect(x: h.x + 0.5 - s / 2, y: h.y + 0.5 - s / 2, width: s, height: s)
            round = settings.brush != .marker
        default: break
        }
        guard let rr = r else { return }
        let v = toView(rr)
        if v.width < 4 && settings.tool != .brush { return }
        c.setLineWidth(1)
        c.setStrokeColor(NSColor.black.withAlphaComponent(0.85).cgColor)
        if round { c.strokeEllipse(in: v.insetBy(dx: 0.5, dy: 0.5)) } else { c.stroke(v.insetBy(dx: 0.5, dy: 0.5)) }
        if v.width > 6 {
            c.setStrokeColor(NSColor.white.withAlphaComponent(0.85).cgColor)
            if round { c.strokeEllipse(in: v.insetBy(dx: 1.5, dy: 1.5)) } else { c.stroke(v.insetBy(dx: 1.5, dy: 1.5)) }
        }
    }

    func ants(rect: CGRect, on c: CGContext) {
        antsPath(CGPath(rect: rect.insetBy(dx: -0.5, dy: -0.5), transform: nil), on: c)
    }
    func antsPath(_ p: CGPath, on c: CGContext) {
        c.saveGState()
        c.setLineWidth(1)
        c.setStrokeColor(NSColor.white.cgColor)
        c.addPath(p); c.strokePath()
        c.setStrokeColor(NSColor.black.cgColor)
        c.setLineDash(phase: 0, lengths: [4, 4])
        c.addPath(p); c.strokePath()
        c.restoreGState()
    }

    func handleRects() -> [(CGRect, Handle)] {
        let ir = imageRect
        let s: CGFloat = 6
        return [
            (CGRect(x: ir.maxX + 2, y: ir.midY - s / 2, width: s, height: s), .right),
            (CGRect(x: ir.midX - s / 2, y: ir.maxY + 2, width: s, height: s), .bottom),
            (CGRect(x: ir.maxX + 2, y: ir.maxY + 2, width: s, height: s), .corner)
        ]
    }
    func handleHit(_ p: CGPoint) -> Handle? {
        for (r, h) in handleRects() where r.insetBy(dx: -4, dy: -4).contains(p) { return h }
        return nil
    }

    // MARK: settings changes

    @objc func settingsChanged() {
        if settings.tool != lastTool {
            let old = lastTool
            lastTool = settings.tool
            if settings.tool == .picker { toolBeforePicker = old }
            if old == .text || textView != nil { commitText() }
            if old == .shape { commitDraft() }
            if settings.tool != .freeSelect { freePts = [] }
        }
        if let tv = textView { applyTextAttributes(tv) }
        needsDisplay = true
        updateCursor()
    }

    // MARK: undo / redo

    func pushUndo() {
        undoStack.append(DocState(image: bitmap.image, sel: sel))
        redoStack.removeAll()
        let bytes = max(1, bitmap.width * bitmap.height * 4)
        let cap = max(8, min(100, 800_000_000 / bytes))
        if undoStack.count > cap { undoStack.removeFirst(undoStack.count - cap) }
        isModified = true
    }

    /// Start a destructive operation: save state, drop text edit, flatten any floating selection.
    func beginOp() {
        commitText()
        pushUndo()
        flattenSelection()
    }

    func flattenSelection() {
        if let s = sel, let img = s.image {
            drawCG(img, in: s.rect, on: bitmap.ctx)
            bitmap.touch()
        }
        sel = nil
    }

    func commitSelection() {
        guard let s = sel else { return }
        if s.lifted { pushUndo(); flattenSelection() } else { sel = nil }
        needsDisplay = true
        onStatus?()
    }

    func apply(_ st: DocState) {
        draft = nil; draftPhase = 0
        bitmap.replace(with: st.image)
        sel = st.sel
        fitFrame()
        needsDisplay = true
        onStatus?()
    }

    func undo() {
        if let tv = textView { tv.undoManager?.undo(); return }
        guard let st = undoStack.popLast() else { return }
        redoStack.append(DocState(image: bitmap.image, sel: sel))
        apply(st)
        isModified = true
    }

    func redo() {
        if let tv = textView { tv.undoManager?.redo(); return }
        guard let st = redoStack.popLast() else { return }
        undoStack.append(DocState(image: bitmap.image, sel: sel))
        apply(st)
        isModified = true
    }

    // MARK: mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for t in trackingAreas { removeTrackingArea(t) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .cursorUpdate, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with e: NSEvent) {
        let vp = convert(e.locationInWindow, from: nil)
        let px = pixelOf(vp)
        let old = hoverPx
        hoverPx = px
        hoverHandle = handleHit(vp)
        if settings.tool == .shape, settings.shape == .polygon, var d = draft {
            d.polyCursor = px
            draft = d
            needsDisplay = true
        }
        if let o = old { invalidate(CGRect(x: o.x - 40, y: o.y - 40, width: 80, height: 80)) }
        invalidate(CGRect(x: px.x - 40, y: px.y - 40, width: 80, height: 80))
        updateCursor()
        onStatus?()
    }
    override func mouseExited(with e: NSEvent) { hoverPx = nil; needsDisplay = true; onStatus?() }
    override func cursorUpdate(with e: NSEvent) { updateCursor() }

    func updateCursor() {
        var cur = NSCursor.crosshair
        if let h = hoverHandle {
            switch h {
            case .right: cur = .resizeLeftRight
            case .bottom: cur = .resizeUpDown
            case .corner: cur = NSCursor.frameResize(position: .bottomRight, directions: .all)
            }
        } else if settings.tool == .text {
            cur = .iBeam
        } else if (settings.tool == .select || settings.tool == .freeSelect), let s = sel, let h = hoverPx, selContains(s, h) {
            cur = .openHand
        }
        cur.set()
    }

    override func mouseDown(with e: NSEvent) { down(e, secondary: false) }
    override func rightMouseDown(with e: NSEvent) { down(e, secondary: true) }
    override func mouseDragged(with e: NSEvent) { drag(e) }
    override func rightMouseDragged(with e: NSEvent) { drag(e) }
    override func mouseUp(with e: NSEvent) { up(e) }
    override func rightMouseUp(with e: NSEvent) { up(e) }

    func constrained(_ p0: CGPoint, _ p1: CGPoint, line: Bool) -> CGPoint {
        let dx = p1.x - p0.x, dy = p1.y - p0.y
        if line {
            let ang = atan2(dy, dx)
            let snapped = (ang / (.pi / 4)).rounded() * (.pi / 4)
            let len = hypot(dx, dy)
            return CGPoint(x: p0.x + (len * cos(snapped)).rounded(), y: p0.y + (len * sin(snapped)).rounded())
        }
        let m = max(abs(dx), abs(dy))
        return CGPoint(x: p0.x + (dx < 0 ? -m : m), y: p0.y + (dy < 0 ? -m : m))
    }

    func down(_ e: NSEvent, secondary: Bool) {
        let vp = convert(e.locationInWindow, from: nil)
        if textView != nil { commitText() }
        window?.makeFirstResponder(self)
        isSecondary = secondary
        dragging = true
        let fg = secondary ? settings.color2 : settings.color1
        let bg = secondary ? settings.color1 : settings.color2
        strokeFG = fg; strokeBG = bg

        if let h = handleHit(vp) {
            resizeHandle = h
            resizeStartView = vp
            resizeNewSize = (bitmap.width, bitmap.height)
            return
        }
        let p = toImage(vp)
        let px = CGPoint(x: floor(p.x), y: floor(p.y))
        lastP = px

        switch settings.tool {
        case .magnifier:
            zoomStep(secondary ? -1 : 1, anchor: vp)
            dragging = false
        case .picker:
            if let col = bitmap.pixel(Int(px.x), Int(px.y)) {
                if secondary { settings.color2 = col; } else { settings.color1 = col }
            }
            dragging = false
            if toolBeforePicker != .picker { settings.tool = toolBeforePicker }
        case .fill:
            if inBounds(px) {
                beginOp()
                bitmap.floodFill(x: Int(px.x), y: Int(px.y), color: fg)
                needsDisplay = true
            }
            dragging = false
        case .pencil, .eraser, .brush:
            strokeBegin(px, tool: settings.tool)
        case .shape:
            shapeDown(px, e: e)
        case .text:
            selDragStart = p
            selDragRect = CGRect(origin: CGPoint(x: round(p.x), y: round(p.y)), size: .zero)
        case .select:
            if let s = sel, selContains(s, px) {
                startMove(p, option: e.modifierFlags.contains(.option))
            } else {
                commitSelection()
                selDragStart = CGPoint(x: round(p.x), y: round(p.y))
                selDragRect = nil
            }
        case .freeSelect:
            if let s = sel, selContains(s, px) {
                startMove(p, option: e.modifierFlags.contains(.option))
            } else {
                commitSelection()
                freePts = [clampPoint(p)]
            }
        }
        if settings.tool != .pencil && settings.tool != .eraser && settings.tool != .brush { onStatus?() }
    }

    func clampPoint(_ p: CGPoint) -> CGPoint {
        CGPoint(x: max(0, min(CGFloat(bitmap.width), round(p.x))), y: max(0, min(CGFloat(bitmap.height), round(p.y))))
    }

    func drag(_ e: NSEvent) {
        guard dragging else { return }
        let vp = convert(e.locationInWindow, from: nil)
        autoscroll(with: e)
        let p = toImage(vp)
        let px = CGPoint(x: floor(p.x), y: floor(p.y))
        hoverPx = px

        if let h = resizeHandle {
            let dx = (vp.x - resizeStartView.x) / zoom, dy = (vp.y - resizeStartView.y) / zoom
            var w = bitmap.width, hh = bitmap.height
            if h == .right || h == .corner { w = max(1, bitmap.width + Int(dx.rounded())) }
            if h == .bottom || h == .corner { hh = max(1, bitmap.height + Int(dy.rounded())) }
            resizeNewSize = (w, hh)
            needsDisplay = true
            onStatus?()
            return
        }

        switch settings.tool {
        case .pencil, .eraser, .brush:
            strokeMove(px)
        case .shape:
            shapeDrag(px, e: e)
        case .text:
            if let s = selDragStart {
                selDragRect = CGRect(x: min(s.x, round(p.x)), y: min(s.y, round(p.y)), width: abs(round(p.x) - s.x), height: abs(round(p.y) - s.y))
                needsDisplay = true
            }
        case .select:
            if moveAnchor != nil { moveSelection(to: p) }
            else if let s = selDragStart {
                let q = clampPoint(p)
                selDragRect = CGRect(x: min(s.x, q.x), y: min(s.y, q.y), width: abs(q.x - s.x), height: abs(q.y - s.y))
                needsDisplay = true
            }
        case .freeSelect:
            if moveAnchor != nil { moveSelection(to: p) }
            else if !freePts.isEmpty {
                let q = clampPoint(p)
                if q != freePts.last { freePts.append(q) }
                needsDisplay = true
            }
        default: break
        }
        onStatus?()
    }

    func up(_ e: NSEvent) {
        let wasDragging = dragging
        dragging = false
        guard wasDragging else { return }
        let vp = convert(e.locationInWindow, from: nil)
        let p = toImage(vp)

        if let h = resizeHandle {
            _ = h
            resizeHandle = nil
            if let (w, hh) = resizeNewSize, w != bitmap.width || hh != bitmap.height { resizeCanvas(w, hh) }
            resizeNewSize = nil
            needsDisplay = true
            onStatus?()
            return
        }

        switch settings.tool {
        case .pencil, .eraser, .brush: strokeEnd()
        case .shape: shapeUp(e)
        case .text:
            if let r = selDragRect, let s = selDragStart {
                _ = s
                let rect = CGRect(x: r.minX, y: r.minY, width: max(r.width, 60), height: max(r.height, CGFloat(settings.fontSize) * 96 / 72 * 1.4))
                selDragRect = nil; selDragStart = nil
                beginText(rect)
            }
        case .select:
            if moveAnchor != nil { endMove() }
            else if let r = selDragRect, r.width >= 1, r.height >= 1 { sel = Selection(rect: r, image: nil, path: nil) }
            selDragRect = nil; selDragStart = nil
        case .freeSelect:
            if moveAnchor != nil { endMove() }
            else if freePts.count > 2 {
                let path = CGMutablePath()
                for (i, q) in freePts.enumerated() { if i == 0 { path.move(to: q) } else { path.addLine(to: q) } }
                path.closeSubpath()
                let bb = path.boundingBoxOfPath.integral.intersection(bitmap.bounds)
                if bb.width >= 1, bb.height >= 1 {
                    var t = CGAffineTransform(translationX: -bb.minX, y: -bb.minY)
                    sel = Selection(rect: bb, image: nil, path: path.copy(using: &t))
                }
            }
            freePts = []
        default: break
        }
        _ = p
        needsDisplay = true
        onStatus?()
    }

    // MARK: pencil / eraser / brushes

    func strokeBegin(_ px: CGPoint, tool: Tool) {
        beginOp()
        strokeKind = tool
        let center = CGPoint(x: px.x + 0.5, y: px.y + 0.5)
        strokePts = [center]
        lastP = center
        strokeBase = nil
        if tool == .brush, translucentAlpha() != nil { strokeBase = bitmap.image }
        if tool == .brush && settings.brush == .airbrush {
            airTimer = Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.spray(self.lastP)
            }
        }
        stamp(center)
    }

    func strokeMove(_ px: CGPoint) {
        let c = CGPoint(x: px.x + 0.5, y: px.y + 0.5)
        guard c != lastP else { return }
        if strokeBase != nil {
            strokePts.append(c)
            lastP = c
            redrawTranslucent()
            return
        }
        let s = CGFloat(strokeKind == .pencil ? 1 : max(1, settings.size))
        let spacing = max(1, s / 4)
        let a = lastP
        let d = hypot(c.x - a.x, c.y - a.y)
        let n = max(1, Int(ceil(d / spacing)))
        for i in 1...n {
            let t = CGFloat(i) / CGFloat(n)
            stamp(CGPoint(x: a.x + (c.x - a.x) * t, y: a.y + (c.y - a.y) * t))
        }
        lastP = c
    }

    func strokeEnd() {
        airTimer?.invalidate(); airTimer = nil
        strokeBase = nil
        strokePts = []
    }

    func translucentAlpha() -> CGFloat? {
        guard settings.tool == .brush || strokeKind == .brush else { return nil }
        switch settings.brush {
        case .marker: return 0.5
        case .oil: return 0.8
        case .watercolor: return 0.35
        default: return nil
        }
    }

    func stamp(_ p: CGPoint) {
        let c = bitmap.ctx
        let s = CGFloat(max(1, settings.size))
        var dirty = CGRect(x: p.x - s - 2, y: p.y - s - 2, width: s * 2 + 4, height: s * 2 + 4)
        c.saveGState()
        switch strokeKind {
        case .pencil:
            c.setShouldAntialias(false)
            c.setFillColor(strokeFG.cg)
            c.fill(CGRect(x: floor(p.x), y: floor(p.y), width: 1, height: 1))
        case .eraser:
            let side = CGFloat(eraserSide()), half = CGFloat(eraserSide() / 2)
            c.setShouldAntialias(false)
            c.setFillColor(strokeBG.cg)
            let r = CGRect(x: floor(p.x) - half, y: floor(p.y) - half, width: side, height: side)
            c.fill(r)
            dirty = r.insetBy(dx: -2, dy: -2)
        case .brush:
            switch settings.brush {
            case .brush:
                c.setShouldAntialias(settings.antialias)
                c.setFillColor(strokeFG.cg)
                c.fillEllipse(in: CGRect(x: p.x - s / 2, y: p.y - s / 2, width: s, height: s))
            case .calligraphy1, .calligraphy2:
                c.setShouldAntialias(settings.antialias)
                c.setStrokeColor(strokeFG.cg)
                c.setLineWidth(1.5)
                let h = max(1, s) / 2
                if settings.brush == .calligraphy1 { c.move(to: CGPoint(x: p.x - h, y: p.y + h)); c.addLine(to: CGPoint(x: p.x + h, y: p.y - h)) }
                else { c.move(to: CGPoint(x: p.x - h, y: p.y - h)); c.addLine(to: CGPoint(x: p.x + h, y: p.y + h)) }
                c.strokePath()
            case .airbrush:
                spray(p)
            case .crayon:
                speckle(p, radius: s * 0.8 + 1, density: 0.55, on: c)
            case .naturalPencil:
                speckle(p, radius: s * 0.5 + 1, density: 0.8, on: c)
            default: break   // translucent kinds use redrawTranslucent
            }
        default: break
        }
        c.restoreGState()
        bitmap.touch()
        invalidate(dirty)
    }

    func speckle(_ p: CGPoint, radius r: CGFloat, density: CGFloat, on c: CGContext) {
        c.setShouldAntialias(false)
        c.setFillColor(strokeFG.cg)
        let n = Int(r * r * density * 1.6) + 2
        for _ in 0..<n {
            let a = CGFloat.random(in: 0..<(2 * .pi)), d = sqrt(CGFloat.random(in: 0...1)) * r
            c.fill(CGRect(x: floor(p.x + cos(a) * d), y: floor(p.y + sin(a) * d), width: 1, height: 1))
        }
    }

    func spray(_ p: CGPoint) {
        let s = CGFloat(max(1, settings.size))
        let r = s * 1.5 + 3
        let c = bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.setFillColor(strokeFG.cg)
        let n = Int(r * r * 0.12) + 3
        for _ in 0..<n {
            let a = CGFloat.random(in: 0..<(2 * .pi)), d = sqrt(CGFloat.random(in: 0...1)) * r
            c.fill(CGRect(x: floor(p.x + cos(a) * d), y: floor(p.y + sin(a) * d), width: 1, height: 1))
        }
        c.restoreGState()
        bitmap.touch()
        invalidate(CGRect(x: p.x - r - 2, y: p.y - r - 2, width: r * 2 + 4, height: r * 2 + 4))
    }

    func redrawTranslucent() {
        guard let base = strokeBase, let alpha = translucentAlpha(), let first = strokePts.first else { return }
        let s = CGFloat(max(1, settings.size))
        var bb = CGRect(origin: first, size: .zero)
        for q in strokePts { bb = bb.union(CGRect(origin: q, size: .zero)) }
        bb = bb.insetBy(dx: -s - 2, dy: -s - 2).integral.intersection(bitmap.bounds)
        let c = bitmap.ctx
        c.saveGState()
        c.clip(to: bb)
        c.setBlendMode(.copy)
        drawCG(base, in: bitmap.bounds, on: c)
        c.setBlendMode(.normal)
        c.setShouldAntialias(settings.antialias)
        c.setStrokeColor(strokeFG.ns.withAlphaComponent(alpha).cgColor)
        c.setLineWidth(s)
        c.setLineCap(settings.brush == .marker ? .square : .round)
        c.setLineJoin(settings.brush == .marker ? .bevel : .round)
        c.move(to: first)
        if strokePts.count == 1 { c.addLine(to: CGPoint(x: first.x + 0.01, y: first.y)) }
        for q in strokePts.dropFirst() { c.addLine(to: q) }
        c.strokePath()
        c.restoreGState()
        bitmap.touch()
        invalidate(bb)
    }

    // MARK: shapes

    func newDraft(_ px: CGPoint) -> ShapeDraft {
        ShapeDraft(kind: settings.shape, p0: px, p1: px,
                   outlineColor: strokeFG, fillColor: strokeBG,
                   outline: settings.outline, fill: settings.fill,
                   width: CGFloat(settings.size), antialias: settings.antialias)
    }

    func shapeDown(_ px: CGPoint, e: NSEvent) {
        switch settings.shape {
        case .polygon:
            if var d = draft {
                if e.clickCount >= 2 { commitDraft(); dragging = false; return }
                d.points.append(px)
                draft = d
            } else {
                var d = newDraft(px)
                d.points = [px]
                d.polyCursor = px
                draft = d
            }
            needsDisplay = true
        case .curve:
            if var d = draft {
                if e.clickCount >= 2 { commitDraft(); dragging = false; return }
                if draftPhase == 1 { d.controls = [px, px] } else { if d.controls.count < 2 { d.controls = [px, px] } else { d.controls[1] = px } }
                draft = d
            } else {
                draft = newDraft(px)
                draftPhase = 0
            }
            needsDisplay = true
        default:
            draft = newDraft(px)
            needsDisplay = true
        }
    }

    func shapeDrag(_ px: CGPoint, e: NSEvent) {
        guard var d = draft else { return }
        let shift = e.modifierFlags.contains(.shift)
        switch d.kind {
        case .polygon:
            d.polyCursor = px
        case .curve:
            if draftPhase == 0 {
                d.p1 = shift ? constrained(d.p0, px, line: true) : px
            } else if draftPhase == 1 {
                d.controls = [px, px]
            } else {
                if d.controls.count < 2 { d.controls = [d.controls.first ?? px, px] } else { d.controls[1] = px }
            }
        case .line:
            d.p1 = shift ? constrained(d.p0, px, line: true) : px
        default:
            d.p1 = shift ? constrained(d.p0, px, line: false) : px
        }
        draft = d
        needsDisplay = true
    }

    func shapeUp(_ e: NSEvent) {
        guard let d = draft else { return }
        switch d.kind {
        case .polygon:
            break
        case .curve:
            if draftPhase == 0 {
                if d.p0 == d.p1 { draft = nil; needsDisplay = true; return }
                draftPhase = 1
            } else if draftPhase == 1 {
                draftPhase = 2
            } else {
                commitDraft()
            }
        default:
            if d.p0 == d.p1 { draft = nil; needsDisplay = true } else { commitDraft() }
        }
    }

    func commitDraft() {
        guard var d = draft else { return }
        if d.kind == .polygon {
            d.polyCursor = nil
            if d.points.count < 2 { draft = nil; draftPhase = 0; needsDisplay = true; return }
        }
        beginOp()
        renderShape(d, on: bitmap.ctx)
        bitmap.touch()
        draft = nil
        draftPhase = 0
        needsDisplay = true
    }

    func cancelDraft() {
        draft = nil; draftPhase = 0; needsDisplay = true
    }

    // MARK: selection

    func selContains(_ s: Selection, _ p: CGPoint) -> Bool {
        guard s.rect.contains(p) else { return false }
        if let path = s.path { return path.contains(CGPoint(x: p.x - s.rect.minX, y: p.y - s.rect.minY)) }
        return true
    }

    func captureRegion(_ r: CGRect, path: CGPath?) -> CGImage {
        let b = Bitmap(width: Int(r.width), height: Int(r.height), fill: nil)
        b.ctx.saveGState()
        if let p = path { b.ctx.setShouldAntialias(false); b.ctx.addPath(p); b.ctx.clip() }
        drawCG(bitmap.image, in: CGRect(x: -r.minX, y: -r.minY, width: CGFloat(bitmap.width), height: CGFloat(bitmap.height)), on: b.ctx)
        b.ctx.restoreGState()
        return b.image
    }

    func clearRegion(_ r: CGRect, path: CGPath?, color: RGBA) {
        let c = bitmap.ctx
        c.saveGState()
        c.setShouldAntialias(false)
        c.translateBy(x: r.minX, y: r.minY)
        if let p = path { c.addPath(p); c.clip() } else { c.clip(to: CGRect(x: 0, y: 0, width: r.width, height: r.height)) }
        c.setFillColor(color.cg)
        c.fill(CGRect(x: 0, y: 0, width: r.width, height: r.height))
        c.restoreGState()
        bitmap.touch()
    }

    func lift(copy: Bool) {
        guard var s = sel, s.image == nil else { return }
        var img = captureRegion(s.rect, path: s.path)
        if settings.transparentSelection { img = Bitmap.keyedOut(img, bg: settings.color2) }
        if !copy { clearRegion(s.rect, path: s.path, color: settings.color2) }
        s.image = img
        sel = s
    }

    func startMove(_ p: CGPoint, option: Bool) {
        moveAnchor = p
        moveOrigin = sel?.rect.origin ?? .zero
        movePending = true
        moveCopy = option
    }

    func moveSelection(to p: CGPoint) {
        guard let a = moveAnchor, var s = sel else { return }
        let dx = (p.x - a.x).rounded(), dy = (p.y - a.y).rounded()
        if movePending {
            if dx == 0 && dy == 0 { return }
            pushUndo()
            lift(copy: moveCopy)
            movePending = false
            s = sel!
        }
        s.rect.origin = CGPoint(x: moveOrigin.x + dx, y: moveOrigin.y + dy)
        sel = s
        needsDisplay = true
    }

    func endMove() { moveAnchor = nil; movePending = false }

    func selectAll() {
        commitSelection()
        commitText()
        sel = Selection(rect: bitmap.bounds, image: nil, path: nil)
        if settings.tool != .select && settings.tool != .freeSelect { settings.tool = .select }
        needsDisplay = true
        onStatus?()
    }

    func deleteSelection() {
        guard let s = sel else { return }
        pushUndo()
        if !s.lifted { clearRegion(s.rect, path: s.path, color: settings.color2) }
        sel = nil
        needsDisplay = true
        onStatus?()
    }

    func selectionImage() -> CGImage? {
        guard let s = sel else { return nil }
        return s.image ?? captureRegion(s.rect, path: s.path)
    }

    func copyToPasteboard() {
        let img = selectionImage() ?? flattenedImage()
        let ns = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.writeObjects([ns])
    }

    func cut() {
        guard sel != nil else { return }
        copyToPasteboard()
        deleteSelection()
    }

    func copySel() { copyToPasteboard() }

    func imageFromPasteboard() -> CGImage? {
        let pb = NSPasteboard.general
        guard let imgs = pb.readObjects(forClasses: [NSImage.self], options: nil) as? [NSImage], let img = imgs.first else { return nil }
        if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep }).first, let cg = rep.cgImage { return cg }
        var r = CGRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &r, context: nil, hints: nil)
    }

    func paste() {
        guard let img = imageFromPasteboard() else { NSSound.beep(); return }
        commitText()
        pushUndo()
        flattenSelection()
        if img.width > bitmap.width || img.height > bitmap.height {
            bitmap.resizeCanvas(width: max(img.width, bitmap.width), height: max(img.height, bitmap.height), fill: .white)
            fitFrame()
        }
        let vis = visibleRect
        let ox = max(0, min(CGFloat(bitmap.width - img.width), floor((vis.minX - pad) / zoom)))
        let oy = max(0, min(CGFloat(bitmap.height - img.height), floor((vis.minY - pad) / zoom)))
        var f = img
        if settings.transparentSelection { f = Bitmap.keyedOut(img, bg: settings.color2) }
        sel = Selection(rect: CGRect(x: max(0, ox), y: max(0, oy), width: CGFloat(img.width), height: CGFloat(img.height)), image: f, path: nil)
        settings.tool = .select
        needsDisplay = true
        onStatus?()
    }

    func cropToSelection() {
        guard let s = sel else { return }
        let img = s.image ?? captureRegion(s.rect, path: s.path)
        pushUndo()
        sel = nil
        let b = Bitmap(width: img.width, height: img.height, fill: settings.color2)
        drawCG(img, in: b.bounds, on: b.ctx)
        bitmap.replace(with: b.image)
        fitFrame()
        needsDisplay = true
        onStatus?()
    }

    func nudge(_ dx: CGFloat, _ dy: CGFloat) {
        guard var s = sel else { return }
        if Date().timeIntervalSince(lastNudge) > 0.8 || !s.lifted {
            pushUndo()
            lift(copy: false)
            s = sel!
        }
        lastNudge = Date()
        s.rect.origin.x += dx; s.rect.origin.y += dy
        sel = s
        needsDisplay = true
    }

    // MARK: image-level ops

    func transformSelection(_ f: (CGImage) -> CGImage) {
        pushUndo()
        if !(sel?.lifted ?? false) { lift(copy: false) }
        guard var s = sel, let img = s.image else { return }
        let n = f(img)
        s.image = n
        s.rect.size = CGSize(width: n.width, height: n.height)
        s.path = nil
        sel = s
    }

    func transform(_ f: (CGImage) -> CGImage) {
        if sel != nil { transformSelection(f) }
        else {
            beginOp()
            bitmap.replace(with: f(bitmap.image))
            fitFrame()
        }
        needsDisplay = true
        onStatus?()
    }

    func rotateRight() { transform(Bitmap.rotatedRight) }
    func rotateLeft() { transform(Bitmap.rotatedLeft) }
    func rotate180() { transform(Bitmap.rotated180) }
    func flipH() { transform(Bitmap.flippedH) }
    func flipV() { transform(Bitmap.flippedV) }

    func scaleTo(width w: Int, height h: Int) {
        guard w >= 1, h >= 1, w <= 30000, h <= 30000 else { return }
        transform { Bitmap.scaled($0, width: w, height: h) }
    }

    func resizeCanvas(_ w: Int, _ h: Int) {
        beginOp()
        bitmap.resizeCanvas(width: w, height: h, fill: .white)
        fitFrame()
        needsDisplay = true
        onStatus?()
    }

    func invertColors() {
        beginOp()
        let c = bitmap.ctx
        c.saveGState()
        c.setBlendMode(.difference)
        c.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        c.fill(bitmap.bounds)
        c.restoreGState()
        bitmap.touch()
        needsDisplay = true
    }

    func clearImage() {
        beginOp()
        bitmap.ctx.setFillColor(settings.color2.cg)
        bitmap.ctx.fill(bitmap.bounds)
        bitmap.touch()
        needsDisplay = true
    }

    // MARK: text

    func textAttributes(scale: CGFloat) -> [NSAttributedString.Key: Any] {
        let px = CGFloat(settings.fontSize) * 96 / 72 * scale
        var f = NSFont(name: settings.fontName, size: px) ?? NSFont.systemFont(ofSize: px)
        let fm = NSFontManager.shared
        if settings.bold { f = fm.convert(f, toHaveTrait: .boldFontMask) }
        if settings.italic { f = fm.convert(f, toHaveTrait: .italicFontMask) }
        var a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: settings.color1.ns]
        if settings.underline { a[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return a
    }

    func applyTextAttributes(_ tv: NSTextView) {
        let a = textAttributes(scale: zoom)
        tv.typingAttributes = a
        if let ts = tv.textStorage, ts.length > 0 { ts.setAttributes(a, range: NSRange(location: 0, length: ts.length)) }
        tv.drawsBackground = !settings.textTransparent
        tv.backgroundColor = settings.color2.ns
        tv.insertionPointColor = settings.color1.ns
    }

    func beginText(_ rectImg: CGRect) {
        commitText()
        let tv = NSTextView(frame: toView(rectImg))
        tv.isRichText = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.minSize = NSSize(width: tv.frame.width, height: tv.frame.height)
        tv.maxSize = NSSize(width: tv.frame.width, height: 1e7)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: tv.frame.width, height: 1e7)
        tv.autoresizingMask = []
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.delegate = self
        applyTextAttributes(tv)
        addSubview(tv)
        textView = tv
        window?.makeFirstResponder(tv)
        needsDisplay = true
    }

    func commitText() {
        guard let tv = textView else { return }
        let str = tv.string
        let f = tv.frame
        let r = CGRect(x: (f.minX - pad) / zoom, y: (f.minY - pad) / zoom, width: f.width / zoom, height: f.height / zoom)
        textView = nil
        tv.delegate = nil
        tv.removeFromSuperview()
        window?.makeFirstResponder(self)
        needsDisplay = true
        guard !str.isEmpty else { return }
        beginOp()
        let c = bitmap.ctx
        c.saveGState()
        if !settings.textTransparent {
            c.setShouldAntialias(false)
            c.setFillColor(settings.color2.cg)
            c.fill(r)
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: c, flipped: true)
        c.setShouldAntialias(true)
        c.setShouldSmoothFonts(false)
        NSAttributedString(string: str, attributes: textAttributes(scale: 1))
            .draw(with: CGRect(x: r.minX, y: r.minY, width: r.width, height: 100000), options: [.usesLineFragmentOrigin])
        NSGraphicsContext.restoreGraphicsState()
        c.restoreGState()
        bitmap.touch()
        needsDisplay = true
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) { commitText(); return true }
        return false
    }

    // MARK: keyboard

    override func keyDown(with e: NSEvent) {
        let step: CGFloat = e.modifierFlags.contains(.shift) ? 10 : 1
        switch e.keyCode {
        case 123 where sel != nil: nudge(-step, 0)
        case 124 where sel != nil: nudge(step, 0)
        case 125 where sel != nil: nudge(0, step)
        case 126 where sel != nil: nudge(0, -step)
        case 51, 117:
            if sel != nil { deleteSelection() } else { super.keyDown(with: e) }
        case 53:
            if draft != nil { cancelDraft() } else if sel != nil { commitSelection() } else { super.keyDown(with: e) }
        case 36, 76:
            if draft != nil { commitDraft() } else { super.keyDown(with: e) }
        default: super.keyDown(with: e)
        }
    }

    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        guard e.modifierFlags.contains(.command), window?.firstResponder === self || textView == nil else { return super.performKeyEquivalent(with: e) }
        switch e.charactersIgnoringModifiers {
        case "=", "+": zoomStep(1); return true
        case "-": zoomStep(-1); return true
        default: return super.performKeyEquivalent(with: e)
        }
    }

    // MARK: document I/O

    func flattenedImage() -> CGImage {
        if let s = sel, let f = s.image {
            let b = Bitmap(image: bitmap.image)
            drawCG(f, in: s.rect, on: b.ctx)
            return b.image
        }
        return bitmap.image
    }

    func resetDocument() {
        undoStack.removeAll(); redoStack.removeAll()
        sel = nil; draft = nil; draftPhase = 0
        commitText()
        isModified = false
        zoom = 1
        fitFrame()
        scrollView?.contentView.scroll(to: .zero)
        needsDisplay = true
        onStatus?()
    }

    func newDocument(width: Int, height: Int) {
        bitmap.replace(with: Bitmap(width: width, height: height).image)
        fileURL = nil
        resetDocument()
    }

    func load(url: URL) -> Bool {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return false }
        bitmap.replace(with: Bitmap(image: img).image)
        fileURL = url
        resetDocument()
        return true
    }

    func save(to url: URL) -> Bool {
        commitText()
        let img = flattenedImage()
        let rep = NSBitmapImageRep(cgImage: img)
        let ext = url.pathExtension.lowercased()
        let data: Data?
        switch ext {
        case "jpg", "jpeg": data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.92])
        case "bmp": data = rep.representation(using: .bmp, properties: [:])
        case "tif", "tiff": data = rep.representation(using: .tiff, properties: [:])
        case "gif": data = rep.representation(using: .gif, properties: [:])
        default: data = rep.representation(using: .png, properties: [:])
        }
        guard let d = data else { return false }
        do { try d.write(to: url) } catch { return false }
        fileURL = url
        isModified = false
        onDocChange?()
        return true
    }
}
