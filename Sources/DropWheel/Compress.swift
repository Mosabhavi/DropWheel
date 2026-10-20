import AVFoundation
import AppKit
import ImageIO
import PDFKit
import SwiftUI
import UniformTypeIdentifiers

/// Compression for every kind, either by quality level or aiming for an exact file size.
enum Compressor {
    enum Level: Int, CaseIterable { case light, balanced, strong
        var title: String { ["Light", "Balanced", "Strong"][rawValue] }
    }
    enum Goal { case level(Level), targetBytes(Int) }

    static func compress(_ src: URL, goal: Goal) async throws -> URL {
        let out: URL
        switch FileKind.of(src) {
        case .image: out = try image(src, goal: goal)
        case .video: out = try await video(src, goal: goal)
        case .audio: out = try await audio(src, goal: goal)
        case .pdf: out = try pdf(src, goal: goal)
        default: throw AppError("Can’t compress \(src.lastPathComponent)")
        }
        // A "compressed" copy that isn't smaller is worse than none.
        if size(out) >= size(src) {
            try? FileManager.default.removeItem(at: out)
            throw AppError("\(src.lastPathComponent) is already as small as it gets — no copy saved")
        }
        return out
    }

    static func size(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    // MARK: Images

    static func encode(_ img: CGImage, ext: String, quality: Double, properties: [CFString: Any]) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType(filenameExtension: ext)!.identifier as CFString, 1, nil) else { return nil }
        var opts = properties
        opts[kCGImageDestinationLossyCompressionQuality] = quality
        let input = ext == "jpg" && ImageOps.hasAlpha(img) ? ImageOps.flatten(img) : img
        CGImageDestinationAddImage(dest, input, opts as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func image(_ src: URL, goal: Goal) throws -> URL {
        let full = try ImageOps.load(src)
        let ext = ImageOps.hasAlpha(full) && Catalog.normalizedExt(src) != "jpg" ? "heic" : "jpg"
        let meta = ImageOps.metadata(src)
        var data: Data?
        switch goal {
        case .level(let level):
            let (q, maxPx): (Double, Int?) = [(0.8, nil), (0.6, 3000), (0.4, 2000)][level.rawValue]
            let img = maxPx.map { (try? ImageOps.load(src, maxPixel: min($0, max(full.width, full.height)))) ?? full } ?? full
            data = encode(img, ext: ext, quality: q, properties: meta)
        case .targetBytes(let target):
            var img = full
            // Binary-search the quality; shrink the image if even the lowest quality is too big.
            for _ in 0..<8 {
                var lo = 0.05, hi = 0.95
                var best: Data?
                for _ in 0..<7 {
                    let mid = (lo + hi) / 2
                    guard let d = encode(img, ext: ext, quality: mid, properties: meta) else { break }
                    if d.count <= target { best = d; lo = mid } else { hi = mid }
                }
                if let best { data = best; break }
                let next = Int(Double(max(img.width, img.height)) * 0.75)
                guard next > 64 else { break }
                img = try ImageOps.load(src, maxPixel: next)
            }
            if data == nil { throw AppError("Couldn’t get the image under \(format(target))") }
        }
        guard let data else { throw AppError("Couldn’t compress image") }
        let out = Output.url(for: src, suffix: "compressed", ext: ext)
        try data.write(to: out)
        return out
    }

    // MARK: Video

    static func video(_ src: URL, goal: Goal) async throws -> URL {
        let asset = try await VideoOps.readableAsset(src)
        let out = Output.url(for: src, suffix: "compressed", ext: "mp4")
        switch goal {
        case .level(let level):
            // Aim for a share of the original's size so the result is reliably smaller.
            let share = [0.7, 0.45, 0.25][level.rawValue]
            let target = Int(Double(size(src)) * share)
            do {
                return try await video(src, goal: .targetBytes(target))
            } catch {
                try? FileManager.default.removeItem(at: out)
                let preset = [AVAssetExportPresetHEVCHighestQuality, AVAssetExportPresetHEVC1920x1080, AVAssetExportPreset1280x720][level.rawValue]
                try await VideoOps.export(asset, preset: preset, to: out, ext: "mp4")
            }
        case .targetBytes(let target):
            let seconds = try await asset.load(.duration).seconds
            guard seconds > 0 else { throw AppError("Video has no duration") }
            let hasAudio = !(try await asset.loadTracks(withMediaType: .audio)).isEmpty
            let audioRate = hasAudio ? 96_000 : 0
            // Leave ~4% for container overhead.
            let videoRate = Int(Double(target) * 8 * 0.96 / seconds) - audioRate
            guard videoRate > 100_000 else { throw AppError("\(format(target)) is too small for a \(Int(seconds))-second video") }
            let maxDim: CGFloat = videoRate < 1_200_000 ? 854 : videoRate < 3_000_000 ? 1280 : videoRate < 8_000_000 ? 1920 : 3840
            try await transcode(asset, to: out, videoBitRate: videoRate, audioBitRate: audioRate, maxDimension: maxDim)
        }
        return out
    }

    /// Re-encodes with AVAssetWriter at a fixed average bit rate (HEVC + AAC).
    static func transcode(_ asset: AVAsset, to out: URL, videoBitRate: Int, audioBitRate: Int, maxDimension: CGFloat) async throws {
        guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else { throw AppError("No video track") }
        let natural = try await vTrack.load(.naturalSize)
        let transform = try await vTrack.load(.preferredTransform)
        let scale = min(1, maxDimension / max(natural.width, natural.height))
        let w = Int(natural.width * scale) / 2 * 2, h = Int(natural.height * scale) / 2 * 2

        let reader = try AVAssetReader(asset: asset)
        // The web-optimising pass leaves a backup file beside its output, so write in the temp folder.
        let tmp = Output.temporary(ext: "mp4")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let writer = try AVAssetWriter(outputURL: tmp, fileType: .mp4)
        writer.shouldOptimizeForNetworkUse = true

        let vOut = AVAssetReaderTrackOutput(track: vTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ])
        vOut.alwaysCopiesSampleData = false
        reader.add(vOut)
        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: w, AVVideoHeightKey: h,
            AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: videoBitRate],
        ])
        vIn.transform = transform
        vIn.expectsMediaDataInRealTime = false
        writer.add(vIn)

        var pairs: [(AVAssetReaderOutput, AVAssetWriterInput)] = [(vOut, vIn)]
        if audioBitRate > 0, let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
            let aOut = AVAssetReaderTrackOutput(track: aTrack, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM])
            reader.add(aOut)
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVNumberOfChannelsKey: 2, AVSampleRateKey: 44_100,
                AVEncoderBitRateKey: audioBitRate,
            ])
            writer.add(aIn)
            pairs.append((aOut, aIn))
        }

        guard reader.startReading() else { throw reader.error ?? AppError("Couldn’t read video") }
        guard writer.startWriting() else { throw writer.error ?? AppError("Couldn’t write video") }
        writer.startSession(atSourceTime: .zero)

        await withTaskGroup(of: Void.self) { group in
            for (i, (output, input)) in pairs.enumerated() {
                group.addTask {
                    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
                        let queue = DispatchQueue(label: "dropwheel.transcode.\(i)")
                        input.requestMediaDataWhenReady(on: queue) {
                            while input.isReadyForMoreMediaData {
                                if let sample = output.copyNextSampleBuffer() {
                                    input.append(sample)
                                } else {
                                    input.markAsFinished()
                                    done.resume()
                                    return
                                }
                            }
                        }
                    }
                }
            }
        }
        if reader.status == .failed { writer.cancelWriting(); throw reader.error ?? AppError("Couldn’t read video") }
        await writer.finishWriting()
        if writer.status != .completed { throw writer.error ?? AppError("Couldn’t write video") }
        try FileManager.default.moveItem(at: tmp, to: out)
    }

    // MARK: Audio

    static func audio(_ src: URL, goal: Goal) async throws -> URL {
        let buf = try AudioOps.readAll(src)
        let seconds = Double(buf.frameLength) / buf.format.sampleRate
        let rate: Int
        switch goal {
        case .level(let level): rate = [160_000, 96_000, 64_000][level.rawValue]
        case .targetBytes(let target): rate = min(320_000, max(24_000, Int(Double(target) * 8 * 0.97 / seconds)))
        }
        let ext = Catalog.normalizedExt(src) == "mp3" && FFmpeg.isAvailable ? "mp3" : "m4a"
        let out = Output.url(for: src, suffix: "compressed", ext: ext)
        // Low bit rates sound better in mono.
        let input = rate < 64_000 && buf.format.channelCount > 1 ? AudioOps.mono(buf) : buf
        try AudioOps.write(input, to: out, ext: ext, bitRate: rate)
        return out
    }

    // MARK: PDF

    static func pdf(_ src: URL, goal: Goal) throws -> URL {
        let out = Output.url(for: src, suffix: "compressed", ext: "pdf")
        let doc = try PDFOps.open(src)
        func optimized(jpeg: Bool) -> Data? {
            let tmp = Output.temporary(ext: "pdf")
            defer { try? FileManager.default.removeItem(at: tmp) }
            var opts: [PDFDocumentWriteOption: Any] = [.optimizeImagesForScreenOption: true]
            if jpeg { opts[.saveImagesAsJPEGOption] = true }
            return doc.write(to: tmp, withOptions: opts) ? try? Data(contentsOf: tmp) : nil
        }
        func rasterized(dpi: CGFloat, quality: Double) -> Data? {
            let result = PDFDocument()
            for i in 0..<doc.pageCount {
                guard let page = doc.page(at: i) else { continue }
                let box = page.bounds(for: .cropBox)
                let img = page.thumbnail(of: NSSize(width: box.width * dpi / 72, height: box.height * dpi / 72), for: .cropBox)
                guard let p = PDFPage(image: img, options: [.mediaBox: NSRect(origin: .zero, size: box.size),
                                                             .compressionQuality: quality]) else { continue }
                result.insert(p, at: result.pageCount)
            }
            return result.dataRepresentation()
        }
        var data: Data?
        switch goal {
        case .level(.light): data = optimized(jpeg: false)
        case .level(.balanced): data = optimized(jpeg: true)
        case .level(.strong): data = rasterized(dpi: 110, quality: 0.5)
        case .targetBytes(let target):
            let attempts: [() -> Data?] = [
                { optimized(jpeg: false) }, { optimized(jpeg: true) },
                { rasterized(dpi: 150, quality: 0.7) }, { rasterized(dpi: 120, quality: 0.55) },
                { rasterized(dpi: 96, quality: 0.45) }, { rasterized(dpi: 72, quality: 0.35) },
            ]
            var smallest: Data?
            for attempt in attempts {
                guard let d = attempt() else { continue }
                if smallest == nil || d.count < smallest!.count { smallest = d }
                if d.count <= target { data = d; break }
            }
            if data == nil {
                if let smallest { try smallest.write(to: out) }
                throw AppError("Smallest possible is \(format(smallest?.count ?? 0)); saved that instead")
            }
        }
        guard let data else { throw AppError("Couldn’t compress PDF") }
        try data.write(to: out)
        return out
    }

    static func format(_ bytes: Int) -> String { ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file) }
}

