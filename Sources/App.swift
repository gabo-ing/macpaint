import AppKit
import UniformTypeIdentifiers

/// Helper object for the Resize / New dialogs.
final class SizeAccessory: NSObject {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 290, height: 108))
    let modePopup = NSPopUpButton(frame: NSRect(x: 0, y: 80, width: 150, height: 24), pullsDown: false)
    let wField = NSTextField(frame: NSRect(x: 100, y: 48, width: 80, height: 22))
    let hField = NSTextField(frame: NSRect(x: 100, y: 20, width: 80, height: 22))
    let keep = NSButton(checkboxWithTitle: "Maintain aspect ratio", target: nil, action: nil)
    let baseW: Double, baseH: Double
    let allowPercent: Bool

    init(width: Int, height: Int, allowPercent: Bool) {
        baseW = Double(width); baseH = Double(height)
        self.allowPercent = allowPercent
        super.init()
        if allowPercent { modePopup.addItems(withTitles: ["Percentage", "Pixels"]) } else { modePopup.addItems(withTitles: ["Pixels"]) }
        modePopup.target = self; modePopup.action = #selector(modeChanged)
        let wl = NSTextField(labelWithString: "Horizontal:"); wl.frame = NSRect(x: 0, y: 51, width: 95, height: 17)
        let hl = NSTextField(labelWithString: "Vertical:"); hl.frame = NSRect(x: 0, y: 23, width: 95, height: 17)
        keep.frame = NSRect(x: 0, y: -2, width: 220, height: 20)
        keep.state = allowPercent ? .on : .off
        keep.isHidden = !allowPercent
        for f in [wField, hField] { f.alignment = .right }
        wField.target = self; wField.action = #selector(wChanged)
        hField.target = self; hField.action = #selector(hChanged)
        for v in [modePopup, wl, hl, wField, hField, keep] as [NSView] { view.addSubview(v) }
        if allowPercent { wField.stringValue = "100"; hField.stringValue = "100" }
        else { wField.stringValue = "\(width)"; hField.stringValue = "\(height)" }
    }

    var isPercent: Bool { allowPercent && modePopup.indexOfSelectedItem == 0 }

    @objc func modeChanged() {
        if isPercent { wField.stringValue = "100"; hField.stringValue = "100" }
        else { wField.stringValue = "\(Int(baseW))"; hField.stringValue = "\(Int(baseH))" }
    }
    @objc func wChanged() {
        guard keep.state == .on, let w = Double(wField.stringValue) else { return }
        hField.stringValue = isPercent ? wField.stringValue : "\(max(1, Int((w * baseH / baseW).rounded())))"
    }
    @objc func hChanged() {
        guard keep.state == .on, let h = Double(hField.stringValue) else { return }
        wField.stringValue = isPercent ? hField.stringValue : "\(max(1, Int((h * baseW / baseH).rounded())))"
    }

    func result() -> (Int, Int)? {
        guard let a = Double(wField.stringValue), let b = Double(hField.stringValue), a > 0, b > 0 else { return nil }
        if isPercent { return (max(1, Int((baseW * a / 100).rounded())), max(1, Int((baseH * b / 100).rounded()))) }
        return (Int(a.rounded()), Int(b.rounded()))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var canvas: CanvasView!
    var scroll: PaintScrollView!
    var ribbon: Ribbon!
    var textBar: TextBar!
    var status: StatusBar!
    let settings = Settings.shared

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        canvas = CanvasView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        scroll = PaintScrollView(frame: NSRect(x: 0, y: 0, width: 1200, height: 700))
        scroll.documentView = canvas
        scroll.canvas = canvas
        canvas.scrollView = scroll
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.scrollerStyle = .legacy
        scroll.autohidesScrollers = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = NSColor(srgbRed: 0.79, green: 0.83, blue: 0.90, alpha: 1)
        scroll.allowsMagnification = false

        ribbon = Ribbon(canvas: canvas, app: self)
        textBar = TextBar(frame: NSRect(x: 0, y: 0, width: 1000, height: 34))
        textBar.isHidden = true
        status = StatusBar(canvas: canvas)

        let stack = NSStackView(views: [ribbon, textBar, scroll, status])
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.distribution = .fill
        for v in [ribbon, textBar, scroll, status] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        ribbon.heightAnchor.constraint(equalToConstant: 124).isActive = true
        textBar.heightAnchor.constraint(equalToConstant: 34).isActive = true
        status.heightAnchor.constraint(equalToConstant: 26).isActive = true
        scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 840),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.contentView = NSView()
        window.contentView!.addSubview(stack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let cv = window.contentView!
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            stack.topAnchor.constraint(equalTo: cv.topAnchor),
            stack.bottomAnchor.constraint(equalTo: cv.bottomAnchor)
        ])
        window.minSize = NSSize(width: 1110, height: 520)
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("PaintMainWindow")
        window.acceptsMouseMovedEvents = true

        canvas.onStatus = { [weak self] in self?.status.update() }
        canvas.onDocChange = { [weak self] in self?.updateTitle() }
        NotificationCenter.default.addObserver(self, selector: #selector(settingsChanged), name: .paintSettings, object: nil)

        buildMenu()
        updateTitle()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(canvas)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.async { [weak self] in
            self?.canvas.fitFrame()
            self?.status.update()
        }
        if let path = ProcessInfo.processInfo.environment["PAINT_SNAPSHOT"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { self.debugSnapshot(path) }
        }
    }

    /// Developer hook: PAINT_SNAPSHOT=/path/prefix draws a demo via the real tool code and writes window PNGs.
    func debugSnapshot(_ prefix: String) {
        let c = canvas!
        func snap(_ name: String) {
            window.displayIfNeeded()
            let v = window.contentView!
            if let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) {
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(prefix)_\(name).png"))
            }
        }
        func drag(_ pts: [CGPoint], tool: Tool) {
            settings.tool = tool
            c.strokeBegin(pts[0], tool: tool)
            for p in pts.dropFirst() { c.strokeMove(p) }
            c.strokeEnd()
        }
        settings.color1 = RGBA(237, 28, 36)
        drag([CGPoint(x: 100, y: 100), CGPoint(x: 160, y: 140), CGPoint(x: 220, y: 110), CGPoint(x: 300, y: 180)], tool: .pencil)
        settings.color1 = RGBA(0, 162, 232); settings.size = 8
        settings.brush = .brush
        drag([CGPoint(x: 100, y: 220), CGPoint(x: 200, y: 260), CGPoint(x: 320, y: 230)], tool: .brush)
        settings.color1 = RGBA(34, 177, 76); settings.color2 = RGBA(255, 242, 0); settings.size = 3
        settings.fill = true
        for (k, x) in [(ShapeKind.rectangle, 400.0), (.oval, 520), (.star5, 640), (.arrowRight, 760), (.hexagon, 880)] {
            settings.shape = k; settings.tool = .shape
            c.strokeFG = settings.color1; c.strokeBG = settings.color2
            c.draft = c.newDraft(CGPoint(x: x, y: 100))
            c.draft?.p1 = CGPoint(x: x + 90, y: 190)
            c.commitDraft()
        }
        settings.fill = false
        settings.shape = .curve
        c.strokeFG = RGBA(163, 73, 164)
        var d = c.newDraft(CGPoint(x: 400, y: 300)); d.p1 = CGPoint(x: 700, y: 300); d.controls = [CGPoint(x: 480, y: 220), CGPoint(x: 620, y: 380)]
        c.draft = d; c.commitDraft()
        // text
        settings.tool = .text
        c.beginText(CGRect(x: 100, y: 400, width: 400, height: 40))
        c.textView?.string = "Fig. 2 — Edited label (αβγ)"
        c.commitText()
        // fill + selection move
        settings.tool = .fill
        // selection: rectangle around the pencil line, lift and move
        c.sel = Selection(rect: CGRect(x: 90, y: 90, width: 230, height: 100), image: nil, path: nil)
        c.nudge(300, 330)
        c.commitSelection()
        c.needsDisplay = true
        settings.tool = .pencil
        snap("1_normal")
        c.setZoom(1)
        // zoom to pixels around the pencil stroke
        c.setZoom(16, anchor: c.convert(NSPoint(x: c.pad + 420 * c.zoom, y: c.pad + 420 * c.zoom), to: c))
        c.hoverPx = CGPoint(x: 410, y: 420)
        snap("2_zoom16")
        c.undo(); c.undo()
        snap("3_after_undo")
        c.isModified = false
        NSApp.terminate(nil)
    }

    @objc func settingsChanged() {
        textBar.isHidden = settings.tool != .text
        status.isHidden = !settings.showStatusBar
        status.update()
    }

    func updateTitle() {
        let name = canvas.fileURL?.lastPathComponent ?? "Untitled"
        window.title = "\(name) - Paint"
        window.representedURL = canvas.fileURL
        window.isDocumentEdited = canvas.isModified
    }

    // MARK: menus

    func buildMenu() {
        let main = NSMenu()
        NSApp.mainMenu = main

        func sub(_ title: String) -> NSMenu {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            main.addItem(item)
            let m = NSMenu(title: title)
            item.submenu = m
            return m
        }
        @discardableResult
        func add(_ m: NSMenu, _ title: String, _ sel: Selector?, _ key: String = "", _ mods: NSEvent.ModifierFlags = [.command], target: AnyObject? = nil) -> NSMenuItem {
            let it = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            it.keyEquivalentModifierMask = key.isEmpty ? [] : mods
            it.target = target ?? self
            m.addItem(it)
            return it
        }

        let app = sub("Paint")
        add(app, "About Paint", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), target: NSApp)
        app.addItem(.separator())
        add(app, "Hide Paint", #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(app, "Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        app.addItem(.separator())
        add(app, "Quit Paint", #selector(NSApplication.terminate(_:)), "q", target: NSApp)

        let file = sub("File")
        add(file, "New…", #selector(newDocument(_:)), "n")
        add(file, "Open…", #selector(openDocument(_:)), "o")
        file.addItem(.separator())
        add(file, "Save", #selector(saveDocument(_:)), "s")
        add(file, "Save As…", #selector(saveDocumentAs(_:)), "S", [.command, .shift])
        file.addItem(.separator())
        add(file, "Close", #selector(NSWindow.performClose(_:)), "w", target: nil)

        let edit = sub("Edit")
        add(edit, "Undo", #selector(doUndo), "z")
        add(edit, "Redo", #selector(doRedo), "Z", [.command, .shift])
        edit.addItem(.separator())
        add(edit, "Cut", #selector(doCut), "x")
        add(edit, "Copy", #selector(doCopy), "c")
        add(edit, "Paste", #selector(doPaste), "v")
        add(edit, "Delete", #selector(doDelete))
        edit.addItem(.separator())
        add(edit, "Select All", #selector(doSelectAll), "a")

        let image = sub("Image")
        add(image, "Crop to Selection", #selector(doCrop), "k", [.command, .shift])
        add(image, "Resize…", #selector(resizeDialogAction), "r", [.command, .control])
        image.addItem(.separator())
        add(image, "Rotate Right 90°", #selector(doRotR), "]")
        add(image, "Rotate Left 90°", #selector(doRotL), "[")
        add(image, "Rotate 180°", #selector(doRot180))
        add(image, "Flip Horizontal", #selector(doFlipH))
        add(image, "Flip Vertical", #selector(doFlipV))
        image.addItem(.separator())
        add(image, "Invert Colors", #selector(doInvert), "i", [.command, .shift])
        add(image, "Clear Image", #selector(doClear))

        let view = sub("View")
        add(view, "Zoom In", #selector(doZoomIn), "+")
        add(view, "Zoom Out", #selector(doZoomOut), "-")
        add(view, "Actual Size (100%)", #selector(doZoom100), "0")
        add(view, "Fit in Window", #selector(doZoomFit), "9")
        view.addItem(.separator())
        add(view, "Show Pixel Gridlines", #selector(toggleGrid), "'")
        add(view, "Smooth Edges (Antialiasing)", #selector(toggleAA))
        add(view, "Mouse Wheel Zooms Without ⌘", #selector(toggleWheel))
        add(view, "Show Status Bar", #selector(toggleStatus))

        let win = sub("Window")
        add(win, "Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil)
        add(win, "Zoom", #selector(NSWindow.performZoom(_:)), target: nil)
        NSApp.windowsMenu = win
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(doUndo): return !canvas.undoStack.isEmpty || canvas.textView != nil
        case #selector(doRedo): return !canvas.redoStack.isEmpty || canvas.textView != nil
        case #selector(doCrop), #selector(doDelete): return canvas.sel != nil
        case #selector(toggleGrid): item.state = settings.showGrid ? .on : .off
        case #selector(toggleAA): item.state = settings.antialias ? .on : .off
        case #selector(toggleWheel): item.state = settings.wheelZooms ? .on : .off
        case #selector(toggleStatus): item.state = settings.showStatusBar ? .on : .off
        default: break
        }
        return true
    }

    // MARK: edit / image / view actions

    @objc func doUndo() { canvas.undo() }
    @objc func doRedo() { canvas.redo() }
    @objc func doCut() { if let t = canvas.textView { t.cut(nil) } else { canvas.cut() } }
    @objc func doCopy() { if let t = canvas.textView { t.copy(nil) } else { canvas.copySel() } }
    @objc func doPaste() { if let t = canvas.textView { t.paste(nil) } else { canvas.paste() } }
    @objc func doDelete() { canvas.deleteSelection() }
    @objc func doSelectAll() { if let t = canvas.textView { t.selectAll(nil) } else { canvas.selectAll() } }
    @objc func doCrop() { canvas.cropToSelection() }
    @objc func doRotR() { canvas.rotateRight() }
    @objc func doRotL() { canvas.rotateLeft() }
    @objc func doRot180() { canvas.rotate180() }
    @objc func doFlipH() { canvas.flipH() }
    @objc func doFlipV() { canvas.flipV() }
    @objc func doInvert() { canvas.invertColors() }
    @objc func doClear() { canvas.clearImage() }
    @objc func doZoomIn() { canvas.zoomStep(1) }
    @objc func doZoomOut() { canvas.zoomStep(-1) }
    @objc func doZoom100() { canvas.setZoom(1) }
    @objc func doZoomFit() { canvas.zoomToFit() }
    @objc func toggleGrid() { settings.showGrid.toggle() }
    @objc func toggleAA() { settings.antialias.toggle() }
    @objc func toggleWheel() { settings.wheelZooms.toggle() }
    @objc func toggleStatus() { settings.showStatusBar.toggle() }
    @objc func resizeDialogAction() { resizeDialog() }

    // MARK: dialogs

    func resizeDialog() {
        canvas.commitText()
        let target: (Int, Int)
        let what: String
        if let s = canvas.sel { target = (Int(s.rect.width), Int(s.rect.height)); what = "selection" }
        else { target = (canvas.bitmap.width, canvas.bitmap.height); what = "image" }
        let acc = SizeAccessory(width: target.0, height: target.1, allowPercent: true)
        let alert = NSAlert()
        alert.messageText = "Resize \(what)"
        alert.informativeText = "Current size: \(target.0) × \(target.1) px"
        alert.accessoryView = acc.view
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let (w, h) = acc.result() { canvas.scaleTo(width: w, height: h) }
    }

    @objc func newDocument(_ sender: Any?) {
        guard confirmDiscard() else { return }
        let acc = SizeAccessory(width: 1152, height: 648, allowPercent: false)
        let alert = NSAlert()
        alert.messageText = "New image"
        alert.informativeText = "Canvas size in pixels:"
        alert.accessoryView = acc.view
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn, let (w, h) = acc.result(), w >= 1, h >= 1, w <= 30000, h <= 30000 {
            canvas.newDocument(width: w, height: h)
            updateTitle()
        }
    }

    // MARK: files

    func confirmDiscard() -> Bool {
        canvas.commitText()
        guard canvas.isModified else { return true }
        let alert = NSAlert()
        alert.messageText = "Do you want to save changes to \(canvas.fileURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don't save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Don't Save")
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn: return save(asNew: false)
        case .alertSecondButtonReturn: return true
        default: return false
        }
    }

    @objc func openDocument(_ sender: Any?) {
        guard confirmDiscard() else { return }
        let p = NSOpenPanel()
        p.allowedContentTypes = [.image]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let url = p.url { openFile(url) }
    }

    func openFile(_ url: URL) {
        if canvas.load(url: url) { updateTitle() }
        else {
            let a = NSAlert()
            a.messageText = "Couldn't open \(url.lastPathComponent)"
            a.informativeText = "The file isn't a supported image."
            a.runModal()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let u = urls.first, confirmDiscard() else { return }
        openFile(u)
    }

    @objc func saveDocument(_ sender: Any?) { _ = save(asNew: false) }
    @objc func saveDocumentAs(_ sender: Any?) { _ = save(asNew: true) }

    @discardableResult
    func save(asNew: Bool) -> Bool {
        if !asNew, let url = canvas.fileURL {
            let ok = canvas.save(to: url)
            if ok { updateTitle() } else { failAlert() }
            return ok
        }
        let panel = NSSavePanel()
        let formats: [(String, UTType, String)] = [("PNG", .png, "png"), ("JPEG", .jpeg, "jpg"), ("BMP", .bmp, "bmp"), ("TIFF", .tiff, "tiff"), ("GIF", .gif, "gif")]
        let base = (canvas.fileURL?.deletingPathExtension().lastPathComponent) ?? "Untitled"
        let startExt = canvas.fileURL?.pathExtension.lowercased() ?? "png"
        var startIdx = formats.firstIndex { $0.2 == startExt || ($0.2 == "jpg" && startExt == "jpeg") || ($0.2 == "tiff" && startExt == "tif") } ?? 0
        if startIdx < 0 { startIdx = 0 }
        panel.allowedContentTypes = [formats[startIdx].1]
        panel.nameFieldStringValue = "\(base).\(formats[startIdx].2)"
        let pop = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 140, height: 24), pullsDown: false)
        pop.addItems(withTitles: formats.map { $0.0 })
        pop.selectItem(at: startIdx)
        let box = ActionBox { [weak pop, weak panel] in
            guard let pop = pop, let panel = panel else { return }
            let f = formats[pop.indexOfSelectedItem]
            panel.allowedContentTypes = [f.1]
            let n = (panel.nameFieldStringValue as NSString).deletingPathExtension
            panel.nameFieldStringValue = "\(n).\(f.2)"
        }
        pop.target = box
        pop.action = #selector(ActionBox.fire)
        let acc = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 32))
        let lab = NSTextField(labelWithString: "Save as type:")
        lab.frame = NSRect(x: 0, y: 7, width: 90, height: 17)
        pop.frame.origin = NSPoint(x: 96, y: 4)
        acc.addSubview(lab); acc.addSubview(pop)
        panel.accessoryView = acc
        let result = panel.runModal()
        _ = box
        guard result == .OK, let url = panel.url else { return false }
        let ok = canvas.save(to: url)
        if ok { updateTitle() } else { failAlert() }
        return ok
    }

    func failAlert() {
        let a = NSAlert()
        a.messageText = "Couldn't save the image"
        a.runModal()
    }

    // MARK: lifecycle

    func windowShouldClose(_ sender: NSWindow) -> Bool { confirmDiscard() }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply { confirmDiscard() ? .terminateNow : .terminateCancel }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
