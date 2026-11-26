import AppKit

// MARK: - Helpers

let iconBlue = NSColor(srgbRed: 0.17, green: 0.33, blue: 0.58, alpha: 1)
let ribbonBG = NSColor(srgbRed: 0.961, green: 0.965, blue: 0.969, alpha: 1)
let ribbonLine = NSColor(srgbRed: 0.855, green: 0.859, blue: 0.863, alpha: 1)
let accentBlue = NSColor(srgbRed: 0.098, green: 0.475, blue: 0.792, alpha: 1)

final class ActionBox: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func fire() { f() }
}

extension NSMenu {
    @discardableResult
    func add(_ title: String, checked: Bool = false, image: NSImage? = nil, _ f: @escaping () -> Void) -> NSMenuItem {
        let box = ActionBox(f)
        let it = NSMenuItem(title: title, action: #selector(ActionBox.fire), keyEquivalent: "")
        it.target = box
        it.representedObject = box
        it.state = checked ? .on : .off
        it.image = image
        addItem(it)
        return it
    }
}

func symbol(_ name: String, _ pt: CGFloat = 18, weight: NSFont.Weight = .regular) -> NSImage? {
    let cfg = NSImage.SymbolConfiguration(pointSize: pt, weight: weight)
    return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(cfg)
}

func tinted(_ img: NSImage, _ col: NSColor) -> NSImage {
    let size = img.size
    return NSImage(size: size, flipped: false) { rect in
        img.draw(in: rect)
        col.set()
        rect.fill(using: .sourceAtop)
        return true
    }
}

func shapeIcon(_ k: ShapeKind) -> NSImage {
    NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        iconBlue.setStroke()
        let r = CGRect(x: 2, y: 2, width: 14, height: 14)
        var path: NSBezierPath
        switch k {
        case .line:
            path = NSBezierPath(); path.move(to: NSPoint(x: 2, y: 3)); path.line(to: NSPoint(x: 16, y: 15))
        case .curve:
            path = NSBezierPath(); path.move(to: NSPoint(x: 2, y: 14))
            path.curve(to: NSPoint(x: 16, y: 4), controlPoint1: NSPoint(x: 4, y: 1), controlPoint2: NSPoint(x: 12, y: 18))
        case .polygon:
            path = NSBezierPath()
            let pts = [NSPoint(x: 3, y: 15), NSPoint(x: 2, y: 6), NSPoint(x: 9, y: 2), NSPoint(x: 16, y: 7), NSPoint(x: 12, y: 15)]
            path.move(to: pts[0]); for p in pts.dropFirst() { path.line(to: p) }; path.close()
        default:
            path = NSBezierPath(cgPath: closedShapePath(k, in: r))
        }
        path.lineWidth = 1.2
        path.lineJoinStyle = .miter
        path.stroke()
        return true
    }
}

// MARK: - Ribbon button

final class RibbonButton: NSView {
    enum Style { case large, small, icon }
    var style: Style
    var title: String { didSet { needsDisplay = true } }
    var icon: NSImage? { didSet { needsDisplay = true } }
    var isOn = false { didSet { needsDisplay = true } }
    var enabled = true { didSet { needsDisplay = true } }
    var onClick: (() -> Void)?
    var menuBuilder: (() -> NSMenu)?
    var split = false
    var colorOverride: NSColor?
    private var hovering = false { didSet { needsDisplay = true } }
    private var pressed = false { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }

    init(style: Style, title: String = "", icon: NSImage? = nil, frame: NSRect) {
        self.style = style
        self.title = title
        self.icon = icon
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false; pressed = false }

