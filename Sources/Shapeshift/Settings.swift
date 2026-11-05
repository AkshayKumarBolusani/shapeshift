import AppKit
import SwiftUI

enum OutputLocation: String, CaseIterable, Identifiable {
    case besideOriginal, downloads, custom
    var id: String { rawValue }
    var label: String {
        switch self {
        case .besideOriginal: return "Beside the original"
        case .downloads: return "Downloads folder"
        case .custom: return "Custom folder…"
        }
    }
}

enum TriggerKey: String, CaseIterable, Identifiable {
    case shift, command, control, option
    var id: String { rawValue }
    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        case .option: return .option
        }
    }
    var symbol: String {
        switch self {
        case .shift: return "⇧ Shift"
        case .command: return "⌘ Command"
        case .control: return "⌃ Control"
        case .option: return "⌥ Option"
        }
    }
}

extension Notification.Name { static let menuBarIconChanged = Notification.Name("ShapeshiftMenuBarIconChanged") }

final class Settings: ObservableObject {
    static let shared = Settings()
    private let d = UserDefaults.standard

    @Published var convertKey: TriggerKey { didSet { d.set(convertKey.rawValue, forKey: "convertKey") } }
    @Published var toolsKey: TriggerKey { didSet { d.set(toolsKey.rawValue, forKey: "toolsKey") } }
    @Published var actionsKey: TriggerKey { didSet { d.set(actionsKey.rawValue, forKey: "actionsKey") } }
    @Published var outputLocation: OutputLocation { didSet { d.set(outputLocation.rawValue, forKey: "outputLocation") } }
    @Published var customOutputPath: String? { didSet { d.set(customOutputPath, forKey: "customOutputPath") } }
    @Published var jpegQuality: Double { didSet { d.set(jpegQuality, forKey: "jpegQuality") } }
    @Published var pdfDPI: Double { didSet { d.set(pdfDPI, forKey: "pdfDPI") } }
    @Published var dragTriggerEnabled: Bool { didSet { d.set(dragTriggerEnabled, forKey: "dragTriggerEnabled") } }
    @Published var revealAfterConvert: Bool { didSet { d.set(revealAfterConvert, forKey: "revealAfterConvert") } }
    @Published var showMenuBarIcon: Bool { didSet { d.set(showMenuBarIcon, forKey: "showMenuBarIcon"); NotificationCenter.default.post(name: .menuBarIconChanged, object: nil) } }
    @Published var hotKeyEnabled: Bool { didSet { d.set(hotKeyEnabled, forKey: "hotKeyEnabled") } }
    @Published var showToasts: Bool { didSet { d.set(showToasts, forKey: "showToasts") } }

    private init() {
        convertKey = TriggerKey(rawValue: d.string(forKey: "convertKey") ?? "") ?? .shift
        toolsKey = TriggerKey(rawValue: d.string(forKey: "toolsKey") ?? "") ?? .command
        actionsKey = TriggerKey(rawValue: d.string(forKey: "actionsKey") ?? "") ?? .control
        outputLocation = OutputLocation(rawValue: d.string(forKey: "outputLocation") ?? "") ?? .besideOriginal
        customOutputPath = d.string(forKey: "customOutputPath")
        jpegQuality = d.object(forKey: "jpegQuality") as? Double ?? 0.85
        pdfDPI = d.object(forKey: "pdfDPI") as? Double ?? 300
        dragTriggerEnabled = d.object(forKey: "dragTriggerEnabled") as? Bool ?? true
        revealAfterConvert = d.object(forKey: "revealAfterConvert") as? Bool ?? false
        showMenuBarIcon = d.object(forKey: "showMenuBarIcon") as? Bool ?? true
        hotKeyEnabled = d.object(forKey: "hotKeyEnabled") as? Bool ?? true
        showToasts = d.object(forKey: "showToasts") as? Bool ?? true
    }

    func wheel(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        if flags.contains(convertKey.flag) { return .convert }
        if flags.contains(toolsKey.flag) { return .tools }
        if flags.contains(actionsKey.flag) { return .actions }
        return nil
    }
}

/// Opens Terminal with a Homebrew install command (or the Homebrew site if brew is missing).
enum Installer {
    static func run(_ command: String) {
        guard Tools.path("brew") != nil else {
            NSWorkspace.shared.open(URL(string: "https://brew.sh")!)
            return
        }
        let script = "tell application \"Terminal\"\n activate\n do script \"\(command)\"\n end tell"
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
    }
}
