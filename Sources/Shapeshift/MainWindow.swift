import AppKit
import SwiftUI

// MARK: - Window controller

final class MainWindow: NSObject, NSWindowDelegate {
    static let shared = MainWindow()
    private var window: NSWindow?
    let nav = NavState()

    final class NavState: ObservableObject { @Published var page: Page = .features }

    enum Page: String, CaseIterable, Identifiable {
        case features, general, quality, engines, history, guide, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .features: return "Wheel Features"
            case .general: return "General"
            case .quality: return "Quality"
            case .engines: return "Engines"
            case .history: return "History"
            case .guide: return "How to Use"
            case .about: return "About"
            }
        }
        var symbol: String {
            switch self {
            case .features: return "circle.grid.cross"
            case .general: return "gearshape"
            case .quality: return "dial.medium"
            case .engines: return "shippingbox"
            case .history: return "clock.arrow.circlepath"
            case .guide: return "questionmark.circle"
            case .about: return "info.circle"
            }
        }
    }

    @MainActor func show(_ page: Page? = nil) {
        if let page { nav.page = page }
        if window == nil {
            let host = NSHostingController(rootView: MainView(nav: nav))
            let w = NSWindow(contentViewController: host)
            w.title = "Shapeshift"
            w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            w.titlebarAppearsTransparent = false
            w.setContentSize(NSSize(width: 1000, height: 640))
            w.minSize = NSSize(width: 900, height: 540)
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.setFrameAutosaveName("ShapeshiftMain")
            if !w.setFrameUsingName("ShapeshiftMain") { w.center() }
            window = w
        }
        // Show in the Dock and ⌘-Tab while the window is open.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        DispatchQueue.main.async { NSApp.setActivationPolicy(.accessory) }
    }
}

// MARK: - Root

struct MainView: View {
    @ObservedObject var nav: MainWindow.NavState

