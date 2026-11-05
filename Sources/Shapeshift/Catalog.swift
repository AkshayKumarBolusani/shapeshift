import AppKit

enum WheelKind: Int, CaseIterable {
    case convert, tools, actions
    var title: String { ["Convert", "Tools", "Actions"][rawValue] }
    var color: NSColor {
        switch self {
        case .convert: return NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)
        case .tools: return NSColor(calibratedRed: 0.55, green: 0.35, blue: 0.95, alpha: 1)
        case .actions: return NSColor(calibratedRed: 0.15, green: 0.70, blue: 0.50, alpha: 1)
        }
    }
}

/// One wedge on a wheel.
struct Operation {
    let title: String
    let symbol: String
    /// Runs on files; returns the produced files (may be empty for actions).
    let run: ([URL]) async throws -> [URL]
    /// Actions don't report "Saved…" toasts.
    var silent: Bool = false
}

enum Category {
    case image, svg, audio, video, pdf, document, markdown, slides, sheet, subtitle, archive, folder, other

    static func of(_ url: URL) -> Category {
        if url.isDirectory && url.ext != "rtfd" { return .folder }
        switch url.ext {
        case "jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "avif", "bmp", "gif", "ico", "icns", "jp2", "tga", "psd": return url.ext == "gif" ? .image : .image
        case "svg": return .svg
        case "mp3", "m4a", "wav", "flac", "ogg", "oga", "opus", "aif", "aiff", "wma", "aac", "caf", "alac": return .audio
        case "mp4", "mov", "mkv", "webm", "avi", "wmv", "m4v", "flv", "mpg", "mpeg", "3gp", "ts", "mts": return .video
        case "pdf": return .pdf
        case "docx", "doc", "rtf", "rtfd", "txt", "text", "html", "htm", "odt", "webarchive", "textclipping", "pages", "epub": return .document
        case "md", "markdown": return .markdown
        case "ppt", "pptx", "odp", "key": return .slides
        case "xlsx", "xls", "ods", "csv", "tsv", "numbers": return .sheet
        case "srt", "vtt": return .subtitle
        case "zip", "tar", "gz", "tgz", "rar", "7z", "bz2", "xz", "tbz", "txz": return .archive
        default: return .other
        }
    }

    /// Stable name used to store customization.
    var key: String {
        switch self {
        case .image, .svg: return "image"
        case .audio: return "audio"
        case .video: return "video"
        case .pdf: return "pdf"
        case .document: return "document"
        case .markdown: return "markdown"
        case .slides: return "slides"
        case .sheet: return "sheet"
        case .subtitle: return "subtitle"
        case .archive: return "archive"
        case .folder: return "folder"
        case .other: return "other"
        }
    }
}

enum Catalog {
    /// Wedges for these files, after the user's on/off and order choices.
    static func operations(for files: [URL], kind: WheelKind) -> [Operation] {
        let key = kind == .actions ? "any" : (commonCategory(files)?.key ?? "mixed")
        return Customization.shared.apply(allOperations(for: files, kind: kind), kind: kind, category: key)
    }

    /// Every wedge that could apply, ignoring customization.
    static func allOperations(for files: [URL], kind: WheelKind) -> [Operation] {
        guard !files.isEmpty else { return [] }
        switch kind {
        case .actions: return FileActions.all()
        case .convert: return convert(files)
        case .tools: return tools(files)
        }
    }

    static func commonCategory(_ files: [URL]) -> Category? {
        let cats = Set(files.map { Category.of($0) == .svg ? .image : Category.of($0) })
        return cats.count == 1 ? cats.first : nil
    }

    // MARK: Convert wheel

