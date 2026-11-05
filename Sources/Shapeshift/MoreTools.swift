import AppKit
import CoreImage
import CryptoKit
import PDFKit
import Speech
import Vision

// MARK: - Image extras

enum ImageExtras {
    static func tools() -> [Operation] {
        [
            Catalog.each("Extract text", "text.viewfinder") { url in
                let text = try recognizeText(in: try ImageOps.load(url))
                guard !text.isEmpty else { throw OpError("No text found in this image") }
                let out = Paths.output(for: url, ext: "txt", suffix: "text")
                try text.write(to: out, atomically: true, encoding: .utf8)
                await MainActor.run { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                return out
            },
            Operation(title: "Scan QR", symbol: "qrcode.viewfinder", run: { urls in
                var found: [String] = []
                for url in urls { found += try barcodes(in: try ImageOps.load(url)) }
                let text = found.isEmpty ? "No QR code or barcode found." : found.joined(separator: "\n")
                await MainActor.run {
                    if !found.isEmpty { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(found.joined(separator: "\n"), forType: .string) }
                    Prompt.showText(title: "Scanned codes (copied)", text: text)
                }
                return []
            }, silent: true),
            ImageOps.transform("Blur faces") { try blurFaces($0) },
            Catalog.each("Watermark…", "signature") { url in
                let vals = await MainActor.run { Prompt.ask(title: "Watermark", message: "Text to place in the bottom-right corner.", fields: [("Text", "© Your Name", "© ")]) }
                guard let text = vals?.first, !text.isEmpty else { throw CancellationError() }
                let img = try ImageOps.load(url)
                return try ImageOps.save(watermark(img, text: text), like: url, suffix: "watermarked")
            },
            ImageOps.transform("Round corners", keepFormat: false) { img in
                let r = CGFloat(min(img.width, img.height)) * 0.08
                return ImageOps.render(width: img.width, height: img.height) { ctx in
                    let rect = CGRect(x: 0, y: 0, width: img.width, height: img.height)
                    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)); ctx.clip()
                    ctx.draw(img, in: rect)
                }
            },
            ImageOps.transform("Add border") { img in
                let b = max(8, min(img.width, img.height) / 25)
                return ImageOps.render(width: img.width + b * 2, height: img.height + b * 2) { ctx in
                    ctx.setFillColor(.white); ctx.fill(CGRect(x: 0, y: 0, width: img.width + b * 2, height: img.height + b * 2))
                    ctx.draw(img, in: CGRect(x: b, y: b, width: img.width, height: img.height))
                }
            },
            ImageOps.transform("Sharpen") { img in
                let ci = CIImage(cgImage: img)
                let f = CIFilter(name: "CISharpenLuminance")!
                f.setValue(ci, forKey: kCIInputImageKey); f.setValue(0.6, forKey: kCIInputSharpnessKey)
                return CIContext().createCGImage(f.outputImage!, from: ci.extent) ?? img
            },
            ImageOps.transform("Upscale 2×") { img in
                let ci = CIImage(cgImage: img)
                let f = CIFilter(name: "CILanczosScaleTransform")!
                f.setValue(ci, forKey: kCIInputImageKey); f.setValue(2.0, forKey: kCIInputScaleKey); f.setValue(1.0, forKey: kCIInputAspectRatioKey)
                let out = f.outputImage!
                return CIContext().createCGImage(out, from: out.extent) ?? img
            },
        ]
    }

    static func recognizeText(in img: CGImage) throws -> String {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.usesLanguageCorrection = true
        req.automaticallyDetectsLanguage = true
        try VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }

    static func barcodes(in img: CGImage) throws -> [String] {
        let req = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: img).perform([req])
        return (req.results ?? []).compactMap { $0.payloadStringValue }
    }

    static func blurFaces(_ img: CGImage) throws -> CGImage {
        let req = VNDetectFaceRectanglesRequest()
        try VNImageRequestHandler(cgImage: img).perform([req])
        let faces = req.results ?? []
        guard !faces.isEmpty else { throw OpError("No faces found") }
        let ci = CIImage(cgImage: img)
        let scale = max(CGFloat(max(img.width, img.height)) / 40, 12)
        let pixelated = ci.applyingFilter("CIPixellate", parameters: [kCIInputScaleKey: scale, kCIInputCenterKey: CIVector(x: 0, y: 0)]).cropped(to: ci.extent)
        // Mask: white ovals over every face (slightly enlarged).
        var mask = CIImage(color: .black).cropped(to: ci.extent)
        for f in faces {
            let b = VNImageRectForNormalizedRect(f.boundingBox, img.width, img.height).insetBy(dx: -CGFloat(img.width) * 0.02, dy: -CGFloat(img.height) * 0.03)
            let radial = CIFilter(name: "CIRadialGradient", parameters: [
                "inputCenter": CIVector(x: b.midX, y: b.midY), "inputRadius0": max(b.width, b.height) * 0.45,
                "inputRadius1": max(b.width, b.height) * 0.6, "inputColor0": CIColor.white, "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
            ])!.outputImage!.cropped(to: ci.extent)
            mask = radial.composited(over: mask)
        }
        let out = pixelated.applyingFilter("CIBlendWithMask", parameters: [kCIInputBackgroundImageKey: ci, kCIInputMaskImageKey: mask])
        guard let cg = CIContext().createCGImage(out, from: ci.extent) else { throw OpError("Blur failed") }
        return cg
    }

    static func watermark(_ img: CGImage, text: String) -> CGImage {
        ImageOps.render(width: img.width, height: img.height) { ctx in
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
            let size = CGFloat(max(14, min(img.width, img.height) / 22))
            let shadow = NSShadow(); shadow.shadowBlurRadius = size / 6; shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
            let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .semibold),
                                                        .foregroundColor: NSColor.white.withAlphaComponent(0.85), .shadow: shadow]
            let s = NSAttributedString(string: text, attributes: attrs)
            let w = s.size()
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            s.draw(at: NSPoint(x: CGFloat(img.width) - w.width - size, y: size * 0.8))
            NSGraphicsContext.restoreGraphicsState()
        }
    }
}

