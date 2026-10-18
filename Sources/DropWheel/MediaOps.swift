import AVFoundation
import ImageIO
import UniformTypeIdentifiers

enum VideoOps {
    static func fileType(for ext: String) -> AVFileType {
        switch ext {
        case "mp4": return .mp4
        case "m4v": return .m4v
        case "m4a": return .m4a
        default: return .mov
        }
    }

    /// Same container as the source when AVFoundation can write it, otherwise MOV.
    static func sameExt(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        return ["mp4", "m4v", "mov"].contains(e) ? e : "mov"
    }

    static func export(_ asset: AVAsset, preset: String, to out: URL, ext: String,
                       timeRange: CMTimeRange? = nil, stripMetadata: Bool = false,
                       videoComposition: AVVideoComposition? = nil, metadata: [AVMetadataItem]? = nil,
                       keepPitch: Bool = true) async throws {
        guard let session = AVAssetExportSession(asset: asset, presetName: preset) else {
            throw AppError("This file can’t be exported")
        }
        if let timeRange { session.timeRange = timeRange }
        if stripMetadata {
            session.metadata = []
            session.metadataItemFilter = .forSharing()
        }
        if let videoComposition { session.videoComposition = videoComposition }
        if let metadata { session.metadata = metadata }
        session.audioTimePitchAlgorithm = keepPitch ? .spectral : .varispeed
        try await session.export(to: out, as: fileType(for: ext))
    }

    private static var transcoded: [URL: URL] = [:]
    private static let lock = NSLock()

    /// The file as an AVFoundation asset; MKV/WebM/AVI etc. are transcoded to a temporary MP4 via ffmpeg once.
    static func readableAsset(_ src: URL) async throws -> AVURLAsset {
        let asset = AVURLAsset(url: src)
        if (try? await asset.load(.isReadable)) ?? false { return asset }
        lock.lock(); let cached = transcoded[src]; lock.unlock()
        if let cached, FileManager.default.fileExists(atPath: cached.path) { return AVURLAsset(url: cached) }
        guard FFmpeg.isAvailable else {
            throw AppError("macOS can’t read \(src.lastPathComponent). Install ffmpeg (“brew install ffmpeg”) to open it.")
        }
        let tmp = Output.temporary(ext: "mp4")
        try FFmpeg.convert(src, to: tmp, ext: "mp4")
        lock.lock(); transcoded[src] = tmp; lock.unlock()
        return AVURLAsset(url: tmp)
    }

