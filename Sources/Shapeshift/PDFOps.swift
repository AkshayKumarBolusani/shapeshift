import AppKit
import PDFKit

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw OpError("Could not open PDF") }
        if doc.isLocked { throw OpError("This PDF is password-protected") }
        return doc
    }

    /// Every page rendered at the chosen DPI. One page → one file; many pages → a folder.
    static func toImages(_ urls: [URL], ext: String) async throws -> [URL] {
        var results: [URL] = []
        for url in urls {
            let doc = try open(url)
            let dpi = Settings.shared.pdfDPI
            let fmt = ImageOps.outputFormats.first { $0.ext == ext }!
            if doc.pageCount == 1, let page = doc.page(at: 0) {
                let out = Paths.output(for: url, ext: ext)
                try ImageOps.write(render(page, dpi: dpi), to: out, uti: fmt.uti)
                results.append(out)
                continue
            }
            let folder = Paths.outputFolder(for: url, suffix: ext.uppercased())
            let base = url.deletingPathExtension().lastPathComponent
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let out = folder.appendingPathComponent(String(format: "%@ page %03d.%@", base, i + 1, ext))
                try ImageOps.write(render(page, dpi: dpi), to: out, uti: fmt.uti)
            }
            results.append(folder)
        }
        return results
    }

    static func render(_ page: PDFPage, dpi: Double) -> CGImage {
        let box = page.bounds(for: .mediaBox)
        let scale = dpi / 72
        let w = Int(box.width * scale), h = Int(box.height * scale)
        return ImageOps.render(width: w, height: h) { ctx in
            ctx.setFillColor(.white)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            ctx.scaleBy(x: scale, y: scale)
            page.draw(with: .mediaBox, to: ctx)
        }
    }

    /// Rich text of every page, with page breaks between them.
    static func attributedText(_ doc: PDFDocument) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            if let a = page.attributedString { result.append(a) } else if let s = page.string { result.append(NSAttributedString(string: s)) }
            if i < doc.pageCount - 1 { result.append(NSAttributedString(string: "\n\u{0C}")) }
        }
        return result
    }

    static func toDocument(_ url: URL, ext: String) async throws -> URL {
        let doc = try open(url)
        let text = attributedText(doc)
        if text.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw OpError("This PDF has no selectable text (it may be a scan)")
        }
        let out = Paths.output(for: url, ext: ext)
        if ext == "md" {
            var md = ""
            for i in 0..<doc.pageCount {
                md += "## Page \(i + 1)\n\n" + (doc.page(at: i)?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines) + "\n\n"
            }
            try md.write(to: out, atomically: true, encoding: .utf8)
            return out
        }
        try await DocOps.write(text, to: out, title: url.deletingPathExtension().lastPathComponent)
        return out
    }

    // MARK: Tools

    static func tools() -> [Operation] {
        [
            Catalog.each("Compress", "arrow.down.right.and.arrow.up.left") { url in
                let doc = try open(url)
                let out = Paths.output(for: url, ext: "pdf", suffix: "compressed")
                var opts: [PDFDocumentWriteOption: Any] = [:]
                if #available(macOS 13.4, *) {
                    opts[.saveImagesAsJPEGOption] = true
                    opts[.optimizeImagesForScreenOption] = true
                }
                guard doc.write(to: out, withOptions: opts) else { throw OpError("Could not write PDF") }
                return out
            },
            Catalog.each("Split pages", "square.split.2x1") { url in
                let doc = try open(url)
                let folder = Paths.outputFolder(for: url, suffix: "pages")
                let base = url.deletingPathExtension().lastPathComponent
                for i in 0..<doc.pageCount {
                    let single = PDFDocument()
                    if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
                    single.write(to: folder.appendingPathComponent(String(format: "%@ page %03d.pdf", base, i + 1)))
                }
                return folder
            },
            Catalog.each("Extract pages…", "doc.on.doc") { url in
                let doc = try open(url)
                let vals = await MainActor.run {
                    Prompt.ask(title: "Extract pages", message: "\(doc.pageCount) pages. Example: 1-3, 5, 8-10", fields: [("Pages", "1-3, 5", "1")])
                }
                guard let spec = vals?.first, !spec.isEmpty else { throw CancellationError() }
                let pages = parseRanges(spec, max: doc.pageCount)
                guard !pages.isEmpty else { throw OpError("No valid pages in \"\(spec)\"") }
                let outDoc = PDFDocument()
                for (n, p) in pages.enumerated() { if let page = doc.page(at: p - 1)?.copy() as? PDFPage { outDoc.insert(page, at: n) } }
                let out = Paths.output(for: url, ext: "pdf", suffix: "pages \(spec.replacingOccurrences(of: " ", with: ""))")
                outDoc.write(to: out)
                return out
            },
            Catalog.each("Rotate", "rotate.right") { url in
                let doc = try open(url)
                for i in 0..<doc.pageCount { if let p = doc.page(at: i) { p.rotation = (p.rotation + 90) % 360 } }
                let out = Paths.output(for: url, ext: "pdf", suffix: "rotated")
                doc.write(to: out)
                return out
            },
            Catalog.each("Reverse", "arrow.up.arrow.down") { url in
                let doc = try open(url)
                let outDoc = PDFDocument()
                for i in (0..<doc.pageCount).reversed() { if let p = doc.page(at: i)?.copy() as? PDFPage { outDoc.insert(p, at: outDoc.pageCount) } }
                let out = Paths.output(for: url, ext: "pdf", suffix: "reversed")
                outDoc.write(to: out)
                return out
            },
            Catalog.each("Password…", "lock") { url in
                let doc = try open(url)
                let vals = await MainActor.run { Prompt.ask(title: "Protect PDF", message: "Readers will need this password to open it.", fields: [("Password", "", "")], secure: true) }
                guard let pw = vals?.first, !pw.isEmpty else { throw CancellationError() }
                let out = Paths.output(for: url, ext: "pdf", suffix: "protected")
                guard doc.write(to: out, withOptions: [.userPasswordOption: pw, .ownerPasswordOption: pw]) else { throw OpError("Could not write PDF") }
                return out
            },
            Catalog.each("Flatten", "square.3.layers.3d.down.right") { url in
                // Rasterize each page (removes forms, annotations, hidden text).
                let doc = try open(url)
                let out = Paths.output(for: url, ext: "pdf", suffix: "flattened")
                var box = CGRect(x: 0, y: 0, width: 612, height: 792)
                guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw OpError("Could not create PDF") }
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    var b = page.bounds(for: .mediaBox); b.origin = .zero
                    let img = render(page, dpi: 200)
                    ctx.beginPage(mediaBox: &b); ctx.draw(img, in: b); ctx.endPage()
                }
                ctx.closePDF()
                return out
            },
        ]
    }

    static func merge(_ urls: [URL]) async throws -> [URL] {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let outDoc = PDFDocument()
        for url in sorted {
            let doc = try open(url)
            for i in 0..<doc.pageCount { if let p = doc.page(at: i)?.copy() as? PDFPage { outDoc.insert(p, at: outDoc.pageCount) } }
        }
        let out = Paths.output(for: sorted[0], ext: "pdf", suffix: "merged")
        guard outDoc.write(to: out) else { throw OpError("Could not write merged PDF") }
        return [out]
    }

    static func parseRanges(_ s: String, max: Int) -> [Int] {
        var pages: [Int] = []
        for part in s.split(separator: ",") {
            let bits = part.split(separator: "-").map { Int($0.trimmingCharacters(in: .whitespaces)) }
            if bits.count == 1, let a = bits[0], (1...max).contains(a) { pages.append(a) }
            if bits.count == 2, let a = bits[0], let b = bits[1], a <= b {
                pages += (a...b).filter { (1...max).contains($0) }
            }
        }
        return pages
    }
}