    override func mouseDown(with event: NSEvent) {
        guard enabled else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let mb = menuBuilder, onClick == nil || (split && p.y > bounds.height * 0.55) {
            hovering = true
            mb().popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height), in: self)
            hovering = false
            return
        }
        pressed = true
    }

    override func mouseUp(with event: NSEvent) {
        guard enabled, pressed else { return }
        pressed = false
        let p = convert(event.locationInWindow, from: nil)
        if bounds.contains(p) { onClick?() }
    }

    override func draw(_ dirtyRect: NSRect) {
        if enabled && (hovering || isOn || pressed) {
            let fill = (isOn || pressed) ? NSColor(srgbRed: 0.80, green: 0.89, blue: 0.97, alpha: 1) : NSColor(srgbRed: 0.90, green: 0.95, blue: 0.99, alpha: 1)
            let stroke = (isOn || pressed) ? NSColor(srgbRed: 0.45, green: 0.65, blue: 0.85, alpha: 1) : NSColor(srgbRed: 0.70, green: 0.82, blue: 0.93, alpha: 1)
            let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            fill.setFill(); r.fill()
            stroke.setStroke(); r.lineWidth = 1; r.stroke()
        }
        let col = enabled ? (colorOverride ?? iconBlue) : NSColor.gray.withAlphaComponent(0.5)
        let textCol = enabled ? NSColor(white: 0.12, alpha: 1) : NSColor.gray
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let font = NSFont.systemFont(ofSize: 11)
        let hasMenu = menuBuilder != nil

        func drawIcon(in box: CGRect) {
            guard let ic = icon else { return }
            let s = ic.size
            let k = min(box.width / s.width, box.height / s.height, 1.6)
            let w = s.width * k, h = s.height * k
            let img = ic.isTemplate ? tinted(ic, col) : ic
            img.draw(in: CGRect(x: box.midX - w / 2, y: box.midY - h / 2, width: w, height: h), from: .zero, operation: .sourceOver, fraction: enabled ? 1 : 0.5, respectFlipped: true, hints: nil)
        }

        switch style {
        case .large:
            drawIcon(in: CGRect(x: 6, y: 6, width: bounds.width - 12, height: 34))
            let t = title + (hasMenu ? " ▾" : "")
            let lines = t.components(separatedBy: "\n")
            for (i, l) in lines.enumerated() {
                (l as NSString).draw(in: CGRect(x: 0, y: 43 + CGFloat(i) * 13, width: bounds.width, height: 14),
                                     withAttributes: [.font: font, .foregroundColor: textCol, .paragraphStyle: para])
            }
        case .small:
            drawIcon(in: CGRect(x: 4, y: (bounds.height - 16) / 2, width: 16, height: 16))
            let t = title + (hasMenu ? " ▾" : "")
            (t as NSString).draw(in: CGRect(x: 24, y: (bounds.height - 14) / 2, width: bounds.width - 26, height: 14),
                                 withAttributes: [.font: font, .foregroundColor: textCol])
        case .icon:
            drawIcon(in: bounds.insetBy(dx: 4, dy: 4))
        }
    }
}

// MARK: - Palette & color slots

final class PaletteView: NSView {
    var colors: [RGBA?]
    var onPick: ((RGBA, Bool) -> Void)?
    private var hover: Int?
    override var isFlipped: Bool { true }
    let cell: CGFloat = 17, gap: CGFloat = 2

    override init(frame frameRect: NSRect) {
        let base: [RGBA] = [
            RGBA(0, 0, 0), RGBA(127, 127, 127), RGBA(136, 0, 21), RGBA(237, 28, 36), RGBA(255, 127, 39),
            RGBA(255, 242, 0), RGBA(34, 177, 76), RGBA(0, 162, 232), RGBA(63, 72, 204), RGBA(163, 73, 164),
            RGBA(255, 255, 255), RGBA(195, 195, 195), RGBA(185, 122, 87), RGBA(255, 174, 201), RGBA(255, 201, 14),
            RGBA(239, 228, 176), RGBA(181, 230, 29), RGBA(153, 217, 234), RGBA(112, 146, 190), RGBA(200, 191, 231)
        ]
        colors = base.map { Optional($0) } + Array(repeating: nil, count: 10)
        super.init(frame: frameRect)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }
    required init?(coder: NSCoder) { fatalError() }

    func setCustom(_ i: Int, _ c: RGBA) { colors[20 + i] = c; needsDisplay = true }

    func index(at p: CGPoint) -> Int? {
        let col = Int(p.x / (cell + gap)), row = Int(p.y / (cell + gap))
        guard col >= 0, col < 10, row >= 0, row < 3 else { return nil }
        return row * 10 + col
    }

    override func mouseMoved(with event: NSEvent) { hover = index(at: convert(event.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseExited(with event: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with event: NSEvent) { pick(event, secondary: event.modifierFlags.contains(.control)) }
    override func rightMouseDown(with event: NSEvent) { pick(event, secondary: true) }
    func pick(_ e: NSEvent, secondary: Bool) {
        if let i = index(at: convert(e.locationInWindow, from: nil)), let c = colors[i] { onPick?(c, secondary) }
    }

    override func draw(_ dirtyRect: NSRect) {
        for i in 0..<30 {
            let col = i % 10, row = i / 10
            let r = CGRect(x: CGFloat(col) * (cell + gap), y: CGFloat(row) * (cell + gap), width: cell, height: cell)
            if let c = colors[i] {
                c.ns.setFill(); r.fill()
            } else {
                NSColor(white: 0.97, alpha: 1).setFill(); r.fill()
            }
            (hover == i ? NSColor(srgbRed: 0.3, green: 0.55, blue: 0.85, alpha: 1) : NSColor(white: 0.6, alpha: 1)).setStroke()
            NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5)).stroke()
        }
    }
}

final class ColorSlotButton: NSView {
    let slot: Int
    override var isFlipped: Bool { true }
    init(slot: Int, frame: NSRect) {
        self.slot = slot
        super.init(frame: frame)
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .paintSettings, object: nil)
    }
    required init?(coder: NSCoder) { fatalError() }
    @objc func refresh() { needsDisplay = true }
    override func mouseDown(with event: NSEvent) { Settings.shared.activeSlot = slot }