    static let nativeExts: Set<String> = ["mp4", "mov", "m4v"]

    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let out = Output.url(for: src, ext: ext)
        let readable = ((try? await AVURLAsset(url: src).load(.isReadable)) ?? false)
        guard nativeExts.contains(ext), readable else {
            try FFmpeg.convert(src, to: out, ext: ext)
            return out
        }
        let asset = AVURLAsset(url: src)
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, ext: ext)
        } catch {
            // Codec doesn't fit the container — re-encode.
            try? FileManager.default.removeItem(at: out)
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, ext: ext)
        }
        return out
    }

    static func extractAudio(_ src: URL, ext: String = "m4a") async throws -> URL {
        let out = Output.url(for: src, ext: ext)
        let readable = ((try? await AVURLAsset(url: src).load(.isReadable)) ?? false)
        if !readable || !["m4a", "wav", "aiff", "flac"].contains(ext) {
            try FFmpeg.convert(src, to: out, ext: ext, audioOnly: true)
            return out
        }
        let asset = AVURLAsset(url: src)
        guard !(try await asset.loadTracks(withMediaType: .audio)).isEmpty else {
            throw AppError("This video has no sound")
        }
        if ext == "m4a" {
            try await export(asset, preset: AVAssetExportPresetAppleM4A, to: out, ext: "m4a")
        } else {
            let tmp = Output.temporary(ext: "m4a")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try await export(asset, preset: AVAssetExportPresetAppleM4A, to: tmp, ext: "m4a")
            try AudioOps.write(try AudioOps.readAll(tmp), to: out, ext: ext)
        }
        return out
    }

    static func compress(_ src: URL) async throws -> URL {
        let asset = try await readableAsset(src)
        let out = Output.url(for: src, suffix: "compressed", ext: "mp4")
        try await export(asset, preset: AVAssetExportPresetHEVC1920x1080, to: out, ext: "mp4")
        return out
    }

    static func trim(_ src: URL, range: CMTimeRange) async throws -> URL {
        let asset = try await readableAsset(src)
        let ext = sameExt(src)
        let out = Output.url(for: src, suffix: "trimmed", ext: ext)
        do {
            try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, ext: ext, timeRange: range)
        } catch {
            try? FileManager.default.removeItem(at: out)
            try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, ext: ext, timeRange: range)
        }
        return out
    }

    static func stripMetadata(_ src: URL) async throws -> URL {
        let asset = try await readableAsset(src)
        let ext = sameExt(src)
        let out = Output.url(for: src, suffix: "no metadata", ext: ext)
        try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, ext: ext, stripMetadata: true)
        return out
    }

    static func snapshot(_ src: URL) async throws -> URL {
        let asset = try await readableAsset(src)
        let duration = try await asset.load(.duration)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        let (image, _) = try await gen.image(at: CMTimeMultiplyByFloat64(duration, multiplier: 0.5))
        let out = Output.url(for: src, suffix: "snapshot", ext: "png")
        try ImageOps.write(image, to: out, ext: "png")
        return out
    }

    static func gif(_ src: URL) async throws -> URL {
        let asset = try await readableAsset(src)
        let seconds = min(try await asset.load(.duration).seconds, 30)
        let fps = 12.0
        let count = max(1, Int(seconds * fps))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 540, height: 540)
        let tol = CMTime(value: 1, timescale: 30)
        gen.requestedTimeToleranceBefore = tol
        gen.requestedTimeToleranceAfter = tol

        let out = Output.url(for: src, ext: "gif")
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType.gif.identifier as CFString, count, nil) else {
            throw AppError("Couldn’t create GIF")
        }
        CGImageDestinationSetProperties(dest, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
        let frameProps = [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 1 / fps]] as CFDictionary
        for i in 0..<count {
            let (img, _) = try await gen.image(at: CMTime(seconds: Double(i) / fps, preferredTimescale: 600))
            CGImageDestinationAddImage(dest, img, frameProps)
        }
        guard CGImageDestinationFinalize(dest) else { throw AppError("Couldn’t save GIF") }
        return out
    }

    /// Builds a composition holding the asset's tracks, optionally dropping audio.
    private static func composition(_ asset: AVAsset, includeAudio: Bool) async throws -> AVMutableComposition {
        let comp = AVMutableComposition()
        let duration = try await asset.load(.duration)
        let range = CMTimeRange(start: .zero, duration: duration)
        for type in includeAudio ? [AVMediaType.video, .audio] : [.video] {
            for track in try await asset.loadTracks(withMediaType: type) {
                guard let t = comp.addMutableTrack(withMediaType: type, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                try t.insertTimeRange(range, of: track, at: .zero)
                if type == .video { t.preferredTransform = try await track.load(.preferredTransform) }
            }
        }
        return comp
    }

    static func mute(_ src: URL) async throws -> URL {
        let asset = try await readableAsset(src)
        let comp = try await composition(asset, includeAudio: false)
        let ext = sameExt(src)
        let out = Output.url(for: src, suffix: "muted", ext: ext)
        try await export(comp, preset: AVAssetExportPresetPassthrough, to: out, ext: ext)
        return out
    }

    static func changeSpeed(_ src: URL, factor: Double, keepPitch: Bool = true) async throws -> URL {
        let asset = try await readableAsset(src)
        let comp = try await composition(asset, includeAudio: true)
        let duration = comp.duration
        comp.scaleTimeRange(CMTimeRange(start: .zero, duration: duration),
                            toDuration: CMTimeMultiplyByFloat64(duration, multiplier: 1 / factor))
        let label = factor == factor.rounded() ? "\(Int(factor))" : String(format: "%g", factor)
        let out = Output.url(for: src, suffix: "\(label)x speed", ext: "mp4")
        try await export(comp, preset: AVAssetExportPresetHighestQuality, to: out, ext: "mp4", keepPitch: keepPitch)
        return out
    }

    static func join(_ urls: [URL]) async throws -> URL {
        let comp = AVMutableComposition()
        let video = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!
        let audio = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!
        var cursor = CMTime.zero
        for u in urls.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            let asset = AVURLAsset(url: u)
            let duration = try await asset.load(.duration)
            let range = CMTimeRange(start: .zero, duration: duration)
            if let v = try await asset.loadTracks(withMediaType: .video).first {
                try video.insertTimeRange(range, of: v, at: cursor)
                if cursor == .zero { video.preferredTransform = try await v.load(.preferredTransform) }
            }
            if let a = try await asset.loadTracks(withMediaType: .audio).first {
                try audio.insertTimeRange(range, of: a, at: cursor)
            }
            cursor = cursor + duration
        }
        let out = Output.url(for: urls[0], suffix: "joined", ext: "mp4")
        try await export(comp, preset: AVAssetExportPresetHighestQuality, to: out, ext: "mp4")
        return out
    }
}

