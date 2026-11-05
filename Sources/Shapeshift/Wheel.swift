import AppKit

/// Borderless, non-activating panel that can still take keys in click/keyboard mode.
final class WheelPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class WheelController {
    static let shared = WheelController()

    enum Mode { case drag, click }

    private var panel: WheelPanel?
    private var view: WheelView?
    private(set) var isOpen = false
    private(set) var mode: Mode = .drag
    private var files: [URL] = []
    private var keyMonitor: Any?

    func show(files: [URL], kind: WheelKind, mode: Mode, at point: NSPoint = NSEvent.mouseLocation) {
        self.files = files.map(\.realFileURL)
        self.mode = mode
        let size = WheelView.diameter
        if panel == nil {
            let p = WheelPanel(contentRect: NSRect(x: 0, y: 0, width: size, height: size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = false
            p.level = .popUpMenu
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            p.hidesOnDeactivate = false
            p.isReleasedWhenClosed = false
            let v = WheelView(frame: NSRect(x: 0, y: 0, width: size, height: size))
            v.controller = self
            p.contentView = v
            panel = p
            view = v
        }
        guard let panel, let view else { return }
        view.configure(files: files, kind: kind, clickMode: mode == .click)
        // Keep the wheel fully on the screen that holds the pointer.
        let screen = NSScreen.screens.first { NSMouseInRect(point, $0.frame, false) } ?? NSScreen.main!
        var origin = NSPoint(x: point.x - size / 2, y: point.y - size / 2)
        let vf = screen.visibleFrame
        origin.x = min(max(origin.x, vf.minX), vf.maxX - size)
        origin.y = min(max(origin.y, vf.minY), vf.maxY - size)
        panel.setFrameOrigin(origin)
        panel.alphaValue = 1
        if mode == .click {
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
            installKeyMonitor()
        } else {
            panel.orderFrontRegardless()
        }
        isOpen = true
    }

    func switchKind(_ kind: WheelKind) {
        guard isOpen, let view else { return }
        view.configure(files: files, kind: kind, clickMode: mode == .click)
    }

    var currentKind: WheelKind? { isOpen ? view?.kind : nil }

    func close() {
        panel?.orderOut(nil)
        isOpen = false
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
    }

    /// Mouse released somewhere that wasn't a wedge.
    func dragEnded() {
        guard mode == .drag else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            if self?.mode == .drag { self?.close() }
        }
    }

    func perform(_ op: Operation, files: [URL]) {
        close()
        Runner.run(op, files: files.isEmpty ? self.files : files)
    }

    private func installKeyMonitor() {
        if keyMonitor != nil { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { [weak self] e in
            if let k = Settings.shared.wheel(for: e.modifierFlags) { self?.switchKind(k) }
            return e
        }
    }
}

final class WheelView: NSView {
    static let diameter: CGFloat = 580
    weak var controller: WheelController?

    private(set) var kind: WheelKind = .convert
    private var files: [URL] = []
    private var ops: [Operation] = []
    private var hovered: Int? { didSet { if hovered != oldValue { needsDisplay = true } } }
    private var clickMode = false
    private var tracking: NSTrackingArea?

    // Ring geometry
    private let hole: CGFloat = 62
    private let ring1: (CGFloat, CGFloat) = (68, 160)
    private let ring2: (CGFloat, CGFloat) = (164, 256)
    private let perRing1 = 12

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    func configure(files: [URL], kind: WheelKind, clickMode: Bool) {
        self.files = files
        self.kind = kind
        self.clickMode = clickMode
        ops = Array(Catalog.operations(for: files, kind: kind).prefix(34))
        hovered = clickMode && !ops.isEmpty ? 0 : nil
        needsDisplay = true
    }

    override func updateTrackingAreas() {
        if let t = tracking { removeTrackingArea(t) }
        tracking = NSTrackingArea(rect: bounds, options: [.mouseMoved, .activeAlways, .inVisibleRect, .mouseEnteredAndExited], owner: self)
        addTrackingArea(tracking!)
    }

    // MARK: Geometry

    private var center: NSPoint { NSPoint(x: bounds.midX, y: bounds.midY) }

    private func layout(_ i: Int) -> (inner: CGFloat, outer: CGFloat, start: CGFloat, end: CGFloat) {
        let n1 = min(ops.count, perRing1)
        if i < n1 {
            let step = 360 / CGFloat(n1)
            let s = 90 - CGFloat(i) * step + step / 2
            return (ring1.0, ring1.1, s - step, s)
        }
        let n2 = ops.count - n1
        let j = i - n1
        let step = 360 / CGFloat(n2)
        let s = 90 - CGFloat(j) * step + step / 2
        return (ring2.0, ring2.1, s - step, s)
    }

    private func index(at p: NSPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let r = hypot(dx, dy)
        var angle = atan2(dy, dx) * 180 / .pi
        for i in ops.indices {
            let g = layout(i)
            guard r >= g.inner && r <= g.outer else { continue }
            var a = angle
            while a < g.start { a += 360 }
            while a > g.start + 360 { a -= 360 }
            if a <= g.end { return i }
        }
        angle = 0
        return nil
    }

    private var maxRadius: CGFloat { ops.count > perRing1 ? ring2.1 : ring1.1 }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let c = center
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let base = dark ? NSColor(white: 0.14, alpha: 0.94) : NSColor(white: 0.98, alpha: 0.95)
        let wedgeFill = dark ? NSColor(white: 0.20, alpha: 0.96) : NSColor(white: 1.0, alpha: 0.97)
        let text = dark ? NSColor.white : NSColor(white: 0.1, alpha: 1)

        // Shadow disc
        let disc = NSBezierPath(ovalIn: NSRect(x: c.x - maxRadius - 6, y: c.y - maxRadius - 6, width: (maxRadius + 6) * 2, height: (maxRadius + 6) * 2))
        NSGraphicsContext.saveGraphicsState()
        let sh = NSShadow(); sh.shadowBlurRadius = 18; sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowOffset = NSSize(width: 0, height: -4)
        sh.set()
        base.setFill(); disc.fill()
        NSGraphicsContext.restoreGraphicsState()

        for (i, op) in ops.enumerated() {
            let g = layout(i)
            let path = NSBezierPath()
            path.appendArc(withCenter: c, radius: g.outer, startAngle: g.start + 0.6, endAngle: g.end - 0.6)
            path.appendArc(withCenter: c, radius: g.inner, startAngle: g.end - 0.6, endAngle: g.start + 0.6, clockwise: true)
            path.close()
            (i == hovered ? kind.color : wedgeFill).setFill()
            path.fill()

            let mid = (g.start + g.end) / 2 * .pi / 180
            let rr = (g.inner + g.outer) / 2
            let p = NSPoint(x: c.x + cos(mid) * rr, y: c.y + sin(mid) * rr)
            let fg = i == hovered ? NSColor.white : text
            let span = (g.end - g.start) * .pi / 180 * rr
            let maxW = min(span - 8, g.outer - g.inner + 10)
            if let img = NSImage(systemSymbolName: op.symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 15, weight: .medium)) {
                let tinted = img.tinted(fg)
                let s = tinted.size
                tinted.draw(in: NSRect(x: p.x - s.width / 2, y: p.y + 2, width: s.width, height: s.height))
            }
            let font = NSFont.systemFont(ofSize: op.title.count > 9 ? 9.5 : 11, weight: .semibold)
            let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byWordWrapping
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: para]
            let str = NSAttributedString(string: op.title, attributes: attrs)
            let box = str.boundingRect(with: NSSize(width: maxW, height: 30), options: [.usesLineFragmentOrigin])
            str.draw(with: NSRect(x: p.x - maxW / 2, y: p.y - box.height - 2, width: maxW, height: box.height), options: [.usesLineFragmentOrigin])
        }