    override func draw(_ dirtyRect: NSRect) {
        let s = Settings.shared
        let active = s.activeSlot == slot
        if active {
            let r = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
            NSColor(srgbRed: 0.80, green: 0.89, blue: 0.97, alpha: 1).setFill(); r.fill()
            NSColor(srgbRed: 0.45, green: 0.65, blue: 0.85, alpha: 1).setStroke(); r.stroke()
        }
        let sw = CGRect(x: bounds.midX - 14, y: 8, width: 28, height: 28)
        (slot == 1 ? s.color1 : s.color2).ns.setFill()
        sw.fill()
        NSColor(white: 0.35, alpha: 1).setStroke()
        NSBezierPath(rect: sw.insetBy(dx: 0.5, dy: 0.5)).stroke()
        let para = NSMutableParagraphStyle(); para.alignment = .center
        ("Color \(slot)" as NSString).draw(in: CGRect(x: 0, y: 43, width: bounds.width, height: 16),
            withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor(white: 0.12, alpha: 1), .paragraphStyle: para])
    }
}

// MARK: - Ribbon

final class FlippedView: NSView { override var isFlipped: Bool { true } }

final class Ribbon: NSView {
    unowned let canvas: CanvasView
    weak var app: AppDelegate?
    let settings = Settings.shared

    let homePanel = FlippedView()
    let viewPanel = FlippedView()
    var activeTab = 1       // 1 = Home, 2 = View
    let tabRects: [CGRect] = [CGRect(x: 0, y: 0, width: 58, height: 27), CGRect(x: 62, y: 0, width: 54, height: 27), CGRect(x: 118, y: 0, width: 54, height: 27)]

    var toolButtons: [(RibbonButton, () -> Bool)] = []
    var shapeButtons: [ShapeKind: RibbonButton] = [:]
    var selectButton: RibbonButton!
    var brushButton: RibbonButton!
    var outlineButton: RibbonButton!
    var fillButton: RibbonButton!
    var toggles: [(RibbonButton, () -> Bool, String, String)] = []
    let palette = PaletteView(frame: NSRect(x: 0, y: 0, width: 190, height: 57))
    var panelSlot: Int?
    var nextCustom = 0

    override var isFlipped: Bool { true }