// MARK: - Panel

final class CompressModel: ObservableObject {
    let urls: [URL]
    let originalBytes: Int
    @Published var exact = false
    @Published var level = Compressor.Level.balanced
    @Published var targetMB: Double

    init(urls: [URL]) {
        self.urls = urls
        let first = urls.first.flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize } ?? 0
        originalBytes = first
        targetMB = max(0.05, (Double(first) / 1_000_000 / 2 * 100).rounded() / 100)
    }
}

@MainActor enum CompressPanel {
    static func open(_ urls: [URL]) {
        let model = CompressModel(urls: urls)
        _ = Windows.show("Compress", size: NSSize(width: 440, height: 300)) { close in
            CompressView(m: model, close: close)
        }
    }
}

struct CompressView: View {
    @ObservedObject var m: CompressModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text(m.urls.count == 1 ? m.urls[0].lastPathComponent : "\(m.urls.count) files").font(.headline).lineLimit(1)
                Spacer()
                Text(Compressor.format(m.originalBytes)).foregroundStyle(.secondary)
            }
            Picker("", selection: $m.exact) {
                Text("By Quality").tag(false)
                Text("Exact File Size").tag(true)
            }
            .pickerStyle(.segmented)

            if m.exact {
                HStack {
                    Text("Make it at most")
                    TextField("", value: $m.targetMB, format: .number.precision(.fractionLength(0...2)))
                        .frame(width: 80).multilineTextAlignment(.trailing)
                    Text("MB")
                    Stepper("", value: $m.targetMB, in: 0.01...10_000, step: m.targetMB < 1 ? 0.05 : 0.5).labelsHidden()
                }
                Text("DropWheel picks the best quality that fits. Images and PDFs may be scaled down to get there.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("", selection: $m.level) {
                    ForEach(Compressor.Level.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(["Smaller file, no visible difference.", "Good balance of size and quality.", "Smallest file; quality and resolution drop."][m.level.rawValue])
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Compress") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 16, trailing: 18))
    }

    private func apply() {
        let goal: Compressor.Goal = m.exact ? .targetBytes(Int(m.targetMB * 1_000_000)) : .level(m.level)
        let urls = m.urls
        close()
        Windows.finishMany {
            var outs: [URL] = []
            for u in urls { outs.append(try await Compressor.compress(u, goal: goal)) }
            return outs
        }
    }
}
