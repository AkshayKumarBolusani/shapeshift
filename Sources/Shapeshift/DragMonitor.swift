import AppKit
import Carbon

/// Detects a file drag anywhere on the system and opens a wheel when a trigger key is tapped.
/// Works by polling the drag pasteboard, mouse buttons and modifier flags, so it needs no
/// Accessibility or Input Monitoring permission.
final class DragMonitor {
    static let shared = DragMonitor()
    private let dragPB = NSPasteboard(name: .drag)
    private var timer: Timer?
    private var buttonDown = false
    private var countAtMouseUp = 0
    private var dragging = false
    private var files: [URL] = []
    private var lastFlags: NSEvent.ModifierFlags = []
    private let watched: NSEvent.ModifierFlags = [.shift, .command, .control, .option]

    func start() {
        countAtMouseUp = dragPB.changeCount
        let t = Timer(timeInterval: 1.0 / 40.0, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let down = NSEvent.pressedMouseButtons & 1 == 1
        let wheel = WheelController.shared
        if !down {
            if buttonDown {
                buttonDown = false
                if dragging { dragging = false; wheel.dragEnded() }
            }
            countAtMouseUp = dragPB.changeCount
            return
        }
        if !buttonDown { buttonDown = true; lastFlags = NSEvent.modifierFlags.intersection(watched) }
        guard Settings.shared.dragTriggerEnabled else { return }

        if !dragging, dragPB.changeCount != countAtMouseUp {
            countAtMouseUp = dragPB.changeCount
            let urls = dragPB.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            if !urls.isEmpty, !isOwnDrag() {
                dragging = true
                files = urls.map(\.realFileURL)
                lastFlags = NSEvent.modifierFlags.intersection(watched)
            }
        }
        guard dragging else { return }
        let flags = NSEvent.modifierFlags.intersection(watched)
        let pressed = flags.subtracting(lastFlags)
        lastFlags = flags
        guard !pressed.isEmpty, let kind = Settings.shared.wheel(for: pressed) else { return }
        if wheel.isOpen {
            if wheel.currentKind != kind { wheel.switchKind(kind) }
        } else {
            wheel.show(files: files, kind: kind, mode: .drag)
        }
    }

    /// Drags started from our own Float windows shouldn't re-open wheels.
    private func isOwnDrag() -> Bool {
        NSApp.windows.contains { $0 is FloatWindow && $0.isVisible && NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
    }
}

/// System-wide ⌃⌥Space: open the wheel for whatever is selected in Finder.
final class HotKey {
    static let shared = HotKey()
    private var ref: EventHotKeyRef?
    var handler: (() -> Void)?

    func register() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.shared.handler?() }
            return noErr
        }, 1, &spec, nil, nil)
        let id = EventHotKeyID(signature: OSType(0x53485348), id: 1) // 'SHSH'
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id, GetApplicationEventTarget(), 0, &ref)
    }
}

enum Finder {
    static func selection() -> [URL] {
        let src = """
        tell application "Finder"
            set out to ""
            repeat with f in (selection as alias list)
                set out to out & POSIX path of f & linefeed
            end repeat
            return out
        end tell
        """
        var err: NSDictionary?
        guard let res = NSAppleScript(source: src)?.executeAndReturnError(&err).stringValue else { return [] }
        return res.split(separator: "\n").map { URL(fileURLWithPath: String($0)) }
    }
}
