import AVFoundation
import CoreImage
import SwiftUI
import AppKit

/// `DropWheel --test-panels <image> <audio> <video> <pdf>` drives every window's save path without UI.
enum SelfTest {
    @MainActor static func panels(image: URL, audio: URL, video: URL, pdf: URL) async {
        func check(_ name: String, _ body: () async throws -> [URL]) async {
            do {
                let outs = try await body()
                let sizes = outs.map { u -> String in
                    let s = (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                    return "\(u.lastPathComponent) (\(ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file)))"
                }
                print("OK   \(name): \(sizes.joined(separator: ", "))")
            } catch {
                print("FAIL \(name): \(error.localizedDescription)")
            }
        }

        await check("Crop") {
            let m = try EditorModel(url: image, mode: .crop)
            m.setAspect(1)
            m.rotate(clockwise: true)
            return [try m.save()]
        }
        await check("Redact (pixelate + black)") {
            let m = try EditorModel(url: image, mode: .redact)
            m.boxes = [CGRect(x: 0.1, y: 0.1, width: 0.3, height: 0.2)]
            m.style = .black
            m.boxes.append(CGRect(x: 0.5, y: 0.5, width: 0.3, height: 0.3))
            return [try m.save()]
        }
        await check("Annotate") {
            let m = try EditorModel(url: image, mode: .annotate)
            m.marks = [
                Mark(tool: .arrow, points: [CGPoint(x: 0.1, y: 0.1), CGPoint(x: 0.5, y: 0.5)], color: .systemRed, width: 6),
                Mark(tool: .rectangle, points: [CGPoint(x: 0.6, y: 0.2), CGPoint(x: 0.9, y: 0.4)], color: .systemBlue, width: 4),
                Mark(tool: .text, points: [CGPoint(x: 0.1, y: 0.8)], color: .white, width: 8, text: "Hello"),
            ]
            return [try m.save()]
        }
        await check("Add BG") { [try BackgroundModel(url: image).save()] }
        await check("Compress image → 200 KB") { [try await Compressor.compress(image, goal: .targetBytes(200_000))] }
        await check("Metadata write image") {
            [try await MetadataIO.write(image, kind: .image, changes: ["title": "Test", "author": "DropWheel", "keywords": "a, b"], removeLocation: true)]
        }
        await check("Bleep") {
            let m = try BleepModel(url: audio)
            return [try await AudioOps.process(audio, suffix: "bleeped") { AudioOps.bleep($0, ranges: [0.2...0.4]) }]
                + (m.ranges.isEmpty ? [] : [])
        }
        await check("Channels → stereo") {
            let m = try ChannelsModel(url: audio)
            m.stereo = true
            m.left = 50
            return [try await AudioOps.process(audio, suffix: "stereo") { _ in m.output() }]
        }
        await check("Compress audio → 30 KB") { [try await Compressor.compress(audio, goal: .targetBytes(30_000))] }
        await check("Metadata write audio") { [try await MetadataIO.write(audio, kind: .audio, changes: ["title": "Voice"], removeLocation: false)] }
        await check("Compress video (level)") { [try await Compressor.compress(video, goal: .level(.strong))] }
        await check("Compress video → 400 KB") { [try await Compressor.compress(video, goal: .targetBytes(400_000))] }
        await check("Video crop") { [try await VideoOps.crop(video, rect: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5))] }
        await check("Video split") { try await VideoOps.split(video, at: CMTime(seconds: 1.5, preferredTimescale: 600)) }
        await check("Video snapshot") { [try await VideoOps.snapshot(video, at: CMTime(seconds: 1, preferredTimescale: 600))] }
        await check("Video speed 0.5×") { [try await VideoOps.changeSpeed(video, factor: 0.5)] }
        await check("Metadata write video") { [try await MetadataIO.write(video, kind: .video, changes: ["title": "Clip"], removeLocation: false)] }
        await check("PDF organize") {
            let m = try OrganizeModel(url: pdf)
            m.pages.reverse()
            if !m.pages.isEmpty { m.pages[0].rotation = 90 }
            return [try m.save()]
        }
        await check("Compress PDF (strong)") { [try await Compressor.compress(pdf, goal: .level(.strong))] }
        await check("Metadata write PDF") { [try await MetadataIO.write(pdf, kind: .pdf, changes: ["title": "Doc", "keywords": "x, y"], removeLocation: false)] }
    }
}

extension SelfTest {
    /// `DropWheel --render-panel <crop|redact|annotate|addbg|bleep|channels|compress|metadata|organize|edit|trim> <file> <out.png>`
    @MainActor static func renderPanel(_ name: String, file: URL, out: URL) async throws {
        let size: NSSize
        let view: AnyView
        switch name {
        case "crop", "redact", "annotate":
            let mode: EditorMode = name == "crop" ? .crop : name == "redact" ? .redact : .annotate
            let m = try EditorModel(url: file, mode: mode)
            if mode == .redact { m.boxes = [CGRect(x: 0.3, y: 0.2, width: 0.3, height: 0.25)] }
            if mode == .annotate {
                m.marks = [Mark(tool: .arrow, points: [CGPoint(x: 0.15, y: 0.8), CGPoint(x: 0.45, y: 0.45)], color: .systemRed, width: 6),
                           Mark(tool: .text, points: [CGPoint(x: 0.1, y: 0.85)], color: .white, width: 7, text: "Look!")]
            }
            if mode == .crop { m.setAspect(1) }
            size = NSSize(width: 760, height: 680)
            view = AnyView(ImageEditorView(m: m, close: {}))
        case "addbg":
            size = NSSize(width: 620, height: 640)
            let m = try BackgroundModel(url: file)
            m.fill = .color(.blue)
            view = AnyView(AddBackgroundView(m: m, close: {}))
        case "bleep":
            let m = try BleepModel(url: file)
            m.ranges = [0.3...0.42, 0.7...0.8]
            size = NSSize(width: 620, height: 360)
            view = AnyView(BleepView(m: m, close: {}))
        case "channels":
            size = NSSize(width: 520, height: 400)
            view = AnyView(ChannelsView(m: try ChannelsModel(url: file), close: {}))
        case "compress":
            size = NSSize(width: 440, height: 300)
            view = AnyView(CompressView(m: CompressModel(urls: [file]), close: {}))
        case "metadata":
            let m = MetadataModel(url: file)
            m.rows = await MetadataPanel.collect(file)
            m.fields = await MetadataIO.read(file, kind: m.kind)
            size = NSSize(width: 560, height: 640)
            view = AnyView(MetadataView(m: m, close: {}))
        case "organize":
            size = NSSize(width: 720, height: 600)
            view = AnyView(OrganizeView(m: try OrganizeModel(url: file), close: {}))
        case "edit":
            size = NSSize(width: 520, height: 720)
            view = AnyView(EditPhotoView(url: file, base: CIImage(cgImage: try ImageOps.load(file, maxPixel: 1400)), close: {}))
        case "trim":
            size = NSSize(width: 560, height: 330)
            view = AnyView(AudioTrimView(url: file, buffer: try AudioOps.readAll(file), close: {}))
        default:
            throw AppError("Unknown panel \(name)")
        }
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -3000, y: -3000), size: size),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.appearance = NSAppearance(named: .aqua)
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        window.contentView = host
        window.orderFrontRegardless()
        try await Task.sleep(for: .milliseconds(900))
        host.layoutSubtreeIfNeeded()
        let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: rep)
        try rep.representation(using: .png, properties: [:])!.write(to: out)
        window.orderOut(nil)
    }
}