extension ImageOps {
    static func save(_ img: CGImage, like url: URL, suffix: String) throws -> URL {
        var ext = outputFormats.contains { $0.ext == url.ext } ? url.ext : "png"
        if ext == "jpeg" { ext = "jpg" }
        let out = Paths.output(for: url, ext: ext, suffix: suffix)
        try write(img, to: out, uti: outputFormats.first { $0.ext == ext }!.uti)
        return out
    }
}

// MARK: - PDF extras

enum PDFExtras {
    static func tools() -> [Operation] {
        [
            Catalog.each("OCR text", "text.viewfinder") { url in
                let doc = try PDFOps.open(url)
                var text = ""
                for i in 0..<doc.pageCount {
                    guard let page = doc.page(at: i) else { continue }
                    let existing = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    let pageText = existing.count > 20 ? existing : try ImageExtras.recognizeText(in: PDFOps.render(page, dpi: 200))
                    text += "--- Page \(i + 1) ---\n\(pageText)\n\n"
                }
                let out = Paths.output(for: url, ext: "txt", suffix: "text")
                try text.write(to: out, atomically: true, encoding: .utf8)
                return out
            },
            Catalog.each("Page numbers", "number") { url in
                let doc = try PDFOps.open(url)
                let out = Paths.output(for: url, ext: "pdf", suffix: "numbered")
                try stamp(doc, to: out) { ctx, box, i, n in
                    let s = NSAttributedString(string: "\(i + 1) / \(n)", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.darkGray])
                    s.draw(at: NSPoint(x: box.midX - s.size().width / 2, y: box.minY + 20))
                }
                return out
            },
            Catalog.each("Watermark…", "signature") { url in
                let vals = await MainActor.run { Prompt.ask(title: "PDF watermark", message: "Text stamped diagonally on every page.", fields: [("Text", "CONFIDENTIAL", "DRAFT")]) }
                guard let text = vals?.first, !text.isEmpty else { throw CancellationError() }
                let doc = try PDFOps.open(url)
                let out = Paths.output(for: url, ext: "pdf", suffix: "watermarked")
                try stamp(doc, to: out) { ctx, box, _, _ in
                    let size = min(box.width, box.height) / 9
                    let s = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size, weight: .bold), .foregroundColor: NSColor.red.withAlphaComponent(0.18)])
                    ctx.saveGState()
                    ctx.translateBy(x: box.midX, y: box.midY); ctx.rotate(by: .pi / 5)
                    s.draw(at: NSPoint(x: -s.size().width / 2, y: -s.size().height / 2))
                    ctx.restoreGState()
                }
                return out
            },
            Catalog.each("Unlock…", "lock.open") { url in
                guard let doc = PDFDocument(url: url) else { throw OpError("Could not open PDF") }
                if doc.isLocked {
                    let vals = await MainActor.run { Prompt.ask(title: "Unlock PDF", message: "Enter the PDF's password.", fields: [("Password", "", "")], secure: true) }
                    guard let pw = vals?.first, doc.unlock(withPassword: pw) else { throw OpError("Wrong password") }
                }
                let out = Paths.output(for: url, ext: "pdf", suffix: "unlocked")
                // Re-draw pages into a fresh document so no encryption carries over.
                try stamp(doc, to: out) { _, _, _, _ in }
                return out
            },
            Catalog.each("Read aloud", "speaker.wave.2") { url in
                let doc = try PDFOps.open(url)
                return try await Speech.speak(PDFOps.attributedText(doc).string, like: url)
            },
        ]
    }

    /// Redraw every page into a new PDF and let `draw` add something on top.
    static func stamp(_ doc: PDFDocument, to out: URL, _ draw: (CGContext, CGRect, Int, Int) -> Void) throws {
        var media = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &media, nil) else { throw OpError("Could not create PDF") }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            var box = page.bounds(for: .mediaBox)
            if page.rotation % 180 != 0 { box = CGRect(x: 0, y: 0, width: box.height, height: box.width) }
            box.origin = .zero
            ctx.beginPage(mediaBox: &box)
            page.draw(with: .mediaBox, to: ctx)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            draw(ctx, box, i, doc.pageCount)
            NSGraphicsContext.restoreGraphicsState()
            ctx.endPage()
        }
        ctx.closePDF()
    }
}

