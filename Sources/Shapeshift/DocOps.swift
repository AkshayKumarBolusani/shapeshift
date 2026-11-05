import AppKit

enum DocOps {
    static var pagesInstalled: Bool { FileManager.default.fileExists(atPath: "/Applications/Pages.app") }

    static var outputFormats: [String] {
        var f = ["docx", "pdf", "md", "txt", "html", "rtf", "odt", "epub", "doc"]
        if pagesInstalled { f.append("pages") }
        return f
    }

    // MARK: Reading

    @MainActor
    static func read(_ url: URL) throws -> NSAttributedString {
        switch url.ext {
        case "md", "markdown":
            let md = try String(contentsOf: url, encoding: .utf8)
            return try html(Markdown.toHTML(md, title: url.deletingPathExtension().lastPathComponent))
        case "txt", "text":
            let s = try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
            return NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 12)])
        case "textclipping":
            return try readClipping(url)
        case "epub":
            return try html(Epub.readHTML(url))
        case "pages":
            throw OpError("Reading .pages needs Pages; use Pages → File → Export")
        default:
            var attrs: NSDictionary?
            return try NSAttributedString(url: url, options: [:], documentAttributes: &attrs)
        }
    }

    @MainActor
    static func html(_ s: String) throws -> NSAttributedString {
        guard let data = s.data(using: .utf8),
              let a = NSAttributedString(html: data, options: [.characterEncoding: String.Encoding.utf8.rawValue], documentAttributes: nil)
        else { throw OpError("Could not parse HTML") }
        return a
    }

    @MainActor
    private static func readClipping(_ url: URL) throws -> NSAttributedString {
        let data = try Data(contentsOf: url)
        if let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
           let dict = plist["UTI-Data"] as? [String: Any] {
            if let rtf = dict["public.rtf"] as? Data, let a = NSAttributedString(rtf: rtf, documentAttributes: nil) { return a }
            if let s = dict["public.utf8-plain-text"] as? String { return NSAttributedString(string: s) }
            if let d = dict["public.utf8-plain-text"] as? Data { return NSAttributedString(string: String(decoding: d, as: UTF8.self)) }
        }
        throw OpError("Unrecognized text clipping")
    }

    // MARK: Writing

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        if ext == "pages" {
            try await exportViaPages(url, to: out)
            return out
        }
        // Keep Markdown → Markdown-ish exports lossless where possible.
        if url.ext == "md", ext == "html" {
            let md = try String(contentsOf: url, encoding: .utf8)
            try Markdown.toHTML(md, title: url.deletingPathExtension().lastPathComponent).write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        let text = try await MainActor.run { try read(url) }
        try await write(text, to: out, title: url.deletingPathExtension().lastPathComponent)
        return out
    }

    static func write(_ text: NSAttributedString, to out: URL, title: String) async throws {
        try await MainActor.run {
            let range = NSRange(location: 0, length: text.length)
            func save(_ type: NSAttributedString.DocumentType) throws {
                let data = try text.data(from: range, documentAttributes: [.documentType: type])
                try data.write(to: out)
            }
            switch out.ext {
            case "docx": try save(.officeOpenXML)
            case "doc": try save(.docFormat)
            case "odt": try save(.openDocument)
            case "rtf": try save(.rtf)
            case "html": try save(.html)
            case "txt": try text.string.replacingOccurrences(of: "\u{0C}", with: "\n\n").write(to: out, atomically: true, encoding: .utf8)
            case "md": try RichText.markdown(text).write(to: out, atomically: true, encoding: .utf8)
            case "pdf": try printPDF(text, to: out)
            case "epub": try Epub.write(title: title, xhtmlBody: RichText.xhtml(text), to: out)
            default: throw OpError("Unsupported output \(out.ext)")
            }
        }
    }

    @MainActor
    static func printPDF(_ text: NSAttributedString, to url: URL) throws {
        let info = NSPrintInfo(dictionary: [:])
        info.paperSize = NSSize(width: 612, height: 792)
        info.topMargin = 54; info.bottomMargin = 54; info.leftMargin = 60; info.rightMargin = 60
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isHorizontallyCentered = false
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url
        let width = info.paperSize.width - info.leftMargin - info.rightMargin
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 100))
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude)
        tv.textStorage?.setAttributedString(text)
        tv.layoutManager?.ensureLayout(for: tv.textContainer!)
        tv.sizeToFit()
        let op = NSPrintOperation(view: tv, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run(), FileManager.default.fileExists(atPath: url.path) else { throw OpError("PDF export failed") }
    }

    static func exportViaPages(_ url: URL, to out: URL) async throws {
        let script = """
        tell application "Pages"
            set d to open (POSIX file "\(url.path)")
            save d in (POSIX file "\(out.path)")
            close d saving no
        end tell
        """
        try await Shell.run("/usr/bin/osascript", ["-e", script])
    }

    // MARK: Tools

    static func tools() -> [Operation] {
        [
            Catalog.each("Word count", "textformat.123") { url in
                let text = try await MainActor.run { try read(url) }.string
                let words = text.split { $0.isWhitespace || $0.isNewline }.count
                let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
                let mins = max(1, words / 230)
                await MainActor.run {
                    Prompt.showText(title: url.lastPathComponent,
                                    text: "Words: \(words)\nCharacters: \(text.count)\nCharacters (no spaces): \(text.filter { !$0.isWhitespace }.count)\nLines: \(lines)\nReading time: ~\(mins) min")
                }
                return url
            },
            Catalog.each("Plain text", "textformat") { try await convert($0, to: "txt") },
            Catalog.each("Print to PDF", "printer") { try await convert($0, to: "pdf") },
        ]
    }
}

