import AppKit

typealias Table = [[String]]

enum SheetOps {
    static func outputFormats(for url: URL) -> [String] {
        var f = ["xlsx", "csv", "tsv", "json", "html", "md", "pdf"]
        if Tools.soffice != nil { f += ["ods", "xls"] }
        return f.filter { $0 != url.ext }
    }

    // MARK: Read

    static func read(_ url: URL) async throws -> Table {
        switch url.ext {
        case "csv": return CSV.parse(try text(url), sep: ",")
        case "tsv": return CSV.parse(try text(url), sep: "\t")
        case "xlsx": return try XLSX.read(url)
        default:
            // xls / ods / numbers → csv through LibreOffice.
            guard Tools.soffice != nil else { throw OpError("Reading .\(url.ext) needs LibreOffice: brew install --cask libreoffice") }
            let tmp = try Paths.tempDir()
            try await Office.run(["--convert-to", "csv", "--outdir", tmp.path, url.path])
            let csv = tmp.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".csv")
            return CSV.parse(try text(csv), sep: ",")
        }
    }

    private static func text(_ url: URL) throws -> String {
        try (try? String(contentsOf: url, encoding: .utf8)) ?? String(contentsOf: url, encoding: .isoLatin1)
    }

    // MARK: Convert

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        if ext == "ods" || ext == "xls" {
            let tmp = try Paths.tempDir()
            try await Office.run(["--convert-to", ext, "--outdir", tmp.path, url.path])
            let produced = tmp.appendingPathComponent(url.deletingPathExtension().lastPathComponent + "." + ext)
            try FileManager.default.moveItem(at: produced, to: out)
            return out
        }
        let table = try await read(url)
        try await write(table, to: out, title: url.deletingPathExtension().lastPathComponent)
        return out
    }

    static func write(_ t: Table, to out: URL, title: String) async throws {
        switch out.ext {
        case "csv": try CSV.write(t, sep: ",").write(to: out, atomically: true, encoding: .utf8)
        case "tsv": try CSV.write(t, sep: "\t").write(to: out, atomically: true, encoding: .utf8)
        case "xlsx": try XLSX.write(t, to: out)
        case "json":
            guard let header = t.first else { try "[]".write(to: out, atomically: true, encoding: .utf8); return }
            let rows = t.dropFirst().map { row in
                Dictionary(uniqueKeysWithValues: header.enumerated().map { (i, k) in (k.isEmpty ? "column\(i + 1)" : k, i < row.count ? row[i] : "") })
            }
            let data = try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: out)
        case "md":
            guard let header = t.first else { return }
            let w = t.map(\.count).max() ?? 0
            func row(_ r: [String]) -> String { "| " + (0..<w).map { i in i < r.count ? r[i].replacingOccurrences(of: "|", with: "\\|") : "" }.joined(separator: " | ") + " |" }
            let md = ([row(header), "|" + String(repeating: " --- |", count: w)] + t.dropFirst().map(row)).joined(separator: "\n") + "\n"
            try md.write(to: out, atomically: true, encoding: .utf8)
        case "html": try htmlTable(t, title: title).write(to: out, atomically: true, encoding: .utf8)
        case "pdf":
            let html = htmlTable(t, title: title)
            try await MainActor.run {
                let a = try DocOps.html(html)
                try DocOps.printPDF(a, to: out)
            }
        default: throw OpError("Unsupported output \(out.ext)")
        }
    }

    static func htmlTable(_ t: Table, title: String) -> String {
        var h = "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>\(RichText.esc(title))</title><style>table{border-collapse:collapse;font:10pt -apple-system,Helvetica}td,th{border:1px solid #999;padding:3px 6px}th{background:#eee}</style></head><body><table>\n"
        for (i, r) in t.enumerated() {
            let tag = i == 0 ? "th" : "td"
            h += "<tr>" + r.map { "<\(tag)>\(RichText.esc($0))</\(tag)>" }.joined() + "</tr>\n"
        }
        return h + "</table></body></html>"
    }

    static func tools() -> [Operation] {
        [
            Catalog.each("Transpose", "arrow.triangle.swap") { url in
                let t = try await read(url)
                let w = t.map(\.count).max() ?? 0
                let tr = (0..<w).map { c in t.map { c < $0.count ? $0[c] : "" } }
                let ext = ["csv", "tsv", "xlsx"].contains(url.ext) ? url.ext : "xlsx"
                let out = Paths.output(for: url, ext: ext, suffix: "transposed")
                try await write(tr, to: out, title: url.lastPathComponent)
                return out
            },
            Catalog.each("Remove duplicates", "line.3.horizontal.decrease") { url in
                let t = try await read(url)
                var seen = Set<[String]>()
                let unique = t.filter { seen.insert($0).inserted }
                let ext = ["csv", "tsv", "xlsx"].contains(url.ext) ? url.ext : "xlsx"
                let out = Paths.output(for: url, ext: ext, suffix: "deduplicated")
                try await write(unique, to: out, title: url.lastPathComponent)
                return out
            },
        ]
    }
}

// MARK: - CSV

