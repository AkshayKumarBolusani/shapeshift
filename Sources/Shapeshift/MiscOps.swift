import AppKit
import ImageIO
import PDFKit

// MARK: - Subtitles

enum SubtitleOps {
    struct Cue { var start: Double; var end: Double; var text: String }

    static func parse(_ url: URL) throws -> [Cue] {
        let s = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
        var cues: [Cue] = []
        let blocks = s.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        for b in blocks {
            let lines = b.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let ti = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[ti].components(separatedBy: "-->")
            guard parts.count == 2, let a = time(parts[0]), let e = time(parts[1].split(separator: " ").first.map(String.init) ?? "") else { continue }
            cues.append(Cue(start: a, end: e, text: lines[(ti + 1)...].joined(separator: "\n")))
        }
        return cues
    }

    static func time(_ s: String) -> Double? {
        let t = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        return parseTime(t)
    }

    static func stamp(_ t: Double, sep: String) -> String {
        let ms = Int((t * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, (ms / 60000) % 60, (ms / 1000) % 60, sep, ms % 1000)
    }

    static func render(_ cues: [Cue], ext: String) -> String {
        switch ext {
        case "srt": return cues.enumerated().map { "\($0 + 1)\n\(stamp($1.start, sep: ",")) --> \(stamp($1.end, sep: ","))\n\($1.text)\n" }.joined(separator: "\n")
        case "vtt": return "WEBVTT\n\n" + cues.map { "\(stamp($0.start, sep: ".")) --> \(stamp($0.end, sep: "."))\n\($0.text)\n" }.joined(separator: "\n")
        default: return cues.map { $0.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }.joined(separator: "\n") + "\n"
        }
    }

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let cues = try parse(url)
        guard !cues.isEmpty else { throw OpError("No subtitle cues found") }
        let out = Paths.output(for: url, ext: ext)
        try render(cues, ext: ext).write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func shift(_ url: URL) async throws -> URL {
        let vals = await MainActor.run { Prompt.ask(title: "Shift subtitles", message: "Seconds to shift (negative = earlier).", fields: [("Offset", "1.5", "1.0")]) }
        guard let v = vals?.first, let off = Double(v) else { throw CancellationError() }
        let cues = try parse(url).map { Cue(start: max(0, $0.start + off), end: max(0, $0.end + off), text: $0.text) }
        let out = Paths.output(for: url, ext: url.ext, suffix: "shifted")
        try render(cues, ext: url.ext).write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

// MARK: - Archives

enum Archives {
    static func createOps() -> [Operation] {
        [
            Operation(title: "ZIP", symbol: "doc.zipper") { try await create($0, format: "zip") },
            Operation(title: "TAR", symbol: "shippingbox") { try await create($0, format: "tar") },
            Operation(title: "TAR.GZ", symbol: "shippingbox.fill") { try await create($0, format: "tar.gz") },
            Operation(title: "GZIP", symbol: "arrow.down.doc") { urls in
                var out: [URL] = []
                for u in urls where !u.isDirectory {
                    let o = Paths.unique(Paths.outputDirectory(for: u).appendingPathComponent(u.lastPathComponent + ".gz"))
                    try await Shell.run("/bin/sh", ["-c", "/usr/bin/gzip -c -9 \"$1\" > \"$2\"", "sh", u.path, o.path])
                    out.append(o)
                }
                if out.isEmpty { throw OpError("GZIP works on files, not folders. Use TAR.GZ.") }
                return out
            },
        ]
    }

    static func create(_ urls: [URL], format: String) async throws -> [URL] {
        let first = urls[0]
        let parent = first.deletingLastPathComponent()
        let name = urls.count == 1 ? first.deletingPathExtension().lastPathComponent : "Archive"
        let out = Paths.unique(Paths.outputDirectory(for: first).appendingPathComponent("\(name).\(format)"))
        let names = urls.map { $0.lastPathComponent }
        switch format {
        case "zip":
            if urls.count == 1 {
                try await Shell.run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", first.path, out.path])
            } else {
                try await Shell.run("/usr/bin/zip", ["-qry", out.path] + names, cwd: parent)
            }
        case "tar": try await Shell.run("/usr/bin/tar", ["-cf", out.path, "-C", parent.path] + names)
        default: try await Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", parent.path] + names)
        }
        return [out]
    }

    static func extract(_ url: URL) async throws -> URL {
        let folder = Paths.unique(Paths.outputDirectory(for: url).appendingPathComponent(baseName(url), isDirectory: true))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if url.ext == "gz" && !url.lastPathComponent.lowercased().hasSuffix(".tar.gz") {
            // Plain gzip of a single file.
            let target = folder.appendingPathComponent(url.deletingPathExtension().lastPathComponent)
            try await Shell.run("/bin/sh", ["-c", "/usr/bin/gzip -dc \"$1\" > \"$2\"", "sh", url.path, target.path])
        } else {
            // bsdtar reads zip, tar, gz, bz2, xz, rar, 7z.
            try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", folder.path])
        }
        return folder
    }

    static func reArchive(_ url: URL, to format: String) async throws -> URL {
        let tmp = try Paths.tempDir()
        try await Shell.run("/usr/bin/tar", ["-xf", url.path, "-C", tmp.path])
        let out = Paths.unique(Paths.outputDirectory(for: url).appendingPathComponent("\(baseName(url)).\(format)"))
        let items = try FileManager.default.contentsOfDirectory(atPath: tmp.path)
        switch format {
        case "zip": try await Shell.run("/usr/bin/zip", ["-qry", out.path] + items, cwd: tmp)
        case "tar": try await Shell.run("/usr/bin/tar", ["-cf", out.path, "-C", tmp.path] + items)
        default: try await Shell.run("/usr/bin/tar", ["-czf", out.path, "-C", tmp.path] + items)
        }
        return out
    }

    static func baseName(_ url: URL) -> String {
        var n = url.lastPathComponent
        for suffix in [".tar.gz", ".tar.bz2", ".tar.xz", ".tgz", ".tbz", ".txz", ".zip", ".tar", ".gz", ".rar", ".7z", ".bz2", ".xz"] where n.lowercased().hasSuffix(suffix) {
            n = String(n.dropLast(suffix.count)); break
        }
        return n
    }
}

// MARK: - LibreOffice (optional)

enum Office {
    static func run(_ args: [String]) async throws {
        guard let so = Tools.soffice else { throw OpError("LibreOffice is not installed: brew install --cask libreoffice") }
        try await Shell.run(so, ["--headless", "--norestore"] + args)
    }

    static func convert(_ url: URL, to ext: String, filter: String?, importPDF: Bool = false) async throws -> URL {
        let tmp = try Paths.tempDir()
        var args: [String] = []
        if importPDF { args += ["--infilter=impress_pdf_import"] }
        args += ["--convert-to", filter.map { "\(ext):\($0)" } ?? ext, "--outdir", tmp.path, url.path]
        try await run(args)
        let produced = tmp.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "." + ext)
        guard FileManager.default.fileExists(atPath: produced.path) else { throw OpError("LibreOffice produced no output") }
        let out = Paths.output(for: url, ext: ext)
        try FileManager.default.moveItem(at: produced, to: out)
        return out
    }

    static func pdfToSlides(_ url: URL) async throws -> URL {
        try await convert(url, to: "pptx", filter: "Impress MS PowerPoint 2007 XML", importPDF: true)
    }

    static func slides(_ url: URL, to ext: String) async throws -> URL {
        if ext == "jpg" || ext == "png" {
            // Slides → PDF → one image per slide.
            let tmpPDF = try await convert(url, to: "pdf", filter: nil)
            defer { try? FileManager.default.removeItem(at: tmpPDF) }
            let res = try await PDFOps.toImages([tmpPDF], ext: ext)
            return res.first ?? tmpPDF
        }
        return try await convert(url, to: ext, filter: nil)
    }
}

// MARK: - Metadata / Info

enum Metadata {
    static func show(_ urls: [URL]) async throws -> [URL] {
        var text = ""
        for url in urls {
            text += "━━ \(url.lastPathComponent) ━━\n"
            let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
            if let size = attrs[.size] as? Int64 { text += "Size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))\n" }
            if let d = attrs[.creationDate] as? Date { text += "Created: \(d)\n" }
            if let d = attrs[.modificationDate] as? Date { text += "Modified: \(d)\n" }
            text += "Path: \(url.path)\n\n"
            switch Category.of(url) {
            case .image:
                if let src = CGImageSourceCreateWithURL(url as CFURL, nil), let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                    text += describe(p, indent: "")
                }
            case .audio, .video:
                if let probe = Tools.ffprobe {
                    text += (try? await Shell.run(probe, ["-v", "error", "-show_format", "-show_streams", "-of", "flat", url.path])) ?? ""
                }
            case .pdf:
                if let doc = PDFOps.optionalDoc(url) {
                    text += "Pages: \(doc.pageCount)\n"
                    for (k, v) in doc.documentAttributes ?? [:] { text += "\(k): \(v)\n" }
                }
            default:
                text += (try? await Shell.run("/usr/bin/mdls", [url.path])) ?? ""
            }
            text += "\n"
        }
        let t = text
        await MainActor.run { Prompt.showText(title: urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files", text: t) }
        return []
    }

    private static func describe(_ d: [String: Any], indent: String) -> String {
        d.keys.sorted().map { k in
            if let sub = d[k] as? [String: Any] { return "\(indent)\(k):\n" + describe(sub, indent: indent + "  ") }
            return "\(indent)\(k): \(d[k]!)\n"
        }.joined()
    }
}

extension PDFOps {
    static func optionalDoc(_ url: URL) -> PDFDocument? { PDFDocument(url: url) }
}