// MARK: - Attributed string → Markdown / XHTML

enum RichText {
    struct Run { var text: String; var bold: Bool; var italic: Bool; var mono: Bool; var link: URL? }
    struct Block { var heading: Int; var bullet: Bool; var runs: [Run] }

    static func blocks(_ s: NSAttributedString) -> [Block] {
        let ns = s.string as NSString
        var blocks: [Block] = []
        // Body size = most common font size.
        var sizes: [CGFloat: Int] = [:]
        s.enumerateAttribute(.font, in: NSRange(location: 0, length: s.length)) { v, r, _ in
            if let f = v as? NSFont { sizes[f.pointSize, default: 0] += r.length }
        }
        let body = sizes.max { $0.value < $1.value }?.key ?? 12
        var pos = 0
        while pos < ns.length {
            let pr = ns.paragraphRange(for: NSRange(location: pos, length: 0))
            pos = NSMaxRange(pr)
            var runs: [Run] = []
            var maxSize: CGFloat = 0
            var allBold = true
            s.enumerateAttributes(in: pr) { attrs, r, _ in
                var t = ns.substring(with: r).replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\u{0C}", with: "").replacingOccurrences(of: "\u{2028}", with: " ")
                if t.isEmpty { return }
                let font = attrs[.font] as? NSFont
                let traits = font.map { NSFontManager.shared.traits(of: $0) } ?? []
                let bold = traits.contains(.boldFontMask)
                if !t.trimmingCharacters(in: .whitespaces).isEmpty { maxSize = max(maxSize, font?.pointSize ?? body); if !bold { allBold = false } }
                let link = (attrs[.link] as? URL) ?? (attrs[.link] as? String).flatMap(URL.init(string:))
                t = t.replacingOccurrences(of: "\t", with: " ")
                runs.append(Run(text: t, bold: bold, italic: traits.contains(.italicFontMask), mono: font?.isFixedPitch ?? false, link: link))
            }
            let plain = runs.map(\.text).joined()
            if plain.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var heading = 0
            if maxSize >= body * 1.6 { heading = 1 } else if maxSize >= body * 1.3 { heading = 2 } else if maxSize > body * 1.05 && allBold { heading = 3 }
            var bullet = false
            if let first = runs.first {
                let trimmed = first.text.drop { $0 == " " }
                if let c = trimmed.first, "•◦▪–-".contains(c) {
                    bullet = true
                    runs[0].text = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
                }
            }
            if heading > 0 { for i in runs.indices { runs[i].bold = false } }
            blocks.append(Block(heading: heading, bullet: bullet, runs: runs))
        }
        return blocks
    }

    static func markdown(_ s: NSAttributedString) -> String {
        let bs = blocks(s)
        let lines: [String] = bs.map { b in
            let inline = b.runs.map { r -> String in
                var t = r.text
                let core = t.trimmingCharacters(in: .whitespaces)
                if core.isEmpty { return t }
                var wrapped = core
                if r.mono { wrapped = "`\(wrapped)`" }
                if r.bold && r.italic { wrapped = "***\(wrapped)***" } else if r.bold { wrapped = "**\(wrapped)**" } else if r.italic { wrapped = "*\(wrapped)*" }
                if let l = r.link { wrapped = "[\(wrapped)](\(l.absoluteString))" }
                t = t.replacingOccurrences(of: core, with: wrapped)
                return t
            }.joined()
            if b.heading > 0 { return String(repeating: "#", count: b.heading) + " " + inline.trimmingCharacters(in: .whitespaces) }
            if b.bullet { return "- " + inline }
            return inline
        }
        var md = ""
        for (i, line) in lines.enumerated() {
            if i > 0 { md += (bs[i].bullet && bs[i - 1].bullet) ? "\n" : "\n\n" }
            md += line
        }
        return md + "\n"
    }

