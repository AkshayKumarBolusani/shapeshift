import AppKit
import Quartz

enum FileActions {
    static func all() -> [Operation] {
        [
            Operation(title: "AirDrop", symbol: "airplayaudio", run: { urls in
                await MainActor.run {
                    guard let svc = NSSharingService(named: .sendViaAirDrop) else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    svc.perform(withItems: urls)
                }
                return []
            }, silent: true),
            Operation(title: "Float", symbol: "pin", run: { urls in
                await MainActor.run { for u in urls { FloatWindow.show(u) } }
                return []
            }, silent: true),
            Operation(title: "Copy", symbol: "doc.on.doc", run: { urls in
                await MainActor.run {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.writeObjects(urls as [NSURL])
                    Toast.show("Copied \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") — paste in Finder")
                }
                return []
            }, silent: true),
            Operation(title: "Move", symbol: "folder", run: { urls in
                let dest: URL? = await MainActor.run {
                    NSApp.activate(ignoringOtherApps: true)
                    let p = NSOpenPanel()
                    p.message = "Move \(urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) items") to…"
                    p.prompt = "Move"
                    p.canChooseDirectories = true
                    p.canChooseFiles = false
                    p.canCreateDirectories = true
                    p.directoryURL = urls[0].deletingLastPathComponent()
                    return p.runModal() == .OK ? p.url : nil
                }
                guard let dest else { throw CancellationError() }
                var moved: [URL] = []
                for u in urls {
                    let target = Paths.unique(dest.appendingPathComponent(u.lastPathComponent))
                    try FileManager.default.moveItem(at: u, to: target)
                    moved.append(target)
                }
                await MainActor.run { Toast.show("Moved to \(dest.lastPathComponent)", reveal: moved) }
                return []
            }, silent: true),
            Operation(title: "Copy Path", symbol: "link", run: { urls in
                await MainActor.run {
                    let s = urls.map { $0.path }.joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(s, forType: .string)
                    Toast.show("Path copied")
                }
                return []
            }, silent: true),
            Operation(title: "Terminal", symbol: "terminal", run: { urls in
                let u = urls[0]
                let dir = u.isDirectory ? u : u.deletingLastPathComponent()
                await MainActor.run {
                    let term = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
                    let cfg = NSWorkspace.OpenConfiguration()
                    NSWorkspace.shared.open([dir], withApplicationAt: term, configuration: cfg)
                }
                return []
            }, silent: true),
            Operation(title: "Share…", symbol: "square.and.arrow.up", run: { urls in
                await MainActor.run { SharePicker.show(urls) }
                return []
            }, silent: true),
            Operation(title: "Email", symbol: "envelope", run: { urls in
                await MainActor.run { NSSharingService(named: .composeEmail)?.perform(withItems: urls) }
                return []
            }, silent: true),
            Operation(title: "Quick Look", symbol: "eye", run: { urls in
                await MainActor.run { QuickLooker.shared.show(urls) }
                return []
            }, silent: true),
            Operation(title: "Reveal", symbol: "magnifyingglass", run: { urls in
                await MainActor.run { NSWorkspace.shared.activateFileViewerSelecting(urls) }
                return []
            }, silent: true),
        ]
    }
}

/// The standard macOS share menu, shown at the pointer.
enum SharePicker {
    private static var anchor: NSWindow?
    @MainActor static func show(_ urls: [URL]) {
        NSApp.activate(ignoringOtherApps: true)
        let m = NSEvent.mouseLocation
        let w = NSWindow(contentRect: NSRect(x: m.x - 1, y: m.y - 1, width: 2, height: 2), styleMask: .borderless, backing: .buffered, defer: false)
        w.backgroundColor = .clear; w.isOpaque = false; w.level = .popUpMenu; w.isReleasedWhenClosed = false
        w.orderFrontRegardless()
        anchor = w
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: w.contentView!.bounds, of: w.contentView!, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { w.orderOut(nil) }
    }
}

/// Quick Look panel for any files.
final class QuickLooker: NSObject, QLPreviewPanelDataSource {
    static let shared = QuickLooker()
    private var urls: [URL] = []
    @MainActor func show(_ urls: [URL]) {
        self.urls = urls
        NSApp.activate(ignoringOtherApps: true)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }
    func numberOfPreviewItems(in panel: QLPreviewPanel?) -> Int { urls.count }
    func previewPanel(_ panel: QLPreviewPanel?, previewItemAt index: Int) -> (any QLPreviewItem)? { urls[index] as NSURL }
}

/// An always-on-top window that keeps a file in view, and can be dragged back out.
final class FloatWindow: NSPanel {
    private static var open: [FloatWindow] = []
    let fileURL: URL

    static func show(_ url: URL) {
        let w = FloatWindow(url: url)
        open.append(w)
        w.makeKeyAndOrderFront(nil)
    }

    init(url: URL) {
        fileURL = url
        super.init(contentRect: NSRect(x: 0, y: 0, width: 320, height: 280),
                   styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        title = url.lastPathComponent
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        let preview = QLPreviewView(frame: .zero, style: .compact)!
        preview.previewItem = url as NSURL
        preview.autostarts = true
        let container = DragOutView(url: url)
        container.addSubview(preview)
        preview.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            preview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            preview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            preview.topAnchor.constraint(equalTo: container.topAnchor),
            preview.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -26),
        ])
        let hint = NSTextField(labelWithString: "Drag this bar to drop the file anywhere")
        hint.font = .systemFont(ofSize: 10); hint.textColor = .secondaryLabelColor
        hint.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hint)
        NSLayoutConstraint.activate([hint.centerXAnchor.constraint(equalTo: container.centerXAnchor), hint.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -6)])
        contentView = container
        let mouse = NSEvent.mouseLocation
        setFrameOrigin(NSPoint(x: mouse.x - 160, y: mouse.y - 140))
    }

    override func close() {
        super.close()
        FloatWindow.open.removeAll { $0 === self }
    }
}

/// Bottom strip of a float window acts as a drag source for the file.
final class DragOutView: NSView, NSDraggingSource {
    let url: URL
    init(url: URL) { self.url = url; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }

    override func mouseDragged(with event: NSEvent) {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 48, height: 48)
        let p = convert(event.locationInWindow, from: nil)
        item.setDraggingFrame(NSRect(x: p.x - 24, y: p.y - 24, width: 48, height: 48), contents: icon)
        beginDraggingSession(with: [item], event: event, source: self)
    }

    func draggingSession(_ s: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { [.copy, .move, .link, .generic] }
}
