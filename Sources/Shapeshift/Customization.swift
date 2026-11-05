import AppKit
import ServiceManagement

/// Which wedges are shown, and in what order, for each file type and wheel.
final class Customization: ObservableObject {
    static let shared = Customization()
    private let d = UserDefaults.standard

    /// Keys look like "tools|image|Compress".
    @Published private(set) var hidden: Set<String>
    /// "tools|image" → ordered titles.
    @Published private(set) var order: [String: [String]]

    private init() {
        hidden = Set(d.stringArray(forKey: "hiddenWedges") ?? [])
        order = d.dictionary(forKey: "wedgeOrder") as? [String: [String]] ?? [:]
    }

    private func groupKey(_ kind: WheelKind, _ category: String) -> String { "\(kind.storageKey)|\(category)" }
    private func wedgeKey(_ kind: WheelKind, _ category: String, _ title: String) -> String { "\(groupKey(kind, category))|\(title)" }

    func apply(_ ops: [Operation], kind: WheelKind, category: String) -> [Operation] {
        let visible = ops.filter { !hidden.contains(wedgeKey(kind, category, $0.title)) }
        guard let saved = order[groupKey(kind, category)], !saved.isEmpty else { return visible }
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return visible.enumerated().sorted { a, b in
            let ra = rank[a.element.title] ?? (10_000 + a.offset)
            let rb = rank[b.element.title] ?? (10_000 + b.offset)
            return ra < rb
        }.map(\.element)
    }

    func isEnabled(_ kind: WheelKind, _ category: String, _ title: String) -> Bool {
        !hidden.contains(wedgeKey(kind, category, title))
    }

    func setEnabled(_ on: Bool, _ kind: WheelKind, _ category: String, _ title: String) {
        let k = wedgeKey(kind, category, title)
        if on { hidden.remove(k) } else { hidden.insert(k) }
        d.set(Array(hidden), forKey: "hiddenWedges")
    }

    func setOrder(_ titles: [String], _ kind: WheelKind, _ category: String) {
        order[groupKey(kind, category)] = titles
        d.set(order, forKey: "wedgeOrder")
    }

    func reset(_ kind: WheelKind, _ category: String) {
        let g = groupKey(kind, category)
        hidden = hidden.filter { !$0.hasPrefix(g + "|") }
        order[g] = nil
        d.set(Array(hidden), forKey: "hiddenWedges")
        d.set(order, forKey: "wedgeOrder")
    }

    func resetAll() {
        hidden = []; order = [:]
        d.removeObject(forKey: "hiddenWedges"); d.removeObject(forKey: "wedgeOrder")
    }

    func ordered(_ ops: [Operation], kind: WheelKind, category: String) -> [Operation] {
        guard let saved = order[groupKey(kind, category)] else { return ops }
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        return ops.enumerated().sorted { (rank[$0.element.title] ?? 10_000 + $0.offset) < (rank[$1.element.title] ?? 10_000 + $1.offset) }.map(\.element)
    }
}

extension WheelKind {
    var storageKey: String { ["convert", "tools", "actions"][rawValue] }
}

/// File types listed in the Wheels editor, with sample names used to discover every wedge.
struct FileTypeGroup: Identifiable, Hashable {
    let id: String        // Category.key
    let name: String
    let symbol: String
    let samples: [String]

    static let all: [FileTypeGroup] = [
        .init(id: "image", name: "Images", symbol: "photo", samples: ["a.psd", "b.psd"]),
        .init(id: "video", name: "Video", symbol: "film", samples: ["a.flv", "b.flv"]),
        .init(id: "audio", name: "Audio", symbol: "waveform", samples: ["a.caf", "b.caf"]),
        .init(id: "pdf", name: "PDF", symbol: "doc.richtext", samples: ["a.pdf", "b.pdf"]),
        .init(id: "document", name: "Documents", symbol: "doc.text", samples: ["a.webarchive", "b.webarchive"]),
        .init(id: "markdown", name: "Markdown", symbol: "number", samples: ["a.md", "b.md"]),
        .init(id: "sheet", name: "Spreadsheets", symbol: "tablecells", samples: ["a.numbers", "b.numbers"]),
        .init(id: "slides", name: "Slides", symbol: "rectangle.on.rectangle", samples: ["a.key", "b.key"]),
        .init(id: "subtitle", name: "Subtitles", symbol: "captions.bubble", samples: ["a.srt", "b.vtt"]),
        .init(id: "archive", name: "Archives", symbol: "archivebox", samples: ["a.rar", "b.rar"]),
        .init(id: "folder", name: "Folders", symbol: "folder", samples: ["__folder__"]),
    ]

    /// Every wedge this file type can show on a wheel (union over the samples).
    func operations(_ kind: WheelKind) -> [Operation] {
        var urls: [URL]
        if samples == ["__folder__"] {
            urls = [FileManager.default.temporaryDirectory]
        } else {
            urls = samples.map { URL(fileURLWithPath: "/tmp/shapeshift-sample/\($0)") }
        }
        var seen = Set<String>()
        var result: [Operation] = []
        // Single file and multi-file variants (multi adds Merge wedges).
        let variants: [[URL]] = id == "subtitle" ? urls.map { [$0] } : [[urls[0]], urls]
        for files in variants {
            for op in Catalog.allOperations(for: files, kind: kind) where seen.insert(op.title).inserted { result.append(op) }
        }
        return result
    }
}

// MARK: - Persistent history

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    @Published private(set) var items: [URL]

    private init() {
        items = (UserDefaults.standard.stringArray(forKey: "history") ?? []).map { URL(fileURLWithPath: $0) }
    }

    func add(_ urls: [URL]) {
        items.removeAll { urls.contains($0) }
        items.insert(contentsOf: urls, at: 0)
        items = Array(items.prefix(100))
        save()
    }

    func remove(_ url: URL) { items.removeAll { $0 == url }; save() }
    func clear() { items = []; save() }
    private func save() { UserDefaults.standard.set(items.map(\.path), forKey: "history") }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool {
        if #available(macOS 13.0, *) { return SMAppService.mainApp.status == .enabled }
        return false
    }

    static func set(_ on: Bool) throws {
        if #available(macOS 13.0, *) {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        }
    }
}