        // Center: wheel name + file name; dropping here cancels.
        let hub = NSBezierPath(ovalIn: NSRect(x: c.x - hole, y: c.y - hole, width: hole * 2, height: hole * 2))
        kind.color.withAlphaComponent(0.92).setFill(); hub.fill()
        let para = NSMutableParagraphStyle(); para.alignment = .center; para.lineBreakMode = .byTruncatingMiddle
        let title = NSAttributedString(string: kind.title, attributes: [.font: NSFont.systemFont(ofSize: 14, weight: .bold), .foregroundColor: NSColor.white, .paragraphStyle: para])
        title.draw(in: NSRect(x: c.x - hole + 8, y: c.y + 2, width: hole * 2 - 16, height: 20))
        let sub = files.count == 1 ? files[0].lastPathComponent : "\(files.count) items"
        NSAttributedString(string: sub, attributes: [.font: NSFont.systemFont(ofSize: 9.5), .foregroundColor: NSColor.white.withAlphaComponent(0.9), .paragraphStyle: para])
            .draw(in: NSRect(x: c.x - hole + 10, y: c.y - 14, width: hole * 2 - 20, height: 14))
        let hint = clickMode ? "esc to cancel" : "drop here to cancel"
        NSAttributedString(string: hint, attributes: [.font: NSFont.systemFont(ofSize: 8.5), .foregroundColor: NSColor.white.withAlphaComponent(0.7), .paragraphStyle: para])
            .draw(in: NSRect(x: c.x - hole + 8, y: c.y - 30, width: hole * 2 - 16, height: 12))