// MARK: - Video / audio extras

enum MediaExtras {
    static func videoTools() -> [Operation] {
        [
            Catalog.each("Transcribe", "captions.bubble") { try await Speech.transcribe($0) },
            Catalog.each("Vertical 9:16", "rectangle.portrait") { url in
                try await reencode(url, "vertical", ["-vf", "crop='min(iw,ih*9/16)':'min(ih,iw*16/9)',scale=trunc(iw/2)*2:trunc(ih/2)*2"])
            },
            Catalog.each("Square 1:1", "square") { url in
                try await reencode(url, "square", ["-vf", "crop='min(iw,ih)':'min(iw,ih)',scale=trunc(iw/2)*2:trunc(ih/2)*2"])
            },
            Catalog.each("Stabilize", "camera.metering.center.weighted") { url in try await reencode(url, "stabilized", ["-vf", "deshake"]) },
            Catalog.each("Reverse", "backward") { url in try await reencode(url, "reversed", ["-vf", "reverse", "-af", "areverse"]) },
            Catalog.each("Extract frames", "photo.on.rectangle") { url in
                let folder = Paths.outputFolder(for: url, suffix: "frames")
                try await Shell.ffmpeg(["-i", url.path, "-vf", "fps=1", "-q:v", "2", folder.appendingPathComponent("frame %04d.jpg").path])
                return folder
            },
        ]
    }

    static func audioTools() -> [Operation] {
        [
            Catalog.each("Transcribe", "captions.bubble") { try await Speech.transcribe($0) },
            Catalog.each("Noise reduction", "waveform.badge.minus") { url in
                let ext = MediaOps.audioFormats.contains(url.ext) ? url.ext : "m4a"
                let out = Paths.output(for: url, ext: ext, suffix: "denoised")
                try await Shell.ffmpeg(["-i", url.path, "-vn", "-af", "afftdn=nf=-25,highpass=f=80"] + MediaOps.audioArgs(ext) + [out.path])
                return out
            },
            Catalog.each("Ringtone", "bell") { url in
                let out = Paths.output(for: url, ext: "m4r", suffix: "ringtone")
                try await Shell.ffmpeg(["-i", url.path, "-vn", "-t", "30", "-af", "afade=t=out:st=28:d=2", "-c:a", "aac", "-b:a", "192k", "-f", "ipod", out.path])
                return out
            },
        ]
    }