    var body: some View {
        NavigationSplitView {
            List(MainWindow.Page.allCases, selection: Binding(get: { nav.page }, set: { if let p = $0 { nav.page = p } })) { p in
                Label(p.title, systemImage: p.symbol).tag(p)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 8) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 28, height: 28)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("Shapeshift").font(.headline)
                        Text("v\(appVersion)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }.padding(12)
            }
        } detail: {
            Group {
                switch nav.page {
                case .features: FeaturesPage()
                case .general: GeneralPage()
                case .quality: QualityPage()
                case .engines: EnginesPage()
                case .history: HistoryPage()
                case .guide: GuidePage()
                case .about: AboutPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

var appVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev" }

// MARK: - Wheel features (add / remove / reorder)

struct FeaturesPage: View {
    @ObservedObject private var custom = Customization.shared
    @ObservedObject private var m = FeaturesModel.shared
    private var group: FileTypeGroup { m.group }
    private var kind: WheelKind { m.kind }
    private var search: String { m.search }

    private var categoryKey: String { kind == .actions ? "any" : group.id }

    private var ops: [Operation] {
        let all = kind == .actions ? FileActions.all() : group.operations(kind)
        return custom.ordered(all, kind: kind, category: categoryKey)
    }

    var body: some View {
        HStack(spacing: 0) {
            // File types
            List(FileTypeGroup.all, selection: Binding(get: { group }, set: { if let g = $0 { m.group = g } })) { g in
                Label(g.name, systemImage: g.symbol).tag(g)
            }
            .frame(width: 160)
            .disabled(kind == .actions)
            .opacity(kind == .actions ? 0.45 : 1)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Picker("", selection: $m.kind) {
                        ForEach(WheelKind.allCases, id: \.self) { k in Text(wheelLabel(k)).tag(k) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 380)
                    Spacer()
                    TextField("Filter", text: $m.search).textFieldStyle(.roundedBorder).frame(width: 140)
                }
                Text(kind == .actions ? "Actions are the same for every file type." :
                        "Turn wedges on or off and drag to reorder what appears on the \(kind.title) wheel for \(group.name.lowercased()).")
                    .font(.callout).foregroundStyle(.secondary)

                HStack(alignment: .top, spacing: 16) {
                    let list = ops.filter { search.isEmpty || $0.title.localizedCaseInsensitiveContains(search) }
                    List {
                        ForEach(list, id: \.title) { op in
                            HStack(spacing: 10) {
                                Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                                Image(systemName: op.symbol).frame(width: 22).foregroundStyle(kindColor)
                                Text(op.title)
                                Spacer()
                                Toggle("", isOn: Binding(
                                    get: { custom.isEnabled(kind, categoryKey, op.title) },
                                    set: { custom.setEnabled($0, kind, categoryKey, op.title) }
                                )).toggleStyle(.switch).labelsHidden().controlSize(.small)
                            }
                            .padding(.vertical, 2)
                        }
                        .onMove { from, to in
                            guard search.isEmpty else { return }
                            var titles = ops.map(\.title)
                            titles.move(fromOffsets: from, toOffset: to)
                            custom.setOrder(titles, kind, categoryKey)
                        }
                    }
                    .listStyle(.inset(alternatesRowBackgrounds: true))
                    .frame(minWidth: 250)

                    VStack(spacing: 8) {
                        WheelPreview(group: group, kind: kind, token: "\(custom.hidden.count)-\(custom.order.description.hashValue)")
                            .frame(width: WheelPreview.size, height: WheelPreview.size)
                        let on = ops.filter { custom.isEnabled(kind, categoryKey, $0.title) }.count
                        Text("\(on) of \(ops.count) shown").font(.caption).foregroundStyle(.secondary)
                    }
                }

                HStack {
                    Button("Show All") { for op in ops { custom.setEnabled(true, kind, categoryKey, op.title) } }
                    Button("Hide All") { for op in ops { custom.setEnabled(false, kind, categoryKey, op.title) } }
                    Button("Reset This Wheel") { custom.reset(kind, categoryKey) }
                    Spacer()
                    Button("Reset Everything", role: .destructive) { custom.resetAll() }
                }
            }
            .padding(20)
        }
        .navigationTitle("Wheel Features")
    }

    private var kindColor: Color { Color(nsColor: kind.color) }

    private func wheelLabel(_ k: WheelKind) -> String {
        let s = Settings.shared
        let key = [s.convertKey, s.toolsKey, s.actionsKey][k.rawValue].symbol.prefix(1)
        return "\(key) \(k.title)"
    }
}

/// Live, scaled-down copy of the real wheel.
struct WheelPreview: NSViewRepresentable {
    static let size: CGFloat = 220
    let group: FileTypeGroup
    let kind: WheelKind
    let token: String

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let wheel = WheelView(frame: NSRect(x: 0, y: 0, width: WheelView.diameter, height: WheelView.diameter))
        wheel.unregisterDraggedTypes()
        container.addSubview(wheel)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        guard let wheel = container.subviews.first as? WheelView else { return }
        let files: [URL] = group.samples == ["__folder__"] ? [FileManager.default.temporaryDirectory]
            : [URL(fileURLWithPath: "/tmp/shapeshift-sample/\(group.samples[0])")]
        wheel.configure(files: files, kind: kind, clickMode: false)
        // Draw the full-size wheel scaled into the preview box.
        wheel.frame = NSRect(x: 0, y: 0, width: WheelPreview.size, height: WheelPreview.size)
        wheel.setBoundsSize(NSSize(width: WheelView.diameter, height: WheelView.diameter))
        wheel.needsDisplay = true
    }
}

// MARK: - General

struct GeneralPage: View {
    @ObservedObject var s = Settings.shared
    @ObservedObject private var m = GeneralModel.shared

    var body: some View {
        Form {
            Section("Wheel keys — tap while dragging a file") {
                Picker("Convert wheel", selection: $s.convertKey) { ForEach(TriggerKey.allCases) { Text($0.symbol).tag($0) } }
                Picker("Tools wheel", selection: $s.toolsKey) { ForEach(TriggerKey.allCases) { Text($0.symbol).tag($0) } }
                Picker("Actions wheel", selection: $s.actionsKey) { ForEach(TriggerKey.allCases) { Text($0.symbol).tag($0) } }
                Toggle("Open wheels while dragging files", isOn: $s.dragTriggerEnabled)
                Toggle("⌃⌥Space opens the wheel for the Finder selection", isOn: $s.hotKeyEnabled)
            }
            Section("Saving results") {
                Picker("Save converted files", selection: $s.outputLocation) { ForEach(OutputLocation.allCases) { Text($0.label).tag($0) } }
                    .onChange(of: s.outputLocation) { v in if v == .custom && s.customOutputPath == nil { chooseFolder() } }
                if s.outputLocation == .custom {
                    HStack {
                        Text(s.customOutputPath ?? "None").lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Spacer()
                        Button("Choose…") { chooseFolder() }
                    }
                }
                Toggle("Reveal result in Finder", isOn: $s.revealAfterConvert)
                Toggle("Show progress and result pop-ups", isOn: $s.showToasts)
            }
            Section("App") {
                Toggle("Show icon in menu bar", isOn: $s.showMenuBarIcon)
                if !s.showMenuBarIcon {
                    Text("Open Shapeshift from Applications or Spotlight to get back to this window.").font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Open at login", isOn: Binding(get: { m.loginOn }, set: { on in
                    do { try LoginItem.set(on); m.loginOn = LoginItem.isEnabled; m.loginError = nil }
                    catch { m.loginError = error.localizedDescription; m.loginOn = LoginItem.isEnabled }
                }))
                if let e = m.loginError { Text(e).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("General")
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true
        if p.runModal() == .OK, let url = p.url { s.customOutputPath = url.path }
        else if s.customOutputPath == nil { s.outputLocation = .besideOriginal }
    }
}

// MARK: - Quality

struct QualityPage: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        Form {
            Section("Images") {
                HStack {
                    Text("JPEG / HEIC / WebP / AVIF quality")
                    Slider(value: $s.jpegQuality, in: 0.3...1.0)
                    Text("\(Int(s.jpegQuality * 100))%").monospacedDigit().frame(width: 44)
                }
                Text("Higher means better-looking but larger files. \"Compress\" always uses at most 60%.").font(.caption).foregroundStyle(.secondary)
            }
            Section("PDF") {
                Picker("PDF → image resolution", selection: $s.pdfDPI) {
                    Text("150 DPI (small)").tag(150.0); Text("300 DPI (print)").tag(300.0); Text("600 DPI (sharp)").tag(600.0)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Quality")
    }
}

// MARK: - Engines

struct EnginesPage: View {
    @ObservedObject private var m = EnginesModel.shared
    var body: some View {
        Form {
            Section {
                engine("ffmpeg", "Audio & video conversion and tools", Tools.ffmpeg, "brew install ffmpeg")
                engine("cwebp", "WebP image export", Tools.cwebp, "brew install webp")
                engine("LibreOffice", "Slides, XLS, ODS, PDF → PPTX/XLSX", Tools.soffice, "brew install --cask libreoffice")
            } header: {
                Text("Optional engines")
            } footer: {
                Text("Images, PDFs, documents, spreadsheets, subtitles and archives use built-in macOS features and need nothing extra.")
            }
            Section("Built into macOS") {
                builtin("Vision", "OCR, QR codes, background removal, face blur")
                builtin("Speech", "On-device transcription")
                builtin("PDFKit & ImageIO", "PDF and image conversion")
            }
            Button("Check Again") { Tools.refresh(); m.tick += 1 }
        }
        .formStyle(.grouped)
        .id(m.tick)
        .navigationTitle("Engines")
    }

    private func engine(_ name: String, _ what: String, _ path: String?, _ cmd: String) -> some View {
        HStack {
            Image(systemName: path == nil ? "xmark.circle" : "checkmark.circle.fill").foregroundStyle(path == nil ? .orange : .green)
            VStack(alignment: .leading) { Text(name).bold(); Text(what).font(.caption).foregroundStyle(.secondary) }
            Spacer()
            if path == nil { Button("Install…") { Installer.run(cmd) } }
            else { Text(path!).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 220, alignment: .trailing) }
        }
    }

    private func builtin(_ name: String, _ what: String) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            VStack(alignment: .leading) { Text(name).bold(); Text(what).font(.caption).foregroundStyle(.secondary) }
        }
    }
}

// MARK: - History

struct HistoryPage: View {
    @ObservedObject private var store = HistoryStore.shared
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "clock").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text("Nothing converted yet").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.items, id: \.self) { url in
                        HStack(spacing: 10) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(url.lastPathComponent).lineLimit(1)
                                Text(url.deletingLastPathComponent().path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                            }
                            Spacer()
                            if FileManager.default.fileExists(atPath: url.path) {
                                Button("Open") { NSWorkspace.shared.open(url) }.buttonStyle(.borderless)
                                Button("Show") { NSWorkspace.shared.activateFileViewerSelecting([url]) }.buttonStyle(.borderless)
                            } else {
                                Text("moved or deleted").font(.caption).foregroundStyle(.tertiary)
                            }
                            Button { store.remove(url) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Remove from list")
                        }.padding(.vertical, 2)
                    }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
                HStack { Spacer(); Button("Clear History") { store.clear() } }.padding(12)
            }
        }
        .navigationTitle("History")
    }
}