    init(canvas: CanvasView, app: AppDelegate) {
        self.canvas = canvas
        self.app = app
        super.init(frame: NSRect(x: 0, y: 0, width: 1200, height: 124))
        homePanel.frame = NSRect(x: 0, y: 27, width: 1200, height: 97)
        viewPanel.frame = homePanel.frame
        homePanel.autoresizingMask = [.width]
        viewPanel.autoresizingMask = [.width]
        addSubview(homePanel)
        addSubview(viewPanel)
        buildHome()
        buildView()
        viewPanel.isHidden = true
        NotificationCenter.default.addObserver(self, selector: #selector(refresh), name: .paintSettings, object: nil)
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: building helpers

    func add(_ v: NSView, to panel: NSView) { panel.addSubview(v) }

    func large(_ title: String, _ sym: String, x: CGFloat, w: CGFloat = 58, in panel: NSView, tip: String? = nil, _ action: (() -> Void)?) -> RibbonButton {
        let b = RibbonButton(style: .large, title: title, icon: symbol(sym, 24, weight: .light), frame: NSRect(x: x, y: 3, width: w, height: 74))
        b.onClick = action
        b.toolTip = tip ?? title.replacingOccurrences(of: "\n", with: " ")
        panel.addSubview(b)
        return b
    }

    func small(_ title: String, _ sym: String, x: CGFloat, y: CGFloat, w: CGFloat, in panel: NSView, _ action: (() -> Void)?) -> RibbonButton {
        let b = RibbonButton(style: .small, title: title, icon: symbol(sym, 13), frame: NSRect(x: x, y: y, width: w, height: 24))
        b.onClick = action
        panel.addSubview(b)
        return b
    }

    func iconBtn(_ sym: String, x: CGFloat, y: CGFloat, tip: String, in panel: NSView, _ action: @escaping () -> Void) -> RibbonButton {
        let b = RibbonButton(style: .icon, icon: symbol(sym, 17), frame: NSRect(x: x, y: y, width: 29, height: 29))
        b.onClick = action
        b.toolTip = tip
        panel.addSubview(b)
        return b
    }

    func groupLabel(_ t: String, x: CGFloat, w: CGFloat, in panel: NSView) {
        let l = NSTextField(labelWithString: t)
        l.font = NSFont.systemFont(ofSize: 11)
        l.textColor = NSColor(white: 0.45, alpha: 1)
        l.alignment = .center
        l.frame = NSRect(x: x, y: 79, width: w, height: 15)
        panel.addSubview(l)
    }

    func separator(x: CGFloat, in panel: NSView) {
        let s = NSView(frame: NSRect(x: x, y: 4, width: 1, height: 88))
        s.wantsLayer = true
        s.layer?.backgroundColor = ribbonLine.cgColor
        panel.addSubview(s)
    }

    // MARK: Home tab

    func buildHome() {
        let p = homePanel

        // Clipboard
        let paste = large("Paste", "doc.on.clipboard", x: 6, in: p) { [unowned self] in self.canvas.paste() }
        paste.menuBuilder = nil
        _ = small("Cut", "scissors", x: 66, y: 5, w: 64, in: p) { [unowned self] in self.canvas.cut() }
        _ = small("Copy", "doc.on.doc", x: 66, y: 31, w: 64, in: p) { [unowned self] in self.canvas.copySel() }
        groupLabel("Clipboard", x: 6, w: 124, in: p)
        separator(x: 133, in: p)

        // Image
        selectButton = large("Select", "rectangle.dashed", x: 136, in: p) { [unowned self] in
            if self.settings.tool != .select && self.settings.tool != .freeSelect { self.settings.tool = .select }
        }
        selectButton.split = true
        selectButton.menuBuilder = { [unowned self] in
            let m = NSMenu()
            m.add("Rectangular selection", checked: self.settings.tool == .select, image: symbol("rectangle.dashed", 13)) { self.settings.tool = .select }
            m.add("Free-form selection", checked: self.settings.tool == .freeSelect, image: symbol("lasso", 13)) { self.settings.tool = .freeSelect }
            m.addItem(.separator())
            m.add("Select all") { self.canvas.selectAll() }
            m.add("Delete selection") { self.canvas.deleteSelection() }
            m.addItem(.separator())
            m.add("Transparent selection", checked: self.settings.transparentSelection) { self.settings.transparentSelection.toggle() }
            return m
        }
        _ = small("Crop", "crop", x: 196, y: 5, w: 76, in: p) { [unowned self] in self.canvas.cropToSelection() }
        _ = small("Resize", "arrow.up.left.and.arrow.down.right", x: 196, y: 31, w: 76, in: p) { [unowned self] in self.app?.resizeDialog() }
        let rot = small("Rotate", "rotate.right", x: 196, y: 57, w: 76, in: p, nil)
        rot.menuBuilder = { [unowned self] in
            let m = NSMenu()
            m.add("Rotate right 90°", image: symbol("rotate.right", 13)) { self.canvas.rotateRight() }
            m.add("Rotate left 90°", image: symbol("rotate.left", 13)) { self.canvas.rotateLeft() }
            m.add("Rotate 180°") { self.canvas.rotate180() }
            m.addItem(.separator())
            m.add("Flip vertical", image: symbol("arrow.up.and.down", 13)) { self.canvas.flipV() }
            m.add("Flip horizontal", image: symbol("arrow.left.and.right", 13)) { self.canvas.flipH() }
            return m
        }
        groupLabel("Image", x: 136, w: 136, in: p)
        separator(x: 275, in: p)

        // Tools (2 rows x 3)
        func tool(_ sym: String, _ tip: String, _ t: Tool, col: Int, row: Int) {
            let b = iconBtn(sym, x: 278 + CGFloat(col) * 30, y: 8 + CGFloat(row) * 31, tip: tip, in: p) { [unowned self] in self.settings.tool = t }
            toolButtons.append((b, { [unowned self] in self.settings.tool == t }))
        }
        tool("pencil", "Pencil", .pencil, col: 0, row: 0)
        tool("drop.fill", "Fill with color", .fill, col: 1, row: 0)
        tool("textformat", "Text", .text, col: 2, row: 0)
        tool("eraser", "Eraser", .eraser, col: 0, row: 1)
        tool("eyedropper", "Color picker", .picker, col: 1, row: 1)
        tool("magnifyingglass", "Magnifier (click = zoom in, right-click = zoom out)", .magnifier, col: 2, row: 1)
        groupLabel("Tools", x: 278, w: 90, in: p)
        separator(x: 371, in: p)

        // Brushes
        brushButton = large("Brushes", "paintbrush.pointed.fill", x: 374, in: p) { [unowned self] in self.settings.tool = .brush }
        brushButton.split = true
        brushButton.menuBuilder = { [unowned self] in
            let m = NSMenu()
            for k in BrushKind.allCases {
                m.add(k.name, checked: self.settings.brush == k && self.settings.tool == .brush) { self.settings.brush = k; self.settings.tool = .brush }
            }
            return m
        }
        groupLabel("Brushes", x: 374, w: 58, in: p)
        separator(x: 435, in: p)

        // Shapes gallery
        for (i, k) in ShapeKind.allCases.enumerated() {
            let col = i % 6, row = i / 6
            let b = RibbonButton(style: .icon, icon: shapeIcon(k), frame: NSRect(x: 438 + CGFloat(col) * 23, y: 5 + CGFloat(row) * 23, width: 23, height: 23))
            b.onClick = { [unowned self] in self.settings.shape = k; self.settings.tool = .shape }
            b.toolTip = ["Line", "Curve", "Oval", "Rectangle", "Rounded rectangle", "Polygon (click points, double-click to close)", "Triangle", "Right triangle", "Diamond", "Pentagon", "Hexagon", "Right arrow", "Left arrow", "Up arrow", "Down arrow", "4-point star", "5-point star", "6-point star"][i]
            p.addSubview(b)
            shapeButtons[k] = b
        }
        outlineButton = small("Outline", "square", x: 580, y: 8, w: 82, in: p, nil)
        outlineButton.menuBuilder = { [unowned self] in
            let m = NSMenu()
            m.add("No outline", checked: !self.settings.outline) { self.settings.outline = false }
            m.add("Solid color", checked: self.settings.outline) { self.settings.outline = true }
            return m
        }
        fillButton = small("Fill", "square.fill", x: 580, y: 36, w: 82, in: p, nil)
        fillButton.menuBuilder = { [unowned self] in
            let m = NSMenu()
            m.add("No fill", checked: !self.settings.fill) { self.settings.fill = false }
            m.add("Solid color", checked: self.settings.fill) { self.settings.fill = true }
            return m
        }
        groupLabel("Shapes", x: 438, w: 224, in: p)
        separator(x: 665, in: p)

        // Size
        let sizeIcon = NSImage(size: NSSize(width: 34, height: 28), flipped: true) { _ in
            NSColor(srgbRed: 0.12, green: 0.2, blue: 0.4, alpha: 1).setFill()
            for (i, h) in [1, 2, 3, 5].enumerated() { CGRect(x: 1, y: 2 + CGFloat(i) * 7, width: 32, height: CGFloat(h)).fill() }
            return true
        }
        let sizeBtn = RibbonButton(style: .large, title: "Size", icon: sizeIcon, frame: NSRect(x: 668, y: 3, width: 50, height: 74))
        sizeBtn.toolTip = "Line / brush / eraser size"
        sizeBtn.menuBuilder = { [unowned self] in
            let m = NSMenu()
            for s in [1, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 24, 32, 48] {
                let img = NSImage(size: NSSize(width: 64, height: 18), flipped: true) { _ in
                    NSColor.black.setFill()
                    CGRect(x: 2, y: 9 - CGFloat(min(s, 16)) / 2, width: 58, height: CGFloat(min(s, 16))).fill()
                    return true
                }
                m.add("\(s) px", checked: self.settings.size == s, image: img) { self.settings.size = s }
            }
            return m
        }
        p.addSubview(sizeBtn)
        groupLabel("Size", x: 668, w: 50, in: p)
        separator(x: 721, in: p)

        // Colors
        let c1 = ColorSlotButton(slot: 1, frame: NSRect(x: 724, y: 3, width: 52, height: 74))
        let c2 = ColorSlotButton(slot: 2, frame: NSRect(x: 778, y: 3, width: 52, height: 74))
        p.addSubview(c1); p.addSubview(c2)
        palette.frame = NSRect(x: 836, y: 10, width: 190, height: 57)
        palette.onPick = { [unowned self] c, secondary in
            if secondary { self.settings.color2 = c }
            else if self.settings.activeSlot == 1 { self.settings.color1 = c } else { self.settings.color2 = c }
        }
        p.addSubview(palette)
        _ = large("Edit\ncolors", "paintpalette", x: 1030, w: 62, in: p, tip: "Edit colors") { [unowned self] in self.editColors() }
        groupLabel("Colors", x: 724, w: 368, in: p)
    }

    func editColors() {
        let cp = NSColorPanel.shared
        cp.setTarget(self)
        cp.setAction(#selector(panelColorChanged(_:)))
        cp.isContinuous = true
        cp.color = (settings.activeSlot == 1 ? settings.color1 : settings.color2).ns
        panelSlot = nil
        cp.orderFront(nil)
    }

    @objc func panelColorChanged(_ sender: NSColorPanel) {
        let col = RGBA(sender.color)
        if settings.activeSlot == 1 { settings.color1 = col } else { settings.color2 = col }
        if panelSlot == nil { panelSlot = nextCustom; nextCustom = (nextCustom + 1) % 10 }
        palette.setCustom(panelSlot!, col)
    }

    // MARK: View tab

    func buildView() {
        let p = viewPanel
        _ = large("Zoom in", "plus.magnifyingglass", x: 6, in: p, tip: "Zoom in  (⌘ + scroll wheel, or pinch)") { [unowned self] in self.canvas.zoomStep(1) }
        _ = large("Zoom out", "minus.magnifyingglass", x: 66, in: p, tip: "Zoom out  (⌘ + scroll wheel, or pinch)") { [unowned self] in self.canvas.zoomStep(-1) }
        _ = large("100%", "1.magnifyingglass", x: 126, in: p) { [unowned self] in self.canvas.setZoom(1) }
        _ = large("Fit", "arrow.up.left.and.down.right.magnifyingglass", x: 186, in: p, tip: "Fit image in window") { [unowned self] in self.canvas.zoomToFit() }
        groupLabel("Zoom", x: 6, w: 238, in: p)
        separator(x: 247, in: p)

        func toggle(_ title: String, y: CGFloat, x: CGFloat, w: CGFloat, get: @escaping () -> Bool, set: @escaping () -> Void) {
            let b = small(title, "square", x: x, y: y, w: w, in: p) { set() }
            toggles.append((b, get, "checkmark.square.fill", "square"))
        }
        toggle("Gridlines", y: 5, x: 252, w: 120, get: { [unowned self] in self.settings.showGrid }) { [unowned self] in self.settings.showGrid.toggle() }
        toggle("Status bar", y: 31, x: 252, w: 120, get: { [unowned self] in self.settings.showStatusBar }) { [unowned self] in self.settings.showStatusBar.toggle() }
        groupLabel("Show or hide", x: 252, w: 120, in: p)
        separator(x: 377, in: p)

        toggle("Smooth edges", y: 5, x: 382, w: 150, get: { [unowned self] in self.settings.antialias }) { [unowned self] in self.settings.antialias.toggle() }
        toggle("Wheel zooms", y: 31, x: 382, w: 150, get: { [unowned self] in self.settings.wheelZooms }) { [unowned self] in self.settings.wheelZooms.toggle() }
        groupLabel("Behavior", x: 382, w: 150, in: p)
    }

    // MARK: refresh

    @objc func refresh() {
        for (b, f) in toolButtons { b.isOn = f() }
        selectButton.isOn = settings.tool == .select || settings.tool == .freeSelect
        selectButton.icon = symbol(settings.tool == .freeSelect ? "lasso" : "rectangle.dashed", 24, weight: .light)
        brushButton.isOn = settings.tool == .brush
        for (k, b) in shapeButtons { b.isOn = settings.tool == .shape && settings.shape == k }
        outlineButton.title = settings.outline ? "Outline" : "No outline"
        fillButton.title = settings.fill ? "Fill" : "No fill"
        for (b, get, on, off) in toggles {
            b.icon = symbol(get() ? on : off, 13)
        }
    }

    // MARK: tabs

    override func draw(_ dirtyRect: NSRect) {
        ribbonBG.setFill()
        bounds.fill()
        ribbonLine.setStroke()
        let line = NSBezierPath()
        line.move(to: NSPoint(x: 0, y: 26.5)); line.line(to: NSPoint(x: bounds.width, y: 26.5))
        line.move(to: NSPoint(x: 0, y: 123.5)); line.line(to: NSPoint(x: bounds.width, y: 123.5))
        line.lineWidth = 1
        line.stroke()
        let names = ["File", "Home", "View"]
        let para = NSMutableParagraphStyle(); para.alignment = .center
        for (i, r) in tabRects.enumerated() {
            if i == 0 {
                accentBlue.setFill(); r.fill()
                (names[i] as NSString).draw(in: CGRect(x: r.minX, y: 5, width: r.width, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor.white, .paragraphStyle: para])
            } else {
                let active = activeTab == i
                if active {
                    NSColor(srgbRed: 0.98, green: 0.98, blue: 0.985, alpha: 1).setFill()
                    CGRect(x: r.minX, y: 0, width: r.width, height: 28).fill()
                    ribbonLine.setStroke()
                    let b = NSBezierPath()
                    b.move(to: NSPoint(x: r.minX + 0.5, y: 27)); b.line(to: NSPoint(x: r.minX + 0.5, y: 3)); b.line(to: NSPoint(x: r.maxX - 0.5, y: 3)); b.line(to: NSPoint(x: r.maxX - 0.5, y: 27))
                    b.stroke()
                }
                (names[i] as NSString).draw(in: CGRect(x: r.minX, y: 5, width: r.width, height: 16), withAttributes: [.font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: accentBlue, .paragraphStyle: para])
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        for (i, r) in tabRects.enumerated() where r.contains(p) {
            if i == 0 { showFileMenu(); return }
            activeTab = i
            homePanel.isHidden = i != 1
            viewPanel.isHidden = i != 2
            needsDisplay = true
        }
    }

    func showFileMenu() {
        guard let app = app else { return }
        let m = NSMenu()
        m.add("New") { app.newDocument(nil) }
        m.add("Open…") { app.openDocument(nil) }
        m.add("Save") { app.saveDocument(nil) }
        m.add("Save as…") { app.saveDocumentAs(nil) }
        m.addItem(.separator())
        m.add("Quit") { NSApp.terminate(nil) }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: 27), in: self)
    }
}

// MARK: - Text options bar

final class TextBar: NSView {
    let settings = Settings.shared
    let fontPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let sizePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    let boldB = NSButton(title: "B", target: nil, action: nil)
    let italicB = NSButton(title: "I", target: nil, action: nil)
    let underB = NSButton(title: "U", target: nil, action: nil)
    let transparentB = NSButton(checkboxWithTitle: "Transparent background", target: nil, action: nil)
    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        let fams = NSFontManager.shared.availableFontFamilies
        fontPopup.addItems(withTitles: fams)
        if fams.contains(settings.fontName) { fontPopup.selectItem(withTitle: settings.fontName) }
        fontPopup.frame = NSRect(x: 10, y: 5, width: 200, height: 24)
        fontPopup.target = self; fontPopup.action = #selector(fontChanged)
        let sizes = [8, 9, 10, 11, 12, 14, 16, 18, 20, 22, 24, 26, 28, 36, 48, 72, 96]
        sizePopup.addItems(withTitles: sizes.map { String($0) })
        sizePopup.selectItem(withTitle: String(settings.fontSize))
        sizePopup.frame = NSRect(x: 218, y: 5, width: 70, height: 24)
        sizePopup.target = self; sizePopup.action = #selector(sizeChanged)
        for (i, b) in [boldB, italicB, underB].enumerated() {
            b.setButtonType(.pushOnPushOff)
            b.bezelStyle = .texturedRounded
            b.frame = NSRect(x: 298 + CGFloat(i) * 34, y: 5, width: 32, height: 24)
            b.target = self; b.action = #selector(styleChanged)
        }
        boldB.font = NSFont.boldSystemFont(ofSize: 13)
        italicB.font = NSFontManager.shared.convert(NSFont.systemFont(ofSize: 13), toHaveTrait: .italicFontMask)
        underB.attributedTitle = NSAttributedString(string: "U", attributes: [.underlineStyle: NSUnderlineStyle.single.rawValue, .font: NSFont.systemFont(ofSize: 13)])
        transparentB.frame = NSRect(x: 410, y: 6, width: 220, height: 22)
        transparentB.state = settings.textTransparent ? .on : .off
        transparentB.target = self; transparentB.action = #selector(styleChanged)
        for v in [fontPopup, sizePopup, boldB, italicB, underB, transparentB] as [NSView] { addSubview(v) }
    }
    required init?(coder: NSCoder) { fatalError() }

    @objc func fontChanged() { settings.fontName = fontPopup.titleOfSelectedItem ?? "Helvetica" }
    @objc func sizeChanged() { settings.fontSize = Int(sizePopup.titleOfSelectedItem ?? "14") ?? 14 }
    @objc func styleChanged() {
        settings.bold = boldB.state == .on
        settings.italic = italicB.state == .on
        settings.underline = underB.state == .on
        settings.textTransparent = transparentB.state == .on
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.93, green: 0.94, blue: 0.95, alpha: 1).setFill()
        bounds.fill()
        ribbonLine.setStroke()
        let l = NSBezierPath(); l.move(to: NSPoint(x: 0, y: 33.5)); l.line(to: NSPoint(x: bounds.width, y: 33.5)); l.stroke()
    }
}

// MARK: - Status bar

final class StatusBar: NSView {
    unowned let canvas: CanvasView
    let posLabel = NSTextField(labelWithString: "")
    let selLabel = NSTextField(labelWithString: "")
    let sizeLabel = NSTextField(labelWithString: "")
    let zoomLabel = NSTextField(labelWithString: "100%")
    let slider = NSSlider(value: 4, minValue: 0, maxValue: Double(CanvasView.levels.count - 1), target: nil, action: nil)
    override var isFlipped: Bool { true }