enum CSV {
    static func parse(_ s: String, sep: Character) -> Table {
        var rows: Table = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var chars = Array(s.replacingOccurrences(of: "\r\n", with: "\n"))
        if chars.first == "\u{FEFF}" { chars.removeFirst() }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count && chars[i + 1] == "\"" { field.append("\""); i += 1 } else { inQuotes = false }
                } else { field.append(c) }
            } else if c == "\"" && field.isEmpty {
                inQuotes = true
            } else if c == sep {
                row.append(field); field = ""
            } else if c == "\n" || c == "\r" {
                row.append(field); rows.append(row); row = []; field = ""
            } else { field.append(c) }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }

    static func write(_ t: Table, sep: Character) -> String {
        t.map { row in
            row.map { f in
                if f.contains(sep) || f.contains("\"") || f.contains("\n") { return "\"" + f.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
                return f
            }.joined(separator: String(sep))
        }.joined(separator: "\n") + "\n"
    }
}

// MARK: - XLSX (first sheet)

enum XLSX {
    static func read(_ url: URL) throws -> Table {
        let dir = try Paths.tempDir()
        try Shell.runSync("/usr/bin/unzip", ["-q", "-o", url.path, "-d", dir.path])
        var shared: [String] = []
        if let data = try? Data(contentsOf: dir.appendingPathComponent("xl/sharedStrings.xml")) {
            let p = SharedStringsParser(); let xp = XMLParser(data: data); xp.delegate = p; xp.parse(); shared = p.strings
        }
        // First sheet listed in the workbook.
        let sheetsDir = dir.appendingPathComponent("xl/worksheets")
        let sheets = ((try? FileManager.default.contentsOfDirectory(atPath: sheetsDir.path)) ?? []).filter { $0.hasSuffix(".xml") }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard let first = sheets.first, let data = try? Data(contentsOf: sheetsDir.appendingPathComponent(first)) else { throw OpError("No worksheet found") }
        let p = SheetParser(shared: shared); let xp = XMLParser(data: data); xp.delegate = p; xp.parse()
        return p.table()
    }

    static func write(_ t: Table, to out: URL) throws {
        let dir = try Paths.tempDir().appendingPathComponent("x")
        let fm = FileManager.default
        for d in ["_rels", "xl/_rels", "xl/worksheets"] { try fm.createDirectory(at: dir.appendingPathComponent(d), withIntermediateDirectories: true) }
        func put(_ path: String, _ s: String) throws { try s.write(to: dir.appendingPathComponent(path), atomically: true, encoding: .utf8) }
        try put("[Content_Types].xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/><Default Extension="xml" ContentType="application/xml"/><Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/><Override PartName="/xl/worksheets/sheet1.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml"/></Types>
        """)
        try put("_rels/.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/></Relationships>
        """)
        try put("xl/workbook.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>
        """)
        try put("xl/_rels/workbook.xml.rels", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/></Relationships>
        """)
        var rows = ""
        for (r, row) in t.enumerated() {
            rows += "<row r=\"\(r + 1)\">"
            for (c, v) in row.enumerated() where !v.isEmpty {
                let ref = colName(c) + "\(r + 1)"
                if Double(v) != nil, !v.hasPrefix("0") || v == "0" || v.hasPrefix("0.") {
                    rows += "<c r=\"\(ref)\"><v>\(v)</v></c>"
                } else {
                    rows += "<c r=\"\(ref)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(RichText.esc(v))</t></is></c>"
                }
            }
            rows += "</row>"
        }
        try put("xl/worksheets/sheet1.xml", """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main"><sheetData>\(rows)</sheetData></worksheet>
        """)
        try Shell.runZip(in: dir, args: ["-rX", out.path, "[Content_Types].xml", "_rels", "xl"])
    }

    static func colName(_ i: Int) -> String {
        var n = i + 1, s = ""
        while n > 0 { let r = (n - 1) % 26; s = String(UnicodeScalar(65 + r)!) + s; n = (n - 1) / 26 }
        return s
    }

    static func colIndex(_ ref: String) -> Int {
        var n = 0
        for ch in ref.unicodeScalars { guard ch.value >= 65 && ch.value <= 90 else { break }; n = n * 26 + Int(ch.value - 64) }
        return max(n - 1, 0)
    }

    final class SharedStringsParser: NSObject, XMLParserDelegate {
        var strings: [String] = []
        private var cur = "", inT = false, inSI = false
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            if e == "si" { inSI = true; cur = "" } else if e == "t" { inT = true }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if inSI && inT { cur += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "t" { inT = false } else if e == "si" { strings.append(cur); inSI = false }
        }
    }

    final class SheetParser: NSObject, XMLParserDelegate {
        let shared: [String]
        var cells: [Int: [Int: String]] = [:]
        private var row = 0, col = 0, type = "", buf = "", capture = false
        init(shared: [String]) { self.shared = shared }
        func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String] = [:]) {
            switch e {
            case "row": row = (Int(a["r"] ?? "") ?? (row + 1)) - 1
            case "c":
                type = a["t"] ?? ""; buf = ""
                if let r = a["r"] { col = colIndex(r) } else { col += 1 }
            case "v", "t": capture = true
            default: break
            }
        }
        func parser(_ p: XMLParser, foundCharacters s: String) { if capture { buf += s } }
        func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
            if e == "v" || e == "t" { capture = false }
            if e == "c" {
                var v = buf
                if type == "s", let i = Int(buf), i < shared.count { v = shared[i] }
                if type == "b" { v = buf == "1" ? "TRUE" : "FALSE" }
                if !v.isEmpty { cells[row, default: [:]][col] = v }
            }
        }
        func table() -> Table {
            guard let maxRow = cells.keys.max() else { return [] }
            let maxCol = cells.values.flatMap(\.keys).max() ?? 0
            return (0...maxRow).map { r in (0...maxCol).map { cells[r]?[$0] ?? "" } }
        }
    }
}