    static func xhtml(_ s: NSAttributedString) -> String {
        var html = ""
        var inList = false
        for b in blocks(s) {
            let inline = b.runs.map { r -> String in
                var t = esc(r.text)
                if r.mono { t = "<code>\(t)</code>" }
                if r.bold { t = "<strong>\(t)</strong>" }
                if r.italic { t = "<em>\(t)</em>" }
                if let l = r.link { t = "<a href=\"\(esc(l.absoluteString))\">\(t)</a>" }
                return t
            }.joined()
            if b.bullet && !inList { html += "<ul>\n"; inList = true }
            if !b.bullet && inList { html += "</ul>\n"; inList = false }
            if b.bullet { html += "<li>\(inline)</li>\n" }
            else if b.heading > 0 { html += "<h\(b.heading)>\(inline)</h\(b.heading)>\n" }
            else { html += "<p>\(inline)</p>\n" }
        }
        if inList { html += "</ul>\n" }
        return html
    }

    static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

// MARK: - Minimal Markdown → HTML

enum Markdown {
    static func toHTML(_ md: String, title: String) -> String {
        var out = ""
        var para: [String] = []
        var listType: String?
        var inCode = false
        func flush() {
            if !para.isEmpty { out += "<p>\(inline(para.joined(separator: " ")))</p>\n"; para = [] }
        }
        func closeList() { if let t = listType { out += "</\(t)>\n"; listType = nil } }
        for raw in md.components(separatedBy: .newlines) {
            let line = raw
            if line.hasPrefix("```") {
                flush(); closeList()
                out += inCode ? "</code></pre>\n" : "<pre><code>"
                inCode.toggle(); continue
            }
            if inCode { out += RichText.esc(line) + "\n"; continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.isEmpty { flush(); closeList(); continue }
            if let m = t.range(of: "^#{1,6} ", options: .regularExpression) {
                flush(); closeList()
                let level = t[m].count - 1
                out += "<h\(level)>\(inline(String(t[m.upperBound...])))</h\(level)>\n"; continue
            }
            if t == "---" || t == "***" { flush(); closeList(); out += "<hr/>\n"; continue }
            if t.hasPrefix("> ") { flush(); closeList(); out += "<blockquote><p>\(inline(String(t.dropFirst(2))))</p></blockquote>\n"; continue }
            if let m = t.range(of: "^([-*+]|\\d+\\.) ", options: .regularExpression) {
                flush()
                let type = t[m].first!.isNumber ? "ol" : "ul"
                if listType != type { closeList(); out += "<\(type)>\n"; listType = type }
                out += "<li>\(inline(String(t[m.upperBound...])))</li>\n"; continue
            }
            closeList()
            para.append(t)
        }
        flush(); closeList()
        if inCode { out += "</code></pre>\n" }
        return """
        <!DOCTYPE html><html><head><meta charset="utf-8"><title>\(RichText.esc(title))</title>
        <style>body{font-family:-apple-system,Helvetica,sans-serif;font-size:12pt;line-height:1.5;max-width:46em;margin:2em auto}code,pre{font-family:Menlo,monospace;font-size:10.5pt}pre{background:#f4f4f4;padding:8px}</style>
        </head><body>
        \(out)</body></html>
        """
    }

    static func inline(_ s: String) -> String {
        var t = RichText.esc(s)
        let rules: [(String, String)] = [
            ("`([^`]+)`", "<code>$1</code>"),
            ("!\\[([^\\]]*)\\]\\(([^)]+)\\)", "<img alt=\"$1\" src=\"$2\"/>"),
            ("\\[([^\\]]+)\\]\\(([^)]+)\\)", "<a href=\"$2\">$1</a>"),
            ("\\*\\*\\*([^*]+)\\*\\*\\*", "<strong><em>$1</em></strong>"),
            ("\\*\\*([^*]+)\\*\\*", "<strong>$1</strong>"),
            ("__([^_]+)__", "<strong>$1</strong>"),
            ("\\*([^*]+)\\*", "<em>$1</em>"),
            ("~~([^~]+)~~", "<del>$1</del>"),
        ]
        for (p, r) in rules { t = t.replacingOccurrences(of: p, with: r, options: .regularExpression) }
        return t
    }
}

// MARK: - EPUB

enum Epub {
    static func write(title: String, xhtmlBody: String, to out: URL) throws {
        let dir = try Paths.tempDir().appendingPathComponent("book")
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("META-INF"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("OEBPS"), withIntermediateDirectories: true)
        let t = RichText.esc(title)
        let id = UUID().uuidString
        try "application/epub+zip".write(to: dir.appendingPathComponent("mimetype"), atomically: true, encoding: .ascii)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
        <rootfiles><rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/></rootfiles></container>
        """.write(to: dir.appendingPathComponent("META-INF/container.xml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <package xmlns="http://www.idpf.org/2007/opf" version="3.0" unique-identifier="bookid">
        <metadata xmlns:dc="http://purl.org/dc/elements/1.1/"><dc:identifier id="bookid">urn:uuid:\(id)</dc:identifier>
        <dc:title>\(t)</dc:title><dc:language>en</dc:language><meta property="dcterms:modified">\(ISO8601DateFormatter().string(from: Date()).prefix(19))Z</meta></metadata>
        <manifest><item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>
        <item id="c1" href="chapter.xhtml" media-type="application/xhtml+xml"/></manifest>
        <spine><itemref idref="c1"/></spine></package>
        """.write(to: dir.appendingPathComponent("OEBPS/content.opf"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"><head><title>\(t)</title></head>
        <body><nav epub:type="toc"><ol><li><a href="chapter.xhtml">\(t)</a></li></ol></nav></body></html>
        """.write(to: dir.appendingPathComponent("OEBPS/nav.xhtml"), atomically: true, encoding: .utf8)
        try """
        <?xml version="1.0" encoding="UTF-8"?><!DOCTYPE html>
        <html xmlns="http://www.w3.org/1999/xhtml"><head><title>\(t)</title></head><body>
        \(xhtmlBody)</body></html>
        """.write(to: dir.appendingPathComponent("OEBPS/chapter.xhtml"), atomically: true, encoding: .utf8)
        try Shell.runZip(in: dir, args: ["-X0", out.path, "mimetype"])
        try Shell.runZip(in: dir, args: ["-rX9", out.path, "META-INF", "OEBPS"])
    }

    /// Concatenate the spine's chapters into one HTML document.
    static func readHTML(_ url: URL) throws -> String {
        let dir = try Paths.tempDir()
        try Shell.runSync("/usr/bin/unzip", ["-q", "-o", url.path, "-d", dir.path])
        let container = try String(contentsOf: dir.appendingPathComponent("META-INF/container.xml"), encoding: .utf8)
        guard let r = container.range(of: "full-path=\"([^\"]+)\"", options: .regularExpression) else { throw OpError("Invalid EPUB") }
        let opfPath = String(container[r].dropFirst(11).dropLast())
        let opfURL = dir.appendingPathComponent(opfPath)
        let opf = try String(contentsOf: opfURL, encoding: .utf8)
        var manifest: [String: String] = [:]
        let itemRe = try NSRegularExpression(pattern: "<item\\b[^>]*>")
        for m in itemRe.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)) {
            let tag = String(opf[Range(m.range, in: opf)!])
            if let id = attr(tag, "id"), let href = attr(tag, "href") { manifest[id] = href }
        }
        let refRe = try NSRegularExpression(pattern: "<itemref\\b[^>]*idref=\"([^\"]+)\"")
        var body = ""
        for m in refRe.matches(in: opf, range: NSRange(opf.startIndex..., in: opf)) {
            let idref = String(opf[Range(m.range(at: 1), in: opf)!])
            guard let href = manifest[idref]?.removingPercentEncoding else { continue }
            let file = opfURL.deletingLastPathComponent().appendingPathComponent(href)
            guard let html = try? String(contentsOf: file, encoding: .utf8) else { continue }
            if let b = html.range(of: "<body[^>]*>", options: .regularExpression), let e = html.range(of: "</body>") {
                body += String(html[b.upperBound..<e.lowerBound])
            }
        }
        return "<html><head><meta charset=\"utf-8\"></head><body>\(body)</body></html>"
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let r = tag.range(of: "\\b\(name)=\"([^\"]*)\"", options: .regularExpression) else { return nil }
        return String(tag[r].dropFirst(name.count + 2).dropLast())
    }
}

extension Shell {
    static func runZip(in dir: URL, args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        p.arguments = ["-q"] + args
        p.currentDirectoryURL = dir
        try p.run(); p.waitUntilExit()
        if p.terminationStatus != 0 { throw OpError("zip failed") }
    }
}
