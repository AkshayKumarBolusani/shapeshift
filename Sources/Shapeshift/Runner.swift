import AppKit

enum Runner {
    static func run(_ op: Operation, files rawFiles: [URL]) {
        let files = rawFiles.map(\.realFileURL)
        if !op.silent && Settings.shared.showToasts { Toast.progress("\(op.title)… \(files.count == 1 ? files[0].lastPathComponent : "\(files.count) files")") }
        Task {
            do {
                let outs = try await op.run(files)
                await MainActor.run {
                    guard !op.silent else { return }
                    History.add(outs)
                    let name = outs.count == 1 ? outs[0].lastPathComponent : "\(outs.count) files"
                    if Settings.shared.showToasts { Toast.show("Saved \(name)", reveal: outs) }
                    if Settings.shared.revealAfterConvert, !outs.isEmpty { NSWorkspace.shared.activateFileViewerSelecting(outs) }
                }
            } catch is CancellationError {
                await MainActor.run { Toast.hide() }
            } catch {
                await MainActor.run { Toast.show(error.localizedDescription, isError: true) }
            }
        }
    }
}

enum History {
    static var items: [URL] { HistoryStore.shared.items }
    static func add(_ urls: [URL]) {
        HistoryStore.shared.add(urls)
        NotificationCenter.default.post(name: .historyChanged, object: nil)
    }
}

extension Notification.Name { static let historyChanged = Notification.Name("ShapeshiftHistoryChanged") }

/// Small HUD in the bottom-right corner of the active screen.
final class Toast {
    private static var panel: NSPanel?
    private static var label = NSTextField(labelWithString: "")
    private static var spinner = NSProgressIndicator()
    private static var icon = NSImageView()
    private static var reveal = NSButton(title: "Show", target: nil, action: nil)
    private static var revealURLs: [URL] = []
    private static var hideWork: DispatchWorkItem?
    private static let handler = ToastHandler()

    private static func ensure() -> NSPanel {
        if let p = panel { return p }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false; p.backgroundColor = .clear; p.level = .statusBar; p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let fx = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
        fx.material = .hudWindow; fx.state = .active; fx.blendingMode = .behindWindow
        fx.wantsLayer = true; fx.layer?.cornerRadius = 12; fx.layer?.masksToBounds = true
        spinner.style = .spinning; spinner.controlSize = .small
        spinner.frame = NSRect(x: 14, y: 19, width: 16, height: 16)
        icon.frame = NSRect(x: 12, y: 17, width: 20, height: 20)
        label.frame = NSRect(x: 40, y: 10, width: 230, height: 34)
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.maximumNumberOfLines = 2
        label.lineBreakMode = .byTruncatingMiddle
        label.cell?.wraps = true
        reveal.frame = NSRect(x: 272, y: 13, width: 58, height: 28)
        reveal.bezelStyle = .rounded
        reveal.target = handler; reveal.action = #selector(ToastHandler.reveal)
        [spinner, icon, label, reveal].forEach { fx.addSubview($0) }
        p.contentView = fx
        let click = NSClickGestureRecognizer(target: handler, action: #selector(ToastHandler.dismiss))
        fx.addGestureRecognizer(click)
        panel = p
        return p
    }

    private static func place(_ p: NSPanel) {
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main!
        let vf = screen.visibleFrame
        p.setFrameOrigin(NSPoint(x: vf.maxX - p.frame.width - 16, y: vf.minY + 16))
        p.orderFrontRegardless()
    }

    static func progress(_ text: String) {
        let p = ensure()
        hideWork?.cancel()
        label.stringValue = text
        icon.isHidden = true; spinner.isHidden = false; spinner.startAnimation(nil)
        reveal.isHidden = true
        place(p)
    }

    static func show(_ text: String, reveal urls: [URL] = [], isError: Bool = false) {
        let p = ensure()
        hideWork?.cancel()
        label.stringValue = text
        spinner.stopAnimation(nil); spinner.isHidden = true
        icon.isHidden = false
        icon.image = NSImage(systemSymbolName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill", accessibilityDescription: nil)
        icon.contentTintColor = isError ? .systemOrange : .systemGreen
        revealURLs = urls
        reveal.isHidden = urls.isEmpty
        label.frame.size.width = urls.isEmpty ? 290 : 230
        place(p)
        let work = DispatchWorkItem { hide() }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (isError ? 8 : 4.5), execute: work)
    }

    static func hide() { panel?.orderOut(nil) }

    final class ToastHandler: NSObject {
        @objc func reveal() { NSWorkspace.shared.activateFileViewerSelecting(Toast.revealURLs); Toast.hide() }
        @objc func dismiss() { Toast.hide() }
    }
}
