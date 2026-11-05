import AppKit
import Foundation

// MARK: - Errors

struct OpError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - External tools

enum Tools {
    private static let searchDirs = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin",
                                     "/Applications/LibreOffice.app/Contents/MacOS"]
    private static var cache: [String: String?] = [:]
    private static let lock = NSLock()

    static func path(_ name: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let cached = cache[name] { return cached }
        let found = searchDirs.map { "\($0)/\(name)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
        cache[name] = found
        return found
    }

    static func refresh() { lock.lock(); cache = [:]; lock.unlock() }

    static var ffmpeg: String? { path("ffmpeg") }
    static var ffprobe: String? { path("ffprobe") }
    static var cwebp: String? { path("cwebp") }
    static var soffice: String? { path("soffice") }
    static var hasFFmpeg: Bool { ffmpeg != nil }
}

// MARK: - Process runner

enum Shell {
    @discardableResult
    static func run(_ exe: String, _ args: [String], cwd: URL? = nil) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: exe)
                p.arguments = args
                if let cwd { p.currentDirectoryURL = cwd }
                let out = Pipe(), err = Pipe()
                p.standardOutput = out
                p.standardError = err
                p.standardInput = FileHandle.nullDevice
                var outData = Data(), errData = Data()
                let group = DispatchGroup()
                group.enter(); DispatchQueue.global().async { outData = out.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                group.enter(); DispatchQueue.global().async { errData = err.fileHandleForReading.readDataToEndOfFile(); group.leave() }
                do { try p.run() } catch { cont.resume(throwing: error); return }
                p.waitUntilExit()
                group.wait()
                let o = String(decoding: outData, as: UTF8.self)
                if p.terminationStatus == 0 {
                    cont.resume(returning: o)
                } else {
                    let e = String(decoding: errData, as: UTF8.self)
                    let tail = e.split(separator: "\n").suffix(4).joined(separator: "\n")
                    cont.resume(throwing: OpError("\((exe as NSString).lastPathComponent) failed: \(tail.isEmpty ? o : tail)"))
                }
            }
        }
    }

    static func runSync(_ exe: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw OpError("\((exe as NSString).lastPathComponent) failed: \(String(decoding: data, as: UTF8.self).suffix(300))")
        }
    }

    static func ffmpeg(_ args: [String]) async throws {
        guard let ff = Tools.ffmpeg else { throw OpError("ffmpeg is not installed. Run: brew install ffmpeg") }
        try await run(ff, ["-hide_banner", "-loglevel", "error", "-y"] + args)
    }
}

// MARK: - Output paths

enum Paths {
    static func outputDirectory(for input: URL) -> URL {
        let input = input.realFileURL
        switch Settings.shared.outputLocation {
        case .besideOriginal: return input.deletingLastPathComponent()
        case .downloads: return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .custom:
            if let p = Settings.shared.customOutputPath, !p.isEmpty { return URL(fileURLWithPath: p) }
            return input.deletingLastPathComponent()
        }
    }

    /// e.g. photo.heic -> photo.png (or "photo (compressed).jpg"), never overwriting.
    static func output(for input: URL, ext: String, suffix: String? = nil) -> URL {
        let input = input.realFileURL
        let dir = outputDirectory(for: input)
        var base = input.deletingPathExtension().lastPathComponent
        if input.pathExtension.lowercased() == "gz", base.lowercased().hasSuffix(".tar") {
            base = String(base.dropLast(4))
        }
        if let suffix { base += " (\(suffix))" }
        return unique(dir.appendingPathComponent(base).appendingPathExtension(ext))
    }

    static func outputFolder(for input: URL, suffix: String) -> URL {
        let input = input.realFileURL
        let dir = outputDirectory(for: input)
        let base = input.deletingPathExtension().lastPathComponent + " (\(suffix))"
        let url = unique(dir.appendingPathComponent(base, isDirectory: true))
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let ext = url.pathExtension
        let base = url.deletingPathExtension().lastPathComponent
        var i = 2
        while true {
            var candidate = dir.appendingPathComponent("\(base) \(i)")
            if !ext.isEmpty { candidate.appendPathExtension(ext) }
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }

    static func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shapeshift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

extension URL {
    /// Finder drags can carry file-reference URLs (/.file/id=…). Turn them into real paths
    /// so "beside the original" really means the source file's folder.
    var realFileURL: URL {
        if let u = (self as NSURL).filePathURL { return u.standardizedFileURL.resolvingSymlinksInPath() }
        return standardizedFileURL
    }
    var ext: String { pathExtension.lowercased() }
    var isDirectory: Bool { (try? resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false }
}

// MARK: - Small modal prompts (main thread)

enum Prompt {
    /// Ask for one or more text values. Returns nil if cancelled.
    @MainActor
    static func ask(title: String, message: String, fields: [(label: String, placeholder: String, value: String)], secure: Bool = false) -> [String]? {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        var inputs: [NSTextField] = []
        for f in fields {
            let label = NSTextField(labelWithString: f.label)
            label.font = .systemFont(ofSize: 11)
            let tf: NSTextField = secure ? NSSecureTextField() : NSTextField()
            tf.placeholderString = f.placeholder
            tf.stringValue = f.value
            tf.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
            tf.widthAnchor.constraint(equalToConstant: 260).isActive = true
            stack.addArrangedSubview(label)
            stack.addArrangedSubview(tf)
            inputs.append(tf)
        }
        stack.frame = NSRect(x: 0, y: 0, width: 260, height: CGFloat(fields.count) * 48)
        alert.accessoryView = stack
        alert.window.initialFirstResponder = inputs.first
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return inputs.map { $0.stringValue.trimmingCharacters(in: .whitespaces) }
    }

    @MainActor
    static func showText(title: String, text: String) {
        NSApp.activate(ignoringOtherApps: true)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                           styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        win.title = title
        win.isReleasedWhenClosed = false
        let scroll = NSTextView.scrollableTextView()
        let tv = scroll.documentView as! NSTextView
        tv.isEditable = false
        tv.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        tv.string = text
        win.contentView = scroll
        win.center()
        win.makeKeyAndOrderFront(nil)
        WindowKeeper.keep(win)
    }
}

/// Keeps ad-hoc windows alive until closed.
enum WindowKeeper {
    private static var windows: [NSWindow] = []
    @MainActor static func keep(_ w: NSWindow) {
        windows.append(w)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { n in
            if let win = n.object as? NSWindow { windows.removeAll { $0 === win } }
        }
    }
}

/// Parse "90", "1:30", "01:02:03.5" into seconds.
func parseTime(_ s: String) -> Double? {
    let parts = s.split(separator: ":").map { Double($0) }
    guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
    return parts.compactMap { $0 }.reduce(0) { $0 * 60 + $1 }
}
