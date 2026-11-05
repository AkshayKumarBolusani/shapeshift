import AppKit
import SwiftUI

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var unusedWindow: NSWindow?
    private let recentMenu = NSMenu()

    func applicationDidFinishLaunching(_ note: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            b.image = NSImage(systemSymbolName: "circle.hexagongrid.circle", accessibilityDescription: "Shapeshift")
            b.toolTip = "Shapeshift: drag a file and tap ⇧ ⌘ or ⌃"
        }
        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(withTitle: "Convert Files…", action: #selector(openFiles), keyEquivalent: "o").target = self
        let sel = menu.addItem(withTitle: "Convert Finder Selection", action: #selector(finderSelection), keyEquivalent: " ")
        sel.keyEquivalentModifierMask = [.control, .option]
        sel.target = self
        menu.addItem(.separator())
        let recent = menu.addItem(withTitle: "Recent Results", action: nil, keyEquivalent: "")
        recent.submenu = recentMenu
        menu.addItem(.separator())
        menu.addItem(withTitle: "How to Use", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Customize Wheels…", action: #selector(openFeatures), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Shapeshift…", action: #selector(openMain), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shapeshift", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
        applyMenuBarIcon()
        NotificationCenter.default.addObserver(forName: .menuBarIconChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applyMenuBarIcon() }
        }

        DragMonitor.shared.start()
        HotKey.shared.handler = { [weak self] in if Settings.shared.hotKeyEnabled { self?.finderSelection() } }
        HotKey.shared.register()

        if Tools.ffmpeg == nil && UserDefaults.standard.bool(forKey: "welcomed") == false {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.offerFFmpeg() }
        }
        let firstRun = !UserDefaults.standard.bool(forKey: "welcomed")
        UserDefaults.standard.set(true, forKey: "welcomed")
        // Opening the app yourself shows the window; starting at login stays quietly in the menu bar.
        if !launchedAsLoginItem {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { MainWindow.shared.show(firstRun ? .guide : nil) }
        }
        if false {
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        recentMenu.removeAllItems()
        if History.items.isEmpty { recentMenu.addItem(withTitle: "Nothing yet", action: nil, keyEquivalent: "") }
        for url in History.items {
            let item = recentMenu.addItem(withTitle: url.lastPathComponent, action: #selector(revealRecent(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            let icon = NSWorkspace.shared.icon(forFile: url.path); icon.size = NSSize(width: 16, height: 16)
            item.image = icon
        }
    }

    @objc private func revealRecent(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc private func openFiles() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.message = "Choose files to convert"
        guard p.runModal() == .OK, !p.urls.isEmpty else { return }
        let screen = NSScreen.main!.visibleFrame
        WheelController.shared.show(files: p.urls, kind: .convert, mode: .click, at: NSPoint(x: screen.midX, y: screen.midY))
    }

    @objc private func finderSelection() {
        let files = Finder.selection()
        guard !files.isEmpty else {
            Toast.show("Select files in Finder first", isError: true)
            return
        }
        WheelController.shared.show(files: files, kind: .convert, mode: .click)
    }

    @objc private func openSettings() { MainWindow.shared.show(.general) }
    @objc private func openMain() { MainWindow.shared.show() }
    @objc private func openFeatures() { MainWindow.shared.show(.features) }

    /// Clicking the app in Finder/Dock/Spotlight while it's running opens the window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        MainWindow.shared.show()
        return true
    }

    private func applyMenuBarIcon() { statusItem.isVisible = Settings.shared.showMenuBarIcon }

    private var launchedAsLoginItem: Bool {
        guard let e = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return e.eventID == kAEOpenApplication && e.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }

    private func offerFFmpeg() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Install ffmpeg for audio & video?"
        a.informativeText = "Images, PDFs, documents, spreadsheets and archives work right away. Audio and video conversion needs the free ffmpeg engine (installed with Homebrew)."
        a.addButton(withTitle: "Install ffmpeg")
        a.addButton(withTitle: "Later")
        if a.runModal() == .alertFirstButtonReturn { Installer.run("brew install ffmpeg webp") }
    }

    @objc private func showHelp() {
        let s = Settings.shared
        Prompt.showText(title: "How to use Shapeshift", text: """
        Shapeshift lives in your menu bar. Everything runs locally on your Mac.

        WHILE DRAGGING A FILE (from Finder, Desktop, anywhere):
          tap \(s.convertKey.symbol)   → Convert wheel (formats)
          tap \(s.toolsKey.symbol) → Tools wheel (compress, trim, merge, rotate…)
          tap \(s.actionsKey.symbol) → Actions wheel (AirDrop, Float, Copy, Move, Copy Path, Terminal)
          You can let go of the key; the wheel stays open.
          Drop the file on a wedge to run it. Drop on the center to cancel.
          Tap another key to switch wheels mid-drag.

        WITH THE KEYBOARD:
          Select files in Finder and press ⌃⌥Space.
          Arrow keys choose, Return applies, Tab switches wheel, Esc cancels,
          1–9 pick a wedge directly. Or click a wedge.

        RESULTS are saved as a new copy beside the original (change in Settings).
        Originals are never modified.

        ENGINES:
          ffmpeg  — audio & video     \(Tools.ffmpeg == nil ? "MISSING (brew install ffmpeg)" : "✓")
          cwebp   — WebP export        \(Tools.cwebp == nil ? "missing (brew install webp)" : "✓")
          LibreOffice — slides, XLS, ODS, PDF→PPTX/XLSX  \(Tools.soffice == nil ? "optional (brew install --cask libreoffice)" : "✓")
        """)
    }
}