    init(canvas: CanvasView) {
        self.canvas = canvas
        super.init(frame: NSRect(x: 0, y: 0, width: 1000, height: 26))
        func style(_ l: NSTextField, x: CGFloat, w: CGFloat) {
            l.font = NSFont.systemFont(ofSize: 11.5)
            l.textColor = NSColor(white: 0.15, alpha: 1)
            l.frame = NSRect(x: x, y: 5, width: w, height: 16)
            addSubview(l)
        }
        func icon(_ n: String, x: CGFloat) {
            let iv = NSImageView(frame: NSRect(x: x, y: 5, width: 16, height: 16))
            iv.image = symbol(n, 12).map { tinted($0, NSColor(white: 0.3, alpha: 1)) }
            addSubview(iv)
        }
        icon("scope", x: 10); style(posLabel, x: 30, w: 110)
        icon("rectangle.dashed", x: 150); style(selLabel, x: 170, w: 110)
        icon("photo", x: 290); style(sizeLabel, x: 310, w: 130)

        let minus = NSButton(title: "−", target: self, action: #selector(zoomOut))
        let plus = NSButton(title: "+", target: self, action: #selector(zoomIn))
        for b in [minus, plus] { b.bezelStyle = .smallSquare; b.isBordered = true; b.font = NSFont.systemFont(ofSize: 12, weight: .semibold) }
        zoomLabel.alignment = .right
        zoomLabel.font = NSFont.systemFont(ofSize: 11.5)
        slider.target = self; slider.action = #selector(sliderMoved)
        slider.controlSize = .small
        slider.numberOfTickMarks = 0
        for v in [zoomLabel, minus, slider, plus] as [NSView] { addSubview(v); v.autoresizingMask = [.minXMargin] }
        zoomLabel.frame = NSRect(x: 0, y: 5, width: 56, height: 16)
        minus.frame = NSRect(x: 0, y: 2, width: 22, height: 22)
        slider.frame = NSRect(x: 0, y: 3, width: 130, height: 20)
        plus.frame = NSRect(x: 0, y: 2, width: 22, height: 22)
        layoutRight()
        update()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        layoutRight()
    }

    func layoutRight() {
        let w = bounds.width
        plus.frame.origin.x = w - 32
        slider.frame.origin.x = w - 32 - 138
        minus.frame.origin.x = w - 32 - 138 - 26
        zoomLabel.frame.origin.x = w - 32 - 138 - 26 - 62
    }
    var plus: NSView { subviews.first { ($0 as? NSButton)?.title == "+" }! }
    var minus: NSView { subviews.first { ($0 as? NSButton)?.title == "−" }! }

    @objc func zoomIn() { canvas.zoomStep(1) }
    @objc func zoomOut() { canvas.zoomStep(-1) }
    @objc func sliderMoved() {
        let i = Int(slider.doubleValue.rounded())
        canvas.setZoom(CanvasView.levels[max(0, min(CanvasView.levels.count - 1, i))])
    }

    func update() {
        if let h = canvas.hoverPx, canvas.inBounds(h) { posLabel.stringValue = "\(Int(h.x)), \(Int(h.y)) px" } else { posLabel.stringValue = "" }
        if let r = canvas.resizeNewSize { sizeLabel.stringValue = "\(r.0) × \(r.1)px" }
        else { sizeLabel.stringValue = "\(canvas.bitmap.width) × \(canvas.bitmap.height)px" }
        if let s = canvas.sel { selLabel.stringValue = "\(Int(s.rect.width)) × \(Int(s.rect.height)) px" }
        else if let r = canvas.selDragRect { selLabel.stringValue = "\(Int(r.width)) × \(Int(r.height)) px" }
        else { selLabel.stringValue = "" }
        let z = canvas.zoom
        zoomLabel.stringValue = z >= 1 ? "\(Int((z * 100).rounded()))%" : String(format: "%.1f%%", z * 100)
        slider.doubleValue = Double(canvas.nearestLevel(z))
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(srgbRed: 0.945, green: 0.949, blue: 0.953, alpha: 1).setFill()
        bounds.fill()
        ribbonLine.setStroke()
        let l = NSBezierPath(); l.move(to: NSPoint(x: 0, y: 0.5)); l.line(to: NSPoint(x: bounds.width, y: 0.5)); l.stroke()
    }
}