        // Key legend under the wheel.
        let s = Settings.shared
        let legend = "\(s.convertKey.symbol.prefix(1)) Convert   \(s.toolsKey.symbol.prefix(1)) Tools   \(s.actionsKey.symbol.prefix(1)) Actions"
        let lp = NSMutableParagraphStyle(); lp.alignment = .center
        let ls = NSAttributedString(string: legend, attributes: [.font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: text, .paragraphStyle: lp])
        let pill = NSRect(x: c.x - 105, y: c.y - maxRadius - 34, width: 210, height: 22)
        base.setFill(); NSBezierPath(roundedRect: pill, xRadius: 11, yRadius: 11).fill()
        ls.draw(in: pill.insetBy(dx: 0, dy: 4))

        if ops.isEmpty {
            NSAttributedString(string: "Nothing available", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: text, .paragraphStyle: lp])
                .draw(in: NSRect(x: c.x - 80, y: c.y + hole + 20, width: 160, height: 18))
        }
    }

    // MARK: Drag destination

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        hovered = index(at: convert(sender.draggingLocation, from: nil))
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) { hovered = nil }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let idx = index(at: convert(sender.draggingLocation, from: nil))
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        guard let idx else { controller?.close(); return false }
        let op = ops[idx]
        DispatchQueue.main.async { self.controller?.perform(op, files: urls) }
        return true
    }

    // MARK: Click / keyboard mode

    override func mouseMoved(with event: NSEvent) {
        guard clickMode else { return }
        if let i = index(at: convert(event.locationInWindow, from: nil)) { hovered = i }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let i = index(at: p) { controller?.perform(ops[i], files: files) }
        else if hypot(p.x - center.x, p.y - center.y) < hole || hypot(p.x - center.x, p.y - center.y) > maxRadius { controller?.close() }
    }

    override func keyDown(with event: NSEvent) {
        let n = ops.count
        switch event.keyCode {
        case 53: controller?.close() // esc
        case 36, 76: if let h = hovered, h < n { controller?.perform(ops[h], files: files) } // return
        case 124, 125: if n > 0 { hovered = ((hovered ?? -1) + 1) % n } // right / down
        case 123, 126: if n > 0 { hovered = ((hovered ?? 0) - 1 + n) % n } // left / up
        case 48: // tab cycles wheels
            let next = WheelKind(rawValue: (kind.rawValue + 1) % WheelKind.allCases.count)!
            configure(files: files, kind: next, clickMode: clickMode)
        default:
            // Number keys 1–9 pick a wedge directly.
            if let ch = event.charactersIgnoringModifiers, let d = Int(ch), d >= 1, d <= n { controller?.perform(ops[d - 1], files: files) }
        }
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = self.copy() as! NSImage
        img.lockFocus()
        color.set()
        NSRect(origin: .zero, size: img.size).fill(using: .sourceAtop)
        img.unlockFocus()
        img.isTemplate = false
        return img
    }
}