// MARK: - Audio

enum AudioOps {
    static let writableFormats = ["M4A", "WAV", "AIFF", "FLAC", "CAF"]  // natively

    static func settings(ext: String, sampleRate: Double, channels: Int, bitRate: Int = 256_000) -> [String: Any] {
        var s: [String: Any] = [AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels]
        switch ext {
        case "m4a", "aac":
            s[AVFormatIDKey] = kAudioFormatMPEG4AAC
            s[AVEncoderBitRateKey] = bitRate
            s[AVSampleRateKey] = sampleRate > 48_000 ? 48_000 : sampleRate
        case "flac":
            s[AVFormatIDKey] = kAudioFormatFLAC
        default:
            s[AVFormatIDKey] = kAudioFormatLinearPCM
            s[AVLinearPCMBitDepthKey] = 16
            s[AVLinearPCMIsFloatKey] = false
            s[AVLinearPCMIsNonInterleaved] = false
            s[AVLinearPCMIsBigEndianKey] = (ext == "aiff")
        }
        return s
    }

    static func readAll(_ url: URL) throws -> AVAudioPCMBuffer {
        let file: AVAudioFile
        do {
            file = try AVAudioFile(forReading: url)
        } catch {
            // OGG, Opus, WMA… decode through ffmpeg.
            guard FFmpeg.isAvailable else {
                throw AppError("macOS can’t read \(url.lastPathComponent). Install ffmpeg (“brew install ffmpeg”) to open it.")
            }
            let tmp = Output.temporary(ext: "wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try FFmpeg.convert(url, to: tmp, ext: "wav", audioOnly: true)
            return try readAll(tmp)
        }
        guard let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                         frameCapacity: AVAudioFrameCount(file.length)) else {
            throw AppError("Audio file is too large")
        }
        try file.read(into: buf)
        return buf
    }

    static let ffmpegExts: Set<String> = ["mp3", "ogg", "opus", "wma"]

