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
    }

    func wheel(for flags: NSEvent.ModifierFlags) -> WheelKind? {
        if flags.contains(convertKey.flag) { return .convert }
        if flags.contains(toolsKey.flag) { return .tools }
        if flags.contains(actionsKey.flag) { return .actions }
        return nil
    }
}

struct SettingsView: View {
    @ObservedObject var s = Settings.shared

    var body: some View {
        Form {
            Section("Wheel keys (tap while dragging a file)") {
                Picker("Convert", selection: $s.convertKey) { ForEach(TriggerKey.allCases) { Text($0.symbol).tag($0) } }
                Picker("Tools", selection: $s.toolsKey) { ForEach(TriggerKey.allCases) { Text($0.symbol).tag($0) } }
                Picker("Actions", selection: $s.actionsKey) { ForEach(TriggerKey.allCases) { Text($0.symbol).tag($0) } }
                Toggle("Open wheels while dragging files", isOn: $s.dragTriggerEnabled)
                Text("Keyboard: select files in Finder and press ⌃⌥Space.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Output") {
                Picker("Save results", selection: $s.outputLocation) { ForEach(OutputLocation.allCases) { Text($0.label).tag($0) } }
                    .onChange(of: s.outputLocation) { v in if v == .custom { chooseFolder() } }
                if s.outputLocation == .custom {
                    HStack {
                        Text(s.customOutputPath ?? "None").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Reveal result in Finder", isOn: $s.revealAfterConvert)
            }
            Section("Quality") {
                HStack { Text("JPEG / HEIC / WebP quality"); Slider(value: $s.jpegQuality, in: 0.3...1.0); Text("\(Int(s.jpegQuality * 100))%").frame(width: 40) }
                Picker("PDF → image resolution", selection: $s.pdfDPI) {
                    Text("150 DPI").tag(150.0); Text("300 DPI").tag(300.0); Text("600 DPI").tag(600.0)
                }
            }
            Section("Engines") {
                engineRow("ffmpeg (audio & video)", Tools.ffmpeg, install: "brew install ffmpeg")
                engineRow("cwebp (WebP export)", Tools.cwebp, install: "brew install webp")
                engineRow("LibreOffice (slides, XLS, ODS)", Tools.soffice, install: "brew install --cask libreoffice")
                Text("After installing, quit and reopen Shapeshift.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 560)
    }

    private func engineRow(_ name: String, _ path: String?, install: String) -> some View {
        HStack {
            Image(systemName: path == nil ? "xmark.circle" : "checkmark.circle.fill").foregroundStyle(path == nil ? .red : .green)
            Text(name)
            Spacer()
            if path == nil {
                Button("Install…") { Installer.run(install) }
            } else {
                Text("installed").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url { s.customOutputPath = url.path } else if s.customOutputPath == nil { s.outputLocation = .besideOriginal }
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