// MARK: - Guide

struct GuidePage: View {
    @ObservedObject var s = Settings.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                step("hand.draw", "Drag a file", "Start dragging any file or folder from Finder, the Desktop, or anywhere else.")
                step("keyboard", "Tap a key", "\(s.convertKey.symbol) opens Convert, \(s.toolsKey.symbol) opens Tools, \(s.actionsKey.symbol) opens Actions. You can let go of the key and the wheel stays open. Tap another key to switch wheels.")
                step("target", "Drop on a wedge", "Drop on a wedge to run it. Drop on the center to cancel. The result is saved as a new copy next to the original.")
                step("command", "Or use the keyboard", "Select files in Finder and press ⌃⌥Space. Use the arrows to choose, Return to run, Tab to switch wheel, 1–9 to pick directly and Esc to cancel.")
                step("slider.horizontal.3", "Make it yours", "In Wheel Features, hide the wedges you never use and drag your favourites to the top.")
                step("lock.shield", "Private by design", "Everything runs on your Mac. Nothing is uploaded, and there's no account or tracking.")
            }
            .padding(24)
            .frame(maxWidth: 620, alignment: .leading)
        }
        .navigationTitle("How to Use")
    }

    private func step(_ icon: String, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon).font(.title2).frame(width: 34).foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 4) { Text(title).font(.headline); Text(text).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: - About

struct AboutPage: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
            Text("Shapeshift").font(.largeTitle.bold())
            Text("Version \(appVersion)").foregroundStyle(.secondary)
            Text("A free, open-source, offline file converter for macOS.").multilineTextAlignment(.center)
            HStack(spacing: 12) {
                Link("GitHub", destination: URL(string: "https://github.com/AkshayKumarBolusani/shapeshift")!)
                Link("Check for updates", destination: URL(string: "https://github.com/AkshayKumarBolusani/shapeshift/releases/latest")!)
                Link("Report a problem", destination: URL(string: "https://github.com/AkshayKumarBolusani/shapeshift/issues/new")!)
            }
            Text("MIT License · Made by Akshay Kumar Bolusani").font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("About")
    }
}


// Page state lives in small models (the @State macro needs full Xcode to compile).
final class FeaturesModel: ObservableObject {
    static let shared = FeaturesModel()
    @Published var group: FileTypeGroup = FileTypeGroup.all[0]
    @Published var kind: WheelKind = .convert
    @Published var search = ""
}
final class GeneralModel: ObservableObject {
    static let shared = GeneralModel()
    @Published var loginOn = LoginItem.isEnabled
    @Published var loginError: String?
}
final class EnginesModel: ObservableObject {
    static let shared = EnginesModel()
    @Published var tick = 0
}