    private static func reencode(_ url: URL, _ suffix: String, _ filters: [String]) async throws -> URL {
        let ext = ["mp4", "mov", "mkv", "m4v"].contains(url.ext) ? url.ext : "mp4"
        let out = Paths.output(for: url, ext: ext, suffix: suffix)
        try await Shell.ffmpeg(["-i", url.path] + filters + ["-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "160k", out.path])
        return out
    }
}

// MARK: - Speech (on-device)

enum Speech {
    /// Text → spoken M4A using the built-in macOS voices.
    static func speak(_ text: String, like url: URL) async throws -> URL {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { throw OpError("No text to read") }
        let tmp = try Paths.tempDir().appendingPathComponent("text.txt")
        try clean.write(to: tmp, atomically: true, encoding: .utf8)
        let out = Paths.output(for: url, ext: "m4a", suffix: "spoken")
        try await Shell.run("/usr/bin/say", ["-f", tmp.path, "-o", out.path, "--file-format=m4af", "--data-format=aac"])
        return out
    }

    /// Audio/video → SRT subtitles + plain transcript, recognized on this Mac.
    static func transcribe(_ url: URL) async throws -> URL {
        let status = await withCheckedContinuation { c in SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0) } }
        guard status == .authorized else {
            throw OpError("Allow Speech Recognition for Shapeshift in System Settings → Privacy & Security")
        }
        guard let rec = SFSpeechRecognizer(), rec.isAvailable else { throw OpError("Speech recognition is unavailable for your language") }
        // Normalize to 16 kHz mono WAV (handles any container, including video).
        let wav = try Paths.tempDir().appendingPathComponent("audio.wav")
        try await Shell.ffmpeg(["-i", url.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", wav.path])
        let duration = try await MediaOps.duration(wav)

        // Recognize in 50-second chunks so long recordings work on-device.
        var segments: [(Double, Double, String)] = []
        var start = 0.0
        let chunk = 50.0
        let dir = wav.deletingLastPathComponent()
        var n = 0
        repeat {
            let part = dir.appendingPathComponent("part\(n).wav")
            try await Shell.ffmpeg(["-ss", "\(start)", "-t", "\(chunk)", "-i", wav.path, "-c", "copy", part.path])
            for s in try await recognize(part, rec) { segments.append((s.0 + start, s.1 + start, s.2)) }
            start += chunk; n += 1
        } while start < duration

        guard !segments.isEmpty else { throw OpError("No speech recognized") }
        // Group words into subtitle cues of ~8 words / 4 seconds.
        var cues: [SubtitleOps.Cue] = []
        var cur: [String] = []; var cs = segments[0].0; var ce = segments[0].1
        for (s, e, w) in segments {
            if cur.isEmpty { cs = s }
            cur.append(w); ce = e
            if cur.count >= 8 || e - cs > 4 || w.hasSuffix(".") || w.hasSuffix("?") {
                cues.append(.init(start: cs, end: ce, text: cur.joined(separator: " "))); cur = []
            }
        }
        if !cur.isEmpty { cues.append(.init(start: cs, end: ce, text: cur.joined(separator: " "))) }
        let srt = Paths.output(for: url, ext: "srt")
        try SubtitleOps.render(cues, ext: "srt").write(to: srt, atomically: true, encoding: .utf8)
        let txt = Paths.output(for: url, ext: "txt", suffix: "transcript")
        try segments.map(\.2).joined(separator: " ").write(to: txt, atomically: true, encoding: .utf8)
        return srt
    }

    private static func recognize(_ file: URL, _ rec: SFSpeechRecognizer) async throws -> [(Double, Double, String)] {
        let req = SFSpeechURLRecognitionRequest(url: file)
        req.requiresOnDeviceRecognition = rec.supportsOnDeviceRecognition
        req.shouldReportPartialResults = false
        req.addsPunctuation = true
        return try await withCheckedThrowingContinuation { cont in
            var done = false
            var task: SFSpeechRecognitionTask?
            task = rec.recognitionTask(with: req) { result, error in
                if done { return }
                if let result, result.isFinal {
                    done = true
                    let segs = result.bestTranscription.segments.map { ($0.timestamp, $0.timestamp + $0.duration, $0.substring) }
                    cont.resume(returning: segs)
                } else if let error {
                    done = true
                    // Silence in a chunk is not a failure.
                    let ns = error as NSError
                    if ns.domain == "kAFAssistantErrorDomain" && (ns.code == 1110 || ns.code == 203) { cont.resume(returning: []) }
                    else { cont.resume(throwing: error) }
                }
            }
            _ = task
        }
    }
}

// MARK: - Any file

enum GeneralTools {
    static func checksum() -> Operation {
        Operation(title: "Checksum", symbol: "number.square", run: { urls in
            var lines: [String] = []
            for url in urls where !url.isDirectory {
                let (sha, md5) = try hashes(url)
                lines.append("\(url.lastPathComponent)\nSHA-256: \(sha)\nMD5:     \(md5)\n")
            }
            let text = lines.joined(separator: "\n")
            await MainActor.run {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                Prompt.showText(title: "Checksums (copied)", text: text)
            }
            return []
        }, silent: true)
    }

    static func hashes(_ url: URL) throws -> (String, String) {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var sha = SHA256(), md5 = Insecure.MD5()
        while let data = try h.read(upToCount: 1 << 20), !data.isEmpty { sha.update(data: data); md5.update(data: data) }
        func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
        return (hex(sha.finalize()), hex(md5.finalize()))
    }

    static func readAloud() -> Operation {
        Catalog.each("Read aloud", "speaker.wave.2") { url in
            let text = try await MainActor.run { try DocOps.read(url) }.string
            return try await Speech.speak(text, like: url)
        }
    }
}