    static func write(_ buf: AVAudioPCMBuffer, to url: URL, ext: String, bitRate: Int = 256_000) throws {
        if ffmpegExts.contains(ext) {
            let tmp = Output.temporary(ext: "wav")
            defer { try? FileManager.default.removeItem(at: tmp) }
            try write(buf, to: tmp, ext: "wav")
            var args = ["-i", tmp.path] + (FFmpeg.audioCodecs[ext] ?? [])
            if ext != "ogg", let i = args.firstIndex(of: "-q:a") { args.removeSubrange(i...i+1); args += ["-b:a", "\(bitRate / 1000)k"] }
            try FFmpeg.run(args + [url.path], for: ext.uppercased())
            return
        }
        var buffer = buf
        // AAC is limited to 48 kHz; resample if needed.
        var rate = bitRate
        if ["m4a", "aac"].contains(ext) {
            // AAC wants 32–48 kHz and a bit rate the channel count can carry.
            let sr = buf.format.sampleRate
            if sr > 48_000 || sr < 32_000 { buffer = try resample(buf, to: sr > 48_000 ? 48_000 : 44_100) }
            // The encoder silently ignores rates it doesn't support, so snap to a standard one.
            let cap = min(bitRate, 128_000 * Int(buffer.format.channelCount))
            let standard = [32_000, 48_000, 64_000, 96_000, 128_000, 160_000, 192_000, 256_000]
            rate = standard.last { $0 <= cap } ?? 32_000
        }
        let s = settings(ext: ext, sampleRate: buffer.format.sampleRate,
                         channels: Int(buffer.format.channelCount), bitRate: rate)
        // AVAudioFile pads M4A files with a large "free" atom, so encode to a temp file and remux.
        let isAAC = ["m4a", "aac"].contains(ext)
        let target = isAAC ? Output.temporary(ext: "m4a") : url
        do {
            let file = try AVAudioFile(forWriting: target, settings: s, commonFormat: .pcmFormatFloat32, interleaved: false)
            try file.write(from: buffer)
            file.close()
        } catch {
            try? FileManager.default.removeItem(at: target)
            throw error
        }
        if isAAC {
            defer { try? FileManager.default.removeItem(at: target) }
            let done = DispatchSemaphore(value: 0)
            var failed = true
            Task.detached {
                failed = (try? await VideoOps.export(AVURLAsset(url: target), preset: AVAssetExportPresetPassthrough,
                                                     to: url, ext: "m4a")) == nil
                done.signal()
            }
            done.wait()
            if failed {
                try? FileManager.default.removeItem(at: url)
                try FileManager.default.moveItem(at: target, to: url)
            }
        }
    }

