import AVFoundation
import Foundation

/// Formats Apple's frameworks can't write (MP3, OGG, Opus, MKV, AVI, WMV, WebM, WebP) go through ffmpeg
/// when it's installed (Homebrew/MacPorts) or bundled in the app's Resources folder.
enum FFmpeg {
    static var path: String? {
        let candidates = [
            Bundle.main.resourceURL?.appendingPathComponent("ffmpeg").path,
            "/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/opt/local/bin/ffmpeg",
        ].compactMap { $0 }
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var isAvailable: Bool { path != nil }

    static func require(_ what: String) throws -> String {
        guard let path else {
            throw AppError("\(what) needs ffmpeg. Install it with “brew install ffmpeg”, then try again.")
        }
        return path
    }

    static func run(_ args: [String], for what: String) throws {
        let tool = try require(what)
        try ArchiveOps.run(tool, ["-hide_banner", "-loglevel", "error", "-nostdin", "-y"] + args)
    }

    private static let encoders: String = {
        guard let path else { return "" }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = ["-hide_banner", "-encoders"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }()

    static func hasEncoder(_ name: String) -> Bool { encoders.contains(" \(name) ") }

    static var audioCodecs: [String: [String]] { [
        "mp3": ["-c:a", "libmp3lame", "-q:a", "2"],
        "ogg": hasEncoder("libvorbis") ? ["-c:a", "libvorbis", "-q:a", "5"]
                                       : ["-c:a", "vorbis", "-strict", "-2", "-ac", "2", "-q:a", "5"],
        "opus": ["-c:a", "libopus", "-b:a", "128k"],
        "m4a": ["-c:a", "aac", "-b:a", "256k"],
        "wav": ["-c:a", "pcm_s16le"],
        "aiff": ["-c:a", "pcm_s16be"],
        "flac": ["-c:a", "flac"],
        "wma": ["-c:a", "wmav2", "-b:a", "192k"],
    ] }

    static let videoCodecs: [String: [String]] = [
        "mp4": ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"],
        "mov": ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"],
        "m4v": ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k"],
        "mkv": ["-c:v", "libx264", "-crf", "20", "-preset", "medium", "-c:a", "aac", "-b:a", "192k"],
        "webm": ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-deadline", "good", "-cpu-used", "4", "-c:a", "libopus", "-b:a", "128k"],
        "avi": ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame", "-q:a", "3"],
        "wmv": ["-c:v", "wmv2", "-b:v", "5M", "-c:a", "wmav2", "-b:a", "192k"],
    ]

    /// Convert any audio/video file. Tries a lossless stream copy first for container-only changes.
    static func convert(_ src: URL, to out: URL, ext: String, audioOnly: Bool = false) throws {
        if audioOnly {
            try run(["-i", src.path, "-vn"] + (audioCodecs[ext] ?? []) + [out.path], for: ext.uppercased())
            return
        }
        if ["mkv", "mp4", "mov", "m4v"].contains(ext) {
            do {
                try run(["-i", src.path, "-map", "0", "-c", "copy", out.path], for: ext.uppercased())
                return
            } catch {
                try? FileManager.default.removeItem(at: out)
            }
        }
        try run(["-i", src.path] + (videoCodecs[ext] ?? []) + [out.path], for: ext.uppercased())
    }

    static func webp(_ src: URL, to out: URL, quality: Int = 90) throws {
        // Neither tool reads every image format, so hand them a PNG.
        let png = Output.temporary(ext: "png")
        defer { try? FileManager.default.removeItem(at: png) }
        try ImageOps.write(try ImageOps.load(src), to: png, ext: "png")
        let cwebp = ["/opt/homebrew/bin/cwebp", "/usr/local/bin/cwebp", "/opt/local/bin/cwebp"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        if let cwebp {
            try ArchiveOps.run(cwebp, ["-quiet", "-q", "\(quality)", "-metadata", "all", png.path, "-o", out.path])
        } else if hasEncoder("libwebp") {
            try run(["-i", png.path, "-c:v", "libwebp", "-quality", "\(quality)", out.path], for: "WebP")
        } else {
            throw AppError("WebP needs the webp tools. Install them with “brew install webp”, then try again.")
        }
    }
}

/// Makes files AVFoundation can't open (MKV, WebM, AVI, OGG…) usable by the native tools
/// by transcoding them to a temporary MP4 / WAV first.
enum MediaInput {
    static func playable(_ url: URL, audio: Bool) async throws -> (url: URL, isTemporary: Bool) {
        if ((try? await AVURLAsset(url: url).load(.isReadable)) ?? false) { return (url, false) }
        let tmp = Output.temporary(ext: audio ? "wav" : "mp4")
        try FFmpeg.convert(url, to: tmp, ext: audio ? "wav" : "mp4", audioOnly: audio)
        return (tmp, true)
    }

    /// Runs `body` on a readable version of `url`, cleaning up any temporary copy.
    static func with<T>(_ url: URL, audio: Bool, _ body: (URL) async throws -> T) async throws -> T {
        let (u, temp) = try await playable(url, audio: audio)
        defer { if temp { try? FileManager.default.removeItem(at: u) } }
        return try await body(u)
    }
}