// CLI: Shapeshift --run <convert|tools|actions> "<Wedge title>" file1 [file2…]
//      Shapeshift --list <convert|tools|actions> file
let args = CommandLine.arguments
if args.count >= 4, ["--run", "--list", "--snapshot", "--snapshot-page"].contains(args[1]) {
    let kind: WheelKind = ["convert": .convert, "tools": .tools, "actions": .actions][args[2]] ?? .convert
    if args[1] == "--snapshot-page" {
        // Shapeshift --snapshot-page <page> <out.png> [dark]: render the main window offscreen.
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            NSApp.appearance = NSAppearance(named: args.count > 4 && args[4] == "dark" ? .darkAqua : .aqua)
            let nav = MainWindow.NavState()
            nav.page = MainWindow.Page(rawValue: args[2]) ?? .features
            let host = NSHostingView(rootView: MainView(nav: nav))
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
            w.contentView = host
            w.layoutIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
            host.cacheDisplay(in: host.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[3]))
        }
        exit(0)
    }
    if args[1] == "--snapshot", args.count >= 5 {
        // Shapeshift --snapshot <kind> <file> <out.png>: render the wheel to an image.
        MainActor.assumeIsolated {
            _ = NSApplication.shared
            let v = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.diameter, height: WheelView.diameter))
            v.configure(files: [URL(fileURLWithPath: args[3])], kind: kind, clickMode: false)
            let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds)!
            v.cacheDisplay(in: v.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: args[4]))
        }
        exit(0)
    }
    if args[1] == "--list" {
        let files = args[3...].map { URL(fileURLWithPath: $0) }
        print(Catalog.operations(for: files, kind: kind).map(\.title).joined(separator: "\n"))
        exit(0)
    }
    let files = args[4...].map { URL(fileURLWithPath: $0) }
    guard let op = Catalog.operations(for: files, kind: kind).first(where: { $0.title.lowercased() == args[3].lowercased() }) else {
        FileHandle.standardError.write("No wedge named \(args[3])\n".data(using: .utf8)!)
        exit(2)
    }
    _ = NSApplication.shared
    Task {
        do {
            let outs = try await op.run(files)
            outs.forEach { print($0.path) }
            exit(0)
        } catch {
            FileHandle.standardError.write("ERROR: \(error.localizedDescription)\n".data(using: .utf8)!)
            exit(1)
        }
    }
    RunLoop.main.run()
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) { app.run() }
}