    static func resample(_ buf: AVAudioPCMBuffer, to rate: Double) throws -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: buf.format.channelCount)!
        guard let conv = AVAudioConverter(from: buf.format, to: fmt),
              let out = AVAudioPCMBuffer(pcmFormat: fmt,
                                         frameCapacity: AVAudioFrameCount(Double(buf.frameLength) * rate / buf.format.sampleRate) + 1024)
        else { throw AppError("Couldn’t resample audio") }
        var fed = false
        var err: NSError?
        conv.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .endOfStream; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if let err { throw err }
        return out
    }

    /// Output extension for an edit of `src`: same format when we can write it, otherwise M4A.
    static func editExt(_ src: URL) -> String {
        let e = Catalog.normalizedExt(src)
        if writableFormats.contains(e.uppercased()) { return e }
        return ffmpegExts.contains(e) && FFmpeg.isAvailable ? e : "m4a"
    }

    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let out = Output.url(for: src, ext: ext)
        if ffmpegExts.contains(ext) {
            try FFmpeg.convert(src, to: out, ext: ext, audioOnly: true)
        } else {
            try write(try readAll(src), to: out, ext: ext)
        }
        return out
    }

    static func compress(_ src: URL) async throws -> URL {
        let buf = try readAll(src)
        let out = Output.url(for: src, suffix: "compressed", ext: "m4a")
        try write(buf, to: out, ext: "m4a", bitRate: 96_000)
        return out
    }

    static func process(_ src: URL, suffix: String, _ transform: (AVAudioPCMBuffer) -> AVAudioPCMBuffer) async throws -> URL {
        let result = transform(try readAll(src))
        let ext = editExt(src)
        let out = Output.url(for: src, suffix: suffix, ext: ext)
        try write(result, to: out, ext: ext)
        return out
    }

    static func join(_ urls: [URL]) async throws -> URL {
        let sorted = urls.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var parts: [AVAudioPCMBuffer] = []
        for u in sorted { parts.append(try readAll(u)) }
        let rate = parts[0].format.sampleRate
        let channels = parts.map { $0.format.channelCount }.max()!
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        var normalized: [AVAudioPCMBuffer] = []
        for p in parts {
            var b = p.format.sampleRate == rate ? p : try resample(p, to: rate)
            if b.format.channelCount < channels { b = stereo(b) }
            normalized.append(b)
        }
        let total = normalized.reduce(0) { $0 + Int($1.frameLength) }
        let out = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(total))!
        var offset = 0
        for b in normalized {
            for c in 0..<Int(channels) {
                memcpy(out.floatChannelData![c] + offset, b.floatChannelData![c], Int(b.frameLength) * 4)
            }
            offset += Int(b.frameLength)
        }
        out.frameLength = AVAudioFrameCount(total)
        let ext = editExt(sorted[0])
        let url = Output.url(for: sorted[0], suffix: "joined", ext: ext)
        try write(out, to: url, ext: ext)
        return url
    }

    // MARK: Buffer transforms

    static func make(_ rate: Double, _ channels: AVAudioChannelCount, _ frames: Int) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: channels)!
        let b = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(frames, 1)))!
        b.frameLength = AVAudioFrameCount(frames)
        return b
    }

    static func slice(_ b: AVAudioPCMBuffer, from: Int, to: Int) -> AVAudioPCMBuffer {
        let start = max(0, min(from, Int(b.frameLength))), end = max(start, min(to, Int(b.frameLength)))
        let out = make(b.format.sampleRate, b.format.channelCount, end - start)
        for c in 0..<Int(b.format.channelCount) {
            memcpy(out.floatChannelData![c], b.floatChannelData![c] + start, (end - start) * 4)
        }
        return out
    }

    static func normalize(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        var peak: Float = 0
        for c in 0..<Int(b.format.channelCount) {
            let d = b.floatChannelData![c]
            for i in 0..<Int(b.frameLength) { peak = max(peak, abs(d[i])) }
        }
        guard peak > 0 else { return b }
        let gain = 0.98 / peak
        for c in 0..<Int(b.format.channelCount) {
            let d = b.floatChannelData![c]
            for i in 0..<Int(b.frameLength) { d[i] *= gain }
        }
        return b
    }

    static func mono(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let n = Int(b.frameLength), ch = Int(b.format.channelCount)
        let out = make(b.format.sampleRate, 1, n)
        let o = out.floatChannelData![0]
        for i in 0..<n {
            var sum: Float = 0
            for c in 0..<ch { sum += b.floatChannelData![c][i] }
            o[i] = sum / Float(ch)
        }
        return out
    }

    static func stereo(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let src = b.format.channelCount == 1 ? b : mono(b)
        let n = Int(src.frameLength)
        let out = make(src.format.sampleRate, 2, n)
        for c in 0..<2 { memcpy(out.floatChannelData![c], src.floatChannelData![0], n * 4) }
        return out
    }

    static func fade(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let n = Int(b.frameLength)
        let len = min(Int(b.format.sampleRate * 2), n / 2)
        guard len > 0 else { return b }
        for c in 0..<Int(b.format.channelCount) {
            let d = b.floatChannelData![c]
            for i in 0..<len {
                let g = Float(i) / Float(len)
                d[i] *= g
                d[n - 1 - i] *= g
            }
        }
        return b
    }

    static func reverse(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        let n = Int(b.frameLength)
        for c in 0..<Int(b.format.channelCount) {
            let d = b.floatChannelData![c]
            var i = 0, j = n - 1
            while i < j { let t = d[i]; d[i] = d[j]; d[j] = t; i += 1; j -= 1 }
        }
        return b
    }

    /// Peak per bin, 0…1, for drawing waveforms.
    static func peaks(_ b: AVAudioPCMBuffer, bins: Int) -> [Float] {
        let n = Int(b.frameLength)
        guard n > 0 else { return [] }
        let per = max(1, n / bins)
        var out: [Float] = []
        out.reserveCapacity(bins)
        var i = 0
        while i < n {
            var p: Float = 0
            for c in 0..<Int(b.format.channelCount) {
                let d = b.floatChannelData![c]
                var k = i
                while k < min(i + per, n) { p = max(p, abs(d[k])); k += 4 }
            }
            out.append(min(p, 1))
            i += per
        }
        return out
    }
}