    private static func convert(_ files: [URL]) -> [Operation] {
        guard let cat = commonCategory(files) else {
            // Mixed selection: archive everything.
            return Archives.createOps()
        }
        let first = files[0]
        switch cat {
        case .image, .svg:
            var outs = ImageOps.outputFormats.filter { $0.ext != first.ext && !($0.ext == "jpg" && first.ext == "jpeg") && !($0.ext == "tiff" && first.ext == "tif") }
            if Tools.cwebp == nil && !ImageOps.canWrite("org.webmproject.webp") { outs.removeAll { $0.ext == "webp" } }
            return outs.map { fmt in each(fmt.ext.uppercased(), "photo") { try await ImageOps.convert($0, to: fmt) } }
        case .audio:
            return MediaOps.audioFormats.filter { $0 != first.ext }.map { f in
                each(f.uppercased(), "waveform") { try await MediaOps.convertAudio($0, to: f) }
            }
        case .video:
            var ops = MediaOps.videoFormats.filter { $0 != first.ext }.map { f in
                each(f.uppercased(), "film") { try await MediaOps.convertVideo($0, to: f) }
            }
            ops.append(each("MP3", "music.note") { try await MediaOps.extractAudio($0, ext: "mp3") })
            ops.append(each("M4A", "music.note") { try await MediaOps.extractAudio($0, ext: "m4a") })
            return ops
        case .pdf:
            var ops: [Operation] = [
                Operation(title: "JPG", symbol: "photo") { try await PDFOps.toImages($0, ext: "jpg") },
                Operation(title: "PNG", symbol: "photo") { try await PDFOps.toImages($0, ext: "png") },
                each("DOCX", "doc.richtext") { try await PDFOps.toDocument($0, ext: "docx") },
                each("TXT", "doc.plaintext") { try await PDFOps.toDocument($0, ext: "txt") },
                each("MD", "number") { try await PDFOps.toDocument($0, ext: "md") },
                each("RTF", "doc.richtext") { try await PDFOps.toDocument($0, ext: "rtf") },
                each("HTML", "chevron.left.forwardslash.chevron.right") { try await PDFOps.toDocument($0, ext: "html") },
                each("EPUB", "book") { try await PDFOps.toDocument($0, ext: "epub") },
                each("ODT", "doc") { try await PDFOps.toDocument($0, ext: "odt") },
            ]
            if Tools.soffice != nil {
                ops.append(each("PPTX", "rectangle.on.rectangle") { try await Office.pdfToSlides($0) })
                ops.append(each("XLSX", "tablecells") { try await Office.convert($0, to: "xlsx", filter: nil, importPDF: true) })
            }
            return ops
        case .document, .markdown:
            return DocOps.outputFormats.filter { $0 != first.ext && !(cat == .markdown && $0 == "md") }.map { f in
                each(f.uppercased(), f == "pdf" ? "doc.text" : "doc") { try await DocOps.convert($0, to: f) }
            }
        case .slides:
            guard Tools.soffice != nil else { return [Operation.info("Install LibreOffice for slides", "rectangle.on.rectangle.slash")] }
            return ["pdf", "pptx", "jpg", "png", "odp"].filter { $0 != first.ext }.map { f in
                each(f.uppercased(), "rectangle.on.rectangle") { try await Office.slides($0, to: f) }
            }
        case .sheet:
            return SheetOps.outputFormats(for: first).map { f in
                each(f.uppercased(), "tablecells") { try await SheetOps.convert($0, to: f) }
            }
        case .subtitle:
            return ["srt", "vtt", "txt"].filter { $0 != first.ext }.map { f in
                each(f.uppercased(), "captions.bubble") { try await SubtitleOps.convert($0, to: f) }
            }
        case .archive:
            return [
                each("Extract", "archivebox") { try await Archives.extract($0) },
                each("ZIP", "doc.zipper") { try await Archives.reArchive($0, to: "zip") },
                each("TAR", "shippingbox") { try await Archives.reArchive($0, to: "tar") },
                each("TAR.GZ", "shippingbox") { try await Archives.reArchive($0, to: "tar.gz") },
            ].filter { !($0.title == "ZIP" && first.ext == "zip") && !($0.title == "TAR" && first.ext == "tar") }
        case .folder, .other:
            return Archives.createOps()
        }
    }

    // MARK: Tools wheel

    private static func tools(_ files: [URL]) -> [Operation] {
        let cat = commonCategory(files)
        var ops: [Operation] = []
        switch cat {
        case .image, .svg:
            ops = ImageOps.tools() + ImageExtras.tools()
            if files.count > 1 {
                ops.insert(Operation(title: "Merge to PDF", symbol: "doc.on.doc") { try await ImageOps.mergeToPDF($0) }, at: 0)
            }
        case .video:
            ops = MediaOps.videoTools() + MediaExtras.videoTools()
            if files.count > 1 { ops.insert(Operation(title: "Merge", symbol: "rectangle.stack") { try await MediaOps.merge($0, video: true) }, at: 0) }
        case .audio:
            ops = MediaOps.audioTools() + MediaExtras.audioTools()
            if files.count > 1 { ops.insert(Operation(title: "Merge", symbol: "rectangle.stack") { try await MediaOps.merge($0, video: false) }, at: 0) }
        case .pdf:
            ops = PDFOps.tools() + PDFExtras.tools()
            if files.count > 1 { ops.insert(Operation(title: "Merge", symbol: "doc.on.doc") { try await PDFOps.merge($0) }, at: 0) }
        case .subtitle:
            ops = [each("Shift timing", "clock.arrow.2.circlepath") { try await SubtitleOps.shift($0) }]
        case .document, .markdown:
            ops = DocOps.tools() + [GeneralTools.readAloud()]
        case .sheet:
            ops = SheetOps.tools()
        default:
            break
        }
        ops += [
            Operation(title: "Compress ZIP", symbol: "doc.zipper") { try await Archives.create($0, format: "zip") },
            GeneralTools.checksum(),
            Operation(title: "Info", symbol: "info.circle", run: { try await Metadata.show($0) }, silent: true),
        ]
        return ops
    }

    /// Wrap a single-file conversion so it applies to every selected file.
    static func each(_ title: String, _ symbol: String, _ f: @escaping (URL) async throws -> URL) -> Operation {
        Operation(title: title, symbol: symbol) { files in
            var out: [URL] = []
            for file in files { out.append(try await f(file)) }
            return out
        }
    }
}

extension Operation {
    static func info(_ text: String, _ symbol: String) -> Operation {
        Operation(title: text, symbol: symbol, run: { _ in
            await MainActor.run { Prompt.showText(title: "Missing engine", text: "\(text).\n\nbrew install --cask libreoffice") }
            return []
        }, silent: true)
    }
}
