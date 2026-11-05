import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

struct ImageFormat {
    let ext: String
    let uti: String
}

enum ImageOps {
    static let outputFormats: [ImageFormat] = [
        .init(ext: "jpg", uti: "public.jpeg"),
        .init(ext: "png", uti: "public.png"),
        .init(ext: "webp", uti: "org.webmproject.webp"),
        .init(ext: "heic", uti: "public.heic"),
        .init(ext: "avif", uti: "public.avif"),
        .init(ext: "tiff", uti: "public.tiff"),
        .init(ext: "bmp", uti: "com.microsoft.bmp"),
        .init(ext: "gif", uti: "com.compuserve.gif"),
        .init(ext: "pdf", uti: "com.adobe.pdf"),
        .init(ext: "ico", uti: "com.microsoft.ico"),
        .init(ext: "icns", uti: "com.apple.icns"),
    ]

    static func canWrite(_ uti: String) -> Bool {
        (CGImageDestinationCopyTypeIdentifiers() as? [String] ?? []).contains(uti)
    }

    // MARK: Loading

    static func load(_ url: URL) throws -> CGImage {
        if url.ext == "svg" {
            guard let img = NSImage(contentsOf: url) else { throw OpError("Could not read SVG") }
            let scale: CGFloat = 2
            var size = img.size
            if size.width < 1 || size.height < 1 { size = NSSize(width: 1024, height: 1024) }
            let w = Int(size.width * scale), h = Int(size.height * scale)
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw OpError("Could not render SVG") }
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            img.draw(in: NSRect(x: 0, y: 0, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
            guard let cg = ctx.makeImage() else { throw OpError("Could not render SVG") }
            return cg
        }
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw OpError("Could not open image") }
        // Apply EXIF orientation so the output looks like the original.
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize(src),
        ]
        if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        if let img = CGImageSourceCreateImageAtIndex(src, 0, nil) { return img }
        // Last resort: NSImage (handles a few odd formats).
        if let ns = NSImage(contentsOf: url), let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil) { return cg }
        throw OpError("Unsupported image")
    }

    private static func maxPixelSize(_ src: CGImageSource) -> Int {
        let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let w = p[kCGImagePropertyPixelWidth] as? Int ?? 8192
        let h = p[kCGImagePropertyPixelHeight] as? Int ?? 8192
        return max(w, h, 1)
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: Writing

    static func write(_ img: CGImage, to url: URL, uti: String, quality: Double? = nil, stripMetadata: Bool = true) throws {
        let q = quality ?? Settings.shared.jpegQuality
        switch uti {
        case "com.adobe.pdf":
            var box = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            guard let ctx = CGContext(url as CFURL, mediaBox: &box, nil) else { throw OpError("Could not create PDF") }
            ctx.beginPDFPage(nil); ctx.draw(img, in: box); ctx.endPDFPage(); ctx.closePDF()
            return
        case "org.webmproject.webp" where !canWrite(uti):
            guard let cwebp = Tools.cwebp else { throw OpError("WebP export needs cwebp: brew install webp") }
            let tmp = try Paths.tempDir().appendingPathComponent("in.png")
            try write(img, to: tmp, uti: "public.png")
            try Shell.runSync(cwebp, ["-quiet", "-q", "\(Int(q * 100))", "-alpha_q", "100", tmp.path, "-o", url.path])
            return
        case "com.apple.icns":
            // ICNS needs a square power-of-two image; sips assembles it reliably.
            let tmp = try Paths.tempDir().appendingPathComponent("icon.png")
            let side = [1024, 512, 256, 128].first { $0 <= max(img.width, img.height) } ?? 128
            try write(resizeToFit(img, maxSide: side, square: true).scaledSquare(side), to: tmp, uti: "public.png")
            try Shell.runSync("/usr/bin/sips", ["-s", "format", "icns", tmp.path, "--out", url.path])
            return
        default:
            break
        }
        var image = img
        if uti == "public.jpeg" || uti == "com.microsoft.bmp", hasAlpha(img) { image = flatten(img, on: .white) }
        if uti == "com.microsoft.ico" || uti == "com.apple.icns" { image = resizeToFit(img, maxSide: uti == "com.microsoft.ico" ? 256 : 1024, square: true) }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, uti as CFString, 1, nil) else {
            throw OpError("This Mac cannot write \(url.ext.uppercased())")
        }
        var props: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: q]
        if !stripMetadata { props[kCGImagePropertyOrientation] = 1 }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw OpError("Failed writing \(url.lastPathComponent)") }
    }

    static func convert(_ url: URL, to fmt: ImageFormat) async throws -> URL {
        if url.ext == "gif", ["mp4", "webm"].contains(fmt.ext) { return try await MediaOps.convertVideo(url, to: fmt.ext) }
        let img = try load(url)
        let out = Paths.output(for: url, ext: fmt.ext)
        try write(img, to: out, uti: fmt.uti)
        return out
    }

    // MARK: Transforms

    static func flatten(_ img: CGImage, on color: NSColor) -> CGImage {
        let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(color.usingColorSpace(.sRGB)!.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: img.width, height: img.height))
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return ctx.makeImage()!
    }

    static func render(width: Int, height: Int, _ draw: (CGContext) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.interpolationQuality = .high
        draw(ctx)
        return ctx.makeImage()!
    }

    static func resize(_ img: CGImage, scale: Double) -> CGImage {
        let w = Int(Double(img.width) * scale), h = Int(Double(img.height) * scale)
        return render(width: w, height: h) { $0.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) }
    }

    static func resizeToFit(_ img: CGImage, maxSide: Int, square: Bool = false) -> CGImage {
        let s = min(1, Double(maxSide) / Double(max(img.width, img.height)))
        let w = Int(Double(img.width) * s), h = Int(Double(img.height) * s)
        if !square { return render(width: w, height: h) { $0.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h)) } }
        let side = max(w, h)
        return render(width: side, height: side) { $0.draw(img, in: CGRect(x: (side - w) / 2, y: (side - h) / 2, width: w, height: h)) }
    }

    static func rotate(_ img: CGImage, clockwise: Bool) -> CGImage {
        _rotate(img, clockwise: clockwise)
    }

    private static func _rotate(_ img: CGImage, clockwise: Bool) -> CGImage {
        let w = img.height, h = img.width
        return render(width: w, height: h) { ctx in
            ctx.translateBy(x: CGFloat(w) / 2, y: CGFloat(h) / 2)
            ctx.rotate(by: clockwise ? -.pi / 2 : .pi / 2)
            ctx.draw(img, in: CGRect(x: -CGFloat(img.width) / 2, y: -CGFloat(img.height) / 2, width: CGFloat(img.width), height: CGFloat(img.height)))
        }
    }

    static func flip(_ img: CGImage, horizontal: Bool) -> CGImage {
        render(width: img.width, height: img.height) { ctx in
            if horizontal { ctx.translateBy(x: CGFloat(img.width), y: 0); ctx.scaleBy(x: -1, y: 1) }
            else { ctx.translateBy(x: 0, y: CGFloat(img.height)); ctx.scaleBy(x: 1, y: -1) }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        }
    }

    static func cropSquare(_ img: CGImage) -> CGImage {
        let side = min(img.width, img.height)
        return img.cropping(to: CGRect(x: (img.width - side) / 2, y: (img.height - side) / 2, width: side, height: side)) ?? img
    }

    static func ciFilter(_ img: CGImage, _ name: String) throws -> CGImage {
        let ci = CIImage(cgImage: img)
        guard let f = CIFilter(name: name) else { throw OpError("Filter unavailable") }
        f.setValue(ci, forKey: kCIInputImageKey)
        guard let out = f.outputImage, let cg = CIContext().createCGImage(out, from: ci.extent) else { throw OpError("Filter failed") }
        return cg
    }

    static func removeBackground(_ img: CGImage) throws -> CGImage {
        guard #available(macOS 14.0, *) else { throw OpError("Background removal needs macOS 14 or later") }
        let req = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: img)
        try handler.perform([req])
        guard let result = req.results?.first else { throw OpError("No subject found in this image") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { throw OpError("Mask failed") }
        return cg
    }

    /// Run a pixel transform and save in the same format (or a sensible one).
    static func transform(_ suffix: String, keepFormat: Bool = true, forceExt: String? = nil, _ f: @escaping (CGImage) throws -> CGImage) -> Operation {
        let symbols = ["Resize 50%": "arrow.down.left.and.arrow.up.right", "Rotate right": "rotate.right", "Rotate left": "rotate.left",
                       "Flip": "arrow.left.and.right.righttriangle.left.righttriangle.right", "Crop square": "crop", "Grayscale": "circle.lefthalf.filled",
                       "Auto enhance": "wand.and.stars", "White background": "square.fill.on.square", "Remove background": "person.crop.rectangle"]
        return Catalog.each(suffix, symbols[suffix] ?? "wand.and.stars") { url in
            let img = try load(url)
            let result = try f(img)
            var ext = forceExt ?? (keepFormat ? url.ext : "png")
            if ext == "jpeg" { ext = "jpg" }
            if ext == "svg" || !outputFormats.contains(where: { $0.ext == ext }) { ext = "png" }
            let fmt = outputFormats.first { $0.ext == ext }!
            let out = Paths.output(for: url, ext: ext, suffix: suffix.lowercased())
            try write(result, to: out, uti: fmt.uti)
            return out
        }
    }

    static func tools() -> [Operation] {
        var ops: [Operation] = [
            Catalog.each("Compress", "arrow.down.right.and.arrow.up.left") { url in try compress(url) },
            transform("Resize 50%") { resize($0, scale: 0.5) },
            Catalog.each("Resize…", "arrow.up.left.and.arrow.down.right") { url in try await resizePrompt(url) },
            transform("Rotate right") { rotate($0, clockwise: true) },
            transform("Rotate left") { rotate($0, clockwise: false) },
            transform("Flip") { flip($0, horizontal: true) },
            transform("Crop square") { cropSquare($0) },
            transform("Grayscale") { try ciFilter($0, "CIPhotoEffectMono") },
            transform("Auto enhance") { img in
                var ci = CIImage(cgImage: img)
                for f in ci.autoAdjustmentFilters() { f.setValue(ci, forKey: kCIInputImageKey); ci = f.outputImage ?? ci }
                return CIContext().createCGImage(ci, from: ci.extent) ?? img
            },
            transform("White background", forceExt: "jpg") { flatten($0, on: .white) },
            Catalog.each("Strip metadata", "eye.slash") { url in
                let img = try load(url)
                let ext = outputFormats.contains { $0.ext == url.ext } ? url.ext : "png"
                let out = Paths.output(for: url, ext: ext, suffix: "no metadata")
                try write(img, to: out, uti: outputFormats.first { $0.ext == ext }!.uti, quality: 1.0)
                return out
            },
        ]
        if #available(macOS 14.0, *) {
            ops.insert(transform("Remove background", keepFormat: false) { try removeBackground($0) }, at: 1)
        }
        return ops
    }

    static func compress(_ url: URL) throws -> URL {
        let img = try load(url)
        let lossy: [String: String] = ["jpg": "public.jpeg", "jpeg": "public.jpeg", "heic": "public.heic", "avif": "public.avif", "webp": "org.webmproject.webp"]
        let q = min(0.6, Settings.shared.jpegQuality)
        if let uti = lossy[url.ext] {
            let ext = url.ext == "jpeg" ? "jpg" : url.ext
            let out = Paths.output(for: url, ext: ext, suffix: "compressed")
            try write(img, to: out, uti: uti, quality: q)
            return out
        }
        // Lossless sources: JPEG when opaque, HEIC keeps transparency.
        let alpha = hasAlpha(img)
        let out = Paths.output(for: url, ext: alpha ? "heic" : "jpg", suffix: "compressed")
        try write(img, to: out, uti: alpha ? "public.heic" : "public.jpeg", quality: q)
        return out
    }

    static func resizePrompt(_ url: URL) async throws -> URL {
        let img = try load(url)
        let vals = await MainActor.run {
            Prompt.ask(title: "Resize \(url.lastPathComponent)", message: "Currently \(img.width) × \(img.height). Enter the longest side in pixels.",
                       fields: [("Longest side (px)", "1920", "\(max(img.width, img.height) / 2)")])
        }
        guard let v = vals?.first, let side = Int(v), side > 0 else { throw CancellationError() }
        let result = resizeToFit(img, maxSide: side)
        var ext = outputFormats.contains { $0.ext == url.ext } ? url.ext : "png"
        if ext == "jpeg" { ext = "jpg" }
        let out = Paths.output(for: url, ext: ext, suffix: "\(result.width)x\(result.height)")
        try write(result, to: out, uti: outputFormats.first { $0.ext == ext }!.uti)
        return out
    }

    static func mergeToPDF(_ urls: [URL]) async throws -> [URL] {
        let out = Paths.output(for: urls[0], ext: "pdf", suffix: "merged")
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let ctx = CGContext(out as CFURL, mediaBox: &box, nil) else { throw OpError("Could not create PDF") }
        for url in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let img = try load(url)
            var page = CGRect(x: 0, y: 0, width: img.width, height: img.height)
            ctx.beginPage(mediaBox: &page)
            ctx.draw(img, in: page)
            ctx.endPage()
        }
        ctx.closePDF()
        return [out]
    }
}

extension CGImage {
    func scaledSquare(_ side: Int) -> CGImage {
        ImageOps.render(width: side, height: side) { $0.draw(self, in: CGRect(x: 0, y: 0, width: side, height: side)) }
    }
}
