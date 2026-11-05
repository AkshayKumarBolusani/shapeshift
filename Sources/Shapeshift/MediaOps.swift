import Foundation

enum MediaOps {
    static let audioFormats = ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"]
    static let videoFormats = ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif"]

    // MARK: Codec choices

    static func audioArgs(_ ext: String, compress: Bool = false) -> [String] {
        switch ext {
        case "mp3": return ["-c:a", "libmp3lame", "-q:a", compress ? "6" : "2"]
        case "m4a", "aac": return ["-c:a", "aac", "-b:a", compress ? "96k" : "256k"]
        case "wav": return ["-c:a", "pcm_s16le"]
        case "flac": return ["-c:a", "flac"]
        case "ogg": return ["-c:a", "libopus", "-b:a", compress ? "64k" : "160k"]
        case "opus": return ["-c:a", "libopus", "-b:a", compress ? "48k" : "128k"]
        case "aiff", "aif": return ["-c:a", "pcm_s16be"]
        case "wma": return ["-c:a", "wmav2", "-b:a", compress ? "96k" : "192k"]
        default: return []
        }
    }

    static func videoArgs(_ ext: String, crf: Int = 20) -> [String] {
        let even = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p"]
        switch ext {
        case "mp4", "m4v": return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "\(crf)"] + even + ["-c:a", "aac", "-b:a", "160k", "-movflags", "+faststart"]
        case "mov": return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "\(crf)"] + even + ["-c:a", "aac", "-b:a", "160k"]
        case "mkv": return ["-c:v", "libx264", "-preset", "veryfast", "-crf", "\(crf)"] + even + ["-c:a", "aac", "-b:a", "160k", "-c:s", "copy"]
        case "webm": return ["-c:v", "libvpx-vp9", "-crf", "\(crf + 12)", "-b:v", "0", "-deadline", "realtime", "-cpu-used", "8", "-row-mt", "1", "-pix_fmt", "yuv420p", "-c:a", "libopus", "-b:a", "128k"]
        case "avi": return ["-c:v", "mpeg4", "-q:v", "4", "-c:a", "libmp3lame", "-q:a", "3"]
        case "wmv": return ["-c:v", "wmv2", "-q:v", "4", "-c:a", "wmav2", "-b:a", "192k"]
        default: return []
        }
    }

    // MARK: Conversions

    static func convertAudio(_ url: URL, to ext: String) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        try await Shell.ffmpeg(["-i", url.path, "-vn", "-map_metadata", "0"] + audioArgs(ext) + [out.path])
        return out
    }

    static func convertVideo(_ url: URL, to ext: String) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        if ext == "gif" {
            try await Shell.ffmpeg(["-i", url.path, "-vf",
                                    "fps=12,scale='min(640,iw)':-1:flags=lanczos,split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4",
                                    "-loop", "0", out.path])
        } else {
            try await Shell.ffmpeg(["-i", url.path] + videoArgs(ext) + [out.path])
        }
        return out
    }

    static func extractAudio(_ url: URL, ext: String) async throws -> URL {
        let out = Paths.output(for: url, ext: ext)
        try await Shell.ffmpeg(["-i", url.path, "-vn"] + audioArgs(ext) + [out.path])
        return out
    }

    // MARK: Tools

    static func videoTools() -> [Operation] {
        [
            Catalog.each("Compress", "arrow.down.right.and.arrow.up.left") { url in
                let out = Paths.output(for: url, ext: "mp4", suffix: "compressed")
                try await Shell.ffmpeg(["-i", url.path, "-c:v", "libx264", "-preset", "medium", "-crf", "28",
                                        "-vf", "scale='min(1920,iw)':-2", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "96k", "-movflags", "+faststart", out.path])
                return out
            },
            Catalog.each("Trim…", "scissors") { try await trim($0, video: true) },
            Catalog.each("Split…", "square.split.2x1") { try await split($0) },
            Catalog.each("Half size", "arrow.down.right.and.arrow.up.left.square") { url in
                try await simpleVideo(url, "half size", ["-vf", "scale=trunc(iw/4)*2:trunc(ih/4)*2"])
            },
            Catalog.each("Mute", "speaker.slash") { url in
                let out = Paths.output(for: url, ext: url.ext, suffix: "muted")
                try await Shell.ffmpeg(["-i", url.path, "-c:v", "copy", "-an", out.path])
                return out
            },
            Catalog.each("Rotate", "rotate.right") { url in try await simpleVideo(url, "rotated", ["-vf", "transpose=1"]) },
            Catalog.each("Speed 2×", "hare") { url in
                try await simpleVideo(url, "2x", ["-vf", "setpts=0.5*PTS", "-af", "atempo=2.0"])
            },
            Catalog.each("Snapshot", "camera") { url in
                let out = Paths.output(for: url, ext: "jpg", suffix: "frame")
                try await Shell.ffmpeg(["-ss", "1", "-i", url.path, "-frames:v", "1", "-q:v", "2", out.path])
                return out
            },
            Catalog.each("To GIF", "photo.stack") { try await convertVideo($0, to: "gif") },
            Catalog.each("Strip metadata", "eye.slash") { url in
                let out = Paths.output(for: url, ext: url.ext, suffix: "no metadata")
                try await Shell.ffmpeg(["-i", url.path, "-map_metadata", "-1", "-c", "copy", out.path])
                return out
            },
        ]
    }

    static func audioTools() -> [Operation] {
        [
            Catalog.each("Compress", "arrow.down.right.and.arrow.up.left") { url in
                let lossless = ["wav", "flac", "aiff", "aif", "alac", "caf"].contains(url.ext)
                let ext = lossless ? "m4a" : (audioFormats.contains(url.ext) ? url.ext : "m4a")
                let out = Paths.output(for: url, ext: ext, suffix: "compressed")
                try await Shell.ffmpeg(["-i", url.path, "-vn"] + audioArgs(ext, compress: true) + [out.path])
                return out
            },
            Catalog.each("Trim…", "scissors") { try await trim($0, video: false) },
            Catalog.each("Split…", "square.split.2x1") { try await split($0) },
            Catalog.each("Normalize", "slider.horizontal.3") { url in try await simpleAudio(url, "normalized", ["-af", "loudnorm=I=-16:TP=-1.5:LRA=11"]) },
            Catalog.each("Fade in/out", "waveform.path") { url in
                let d = try await duration(url)
                return try await simpleAudio(url, "faded", ["-af", "afade=t=in:d=2,afade=t=out:st=\(max(0, d - 2)):d=2"])
            },
            Catalog.each("Speed 1.5×", "hare") { url in try await simpleAudio(url, "1.5x", ["-af", "atempo=1.5"]) },
            Catalog.each("Remove silence", "waveform.badge.minus") { url in
                try await simpleAudio(url, "trimmed silence", ["-af", "silenceremove=start_periods=1:start_threshold=-50dB:stop_periods=-1:stop_threshold=-50dB:stop_duration=1"])
            },
            Catalog.each("Mono", "speaker.wave.1") { url in try await simpleAudio(url, "mono", ["-ac", "1"]) },
            Catalog.each("Strip metadata", "eye.slash") { url in
                let out = Paths.output(for: url, ext: url.ext, suffix: "no metadata")
                try await Shell.ffmpeg(["-i", url.path, "-map_metadata", "-1", "-map", "0:a", "-c", "copy", out.path])
                return out
            },
        ]
    }

    private static func simpleVideo(_ url: URL, _ suffix: String, _ filter: [String]) async throws -> URL {
        let ext = videoFormats.contains(url.ext) && url.ext != "gif" ? url.ext : "mp4"
        let out = Paths.output(for: url, ext: ext, suffix: suffix)
        var codec = videoArgs(ext)
        if let i = codec.firstIndex(of: "-vf") { codec.removeSubrange(i...(i + 1)) } // filters supplied by caller
        try await Shell.ffmpeg(["-i", url.path] + filter + codec + [out.path])
        return out
    }

    private static func simpleAudio(_ url: URL, _ suffix: String, _ filter: [String]) async throws -> URL {
        let ext = audioFormats.contains(url.ext) ? url.ext : "m4a"
        let out = Paths.output(for: url, ext: ext, suffix: suffix)
        try await Shell.ffmpeg(["-i", url.path, "-vn"] + filter + audioArgs(ext) + [out.path])
        return out
    }

    static func duration(_ url: URL) async throws -> Double {
        guard let probe = Tools.ffprobe else { throw OpError("ffprobe is not installed") }
        let s = try await Shell.run(probe, ["-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", url.path])
        return Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    static func trim(_ url: URL, video: Bool) async throws -> URL {
        let d = (try? await duration(url)) ?? 0
        let vals = await MainActor.run {
            Prompt.ask(title: "Trim \(url.lastPathComponent)", message: String(format: "Length: %.1f s. Use seconds or mm:ss.", d),
                       fields: [("Start", "0:00", "0"), ("End", "0:30", String(format: "%.1f", d))])
        }
        guard let vals, let start = parseTime(vals[0]), let end = parseTime(vals[1]), end > start else { throw CancellationError() }
        let ext = url.ext
        let out = Paths.output(for: url, ext: ext, suffix: "trimmed")
        // Re-encode for frame-accurate cuts.
        let codec = video ? videoArgs(videoFormats.contains(ext) ? ext : "mp4") : audioArgs(audioFormats.contains(ext) ? ext : "m4a")
        try await Shell.ffmpeg(["-ss", "\(start)", "-to", "\(end)", "-i", url.path] + (codec.isEmpty ? ["-c", "copy"] : codec) + [out.path])
        return out
    }

    static func split(_ url: URL) async throws -> URL {
        let d = (try? await duration(url)) ?? 0
        let vals = await MainActor.run {
            Prompt.ask(title: "Split \(url.lastPathComponent)", message: String(format: "Length: %.1f s. Each part will be this long:", d),
                       fields: [("Part length (seconds or mm:ss)", "60", String(format: "%.0f", max(1, (d / 2).rounded(.up))))])
        }
        guard let v = vals?.first, let len = parseTime(v), len > 0 else { throw CancellationError() }
        let folder = Paths.outputFolder(for: url, suffix: "parts")
        let pattern = folder.appendingPathComponent("\(url.deletingPathExtension().lastPathComponent) part %02d.\(url.ext)").path
        try await Shell.ffmpeg(["-i", url.path, "-f", "segment", "-segment_time", "\(len)", "-reset_timestamps", "1", "-map", "0", "-c", "copy", pattern])
        return folder
    }

    static func merge(_ urls: [URL], video: Bool) async throws -> [URL] {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let ext = video ? "mp4" : (audioFormats.contains(sorted[0].ext) ? sorted[0].ext : "m4a")
        let out = Paths.output(for: sorted[0], ext: ext, suffix: "merged")
        var args: [String] = []
        for u in sorted { args += ["-i", u.path] }
        let n = sorted.count
        if video {
            var chain = ""
            for i in 0..<n { chain += "[\(i):v]scale=1920:1080:force_original_aspect_ratio=decrease,pad=1920:1080:(ow-iw)/2:(oh-ih)/2,setsar=1,fps=30[v\(i)];[\(i):a]aresample=48000[a\(i)];" }
            for i in 0..<n { chain += "[v\(i)][a\(i)]" }
            chain += "concat=n=\(n):v=1:a=1[v][a]"
            args += ["-filter_complex", chain, "-map", "[v]", "-map", "[a]", "-c:v", "libx264", "-preset", "veryfast", "-crf", "20", "-pix_fmt", "yuv420p", "-c:a", "aac"]
        } else {
            let chain = (0..<n).map { "[\($0):a]" }.joined() + "concat=n=\(n):v=0:a=1[a]"
            args += ["-filter_complex", chain, "-map", "[a]"] + audioArgs(ext)
        }
        try await Shell.ffmpeg(args + [out.path])
        return [out]
    }
}
