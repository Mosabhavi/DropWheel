import AVFoundation
import AVKit
import AppKit
import ImageIO
import PDFKit
import SwiftUI

// MARK: - Video operations used by the panels

extension VideoOps {
    static func crop(_ src: URL, rect: CGRect) async throws -> URL {
        let asset = try await readableAsset(src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw AppError("No video track") }
        let natural = try await track.load(.naturalSize)
        let t = try await track.load(.preferredTransform)
        let fps = try await track.load(.nominalFrameRate)
        let duration = try await asset.load(.duration)
        let shown = CGRect(origin: .zero, size: natural).applying(t)
        let W = abs(shown.width), H = abs(shown.height)
        // Even pixel sizes keep encoders happy.
        let crop = CGRect(x: (rect.minX * W).rounded(), y: (rect.minY * H).rounded(),
                          width: (rect.width * W / 2).rounded() * 2, height: (rect.height * H / 2).rounded() * 2)

        let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: track)
        layer.setTransform(t.concatenating(CGAffineTransform(translationX: -shown.minX - crop.minX, y: -shown.minY - crop.minY)), at: .zero)
        let instruction = AVMutableVideoCompositionInstruction()
        instruction.timeRange = CMTimeRange(start: .zero, duration: duration)
        instruction.layerInstructions = [layer]
        let comp = AVMutableVideoComposition()
        comp.renderSize = crop.size
        comp.frameDuration = CMTime(value: 1, timescale: CMTimeScale(fps > 0 ? fps.rounded() : 30))
        comp.instructions = [instruction]

        let out = Output.url(for: src, suffix: "cropped", ext: "mp4")
        try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, ext: "mp4", videoComposition: comp)
        return out
    }

    static func split(_ src: URL, at time: CMTime) async throws -> [URL] {
        let asset = try await readableAsset(src)
        let duration = try await asset.load(.duration)
        guard time > .zero, time < duration else { throw AppError("Move the playhead to where the video should be split") }
        let ext = sameExt(src)
        var outs: [URL] = []
        for (i, range) in [CMTimeRange(start: .zero, end: time), CMTimeRange(start: time, end: duration)].enumerated() {
            let out = Output.url(for: src, suffix: "part \(i + 1)", ext: ext)
            do {
                try await export(asset, preset: AVAssetExportPresetPassthrough, to: out, ext: ext, timeRange: range)
            } catch {
                try? FileManager.default.removeItem(at: out)
                try await export(asset, preset: AVAssetExportPresetHighestQuality, to: out, ext: ext, timeRange: range)
            }
            outs.append(out)
        }
        return outs
    }

    static func frame(_ src: URL, at time: CMTime) async throws -> CGImage {
        let asset = try await readableAsset(src)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = .zero
        return try await gen.image(at: time).image
    }

    static func snapshot(_ src: URL, at time: CMTime) async throws -> URL {
        let img = try await frame(src, at: time)
        let secs = String(format: "%.2fs", time.seconds)
        let out = Output.url(for: src, suffix: "snapshot \(secs)", ext: "png")
        try ImageOps.write(img, to: out, ext: "png")
        return out
    }
}

// MARK: - Video crop

@MainActor enum VideoCropPanel {
    static func open(_ url: URL) {
        Task { @MainActor in
            do {
                let asset = try await VideoOps.readableAsset(url)
                let d = try await asset.load(.duration)
                let frame = try await VideoOps.frame(url, at: CMTimeMultiplyByFloat64(d, multiplier: 0.25))
                let model = EditorModel(frame: frame, url: url) { rect in try await VideoOps.crop(url, rect: rect) }
                _ = Windows.show("Crop Video", size: NSSize(width: 760, height: 620)) { close in
                    ImageEditorView(m: model, close: close)
                }
            } catch {
                Toast.shared.show(error.localizedDescription, style: .error)
            }
        }
    }
}

// MARK: - Split / Snapshot

@MainActor enum VideoPlayerPanel {
    enum Mode { case split, snapshot }

    static func open(_ url: URL, mode: Mode) {
        Task { @MainActor in
            do {
                let asset = try await VideoOps.readableAsset(url)
                let player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
                let window = Windows.show(mode == .split ? "Split Video" : "Take Snapshots", size: NSSize(width: 760, height: 520)) { close in
                    VideoPlayerView(url: url, player: player, mode: mode, close: close)
                }
                NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                    player.pause()
                }
            } catch {
                Toast.shared.show(error.localizedDescription, style: .error)
            }
        }
    }
}

struct PlayerViewRep: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .inline
        v.showsFrameSteppingButtons = true
        return v
    }
    func updateNSView(_ nsView: AVPlayerView, context: Context) {}
}

struct VideoPlayerView: View {
    let url: URL
    let player: AVPlayer
    let mode: VideoPlayerPanel.Mode
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            PlayerViewRep(player: player).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(mode == .split ? "Pause where the video should be cut, then split."
                                    : "Pause on any frame and save it as a PNG. Take as many as you like.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: close).keyboardShortcut(.cancelAction)
                if mode == .split {
                    Button { split() } label: { Label("Split Here", systemImage: "scissors") }.keyboardShortcut(.defaultAction)
                } else {
                    Button { snap() } label: { Label("Take Snapshot", systemImage: "camera") }.keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(EdgeInsets(top: 34, leading: 16, bottom: 16, trailing: 16))
    }

    private func split() {
        player.pause()
        let t = player.currentTime(), url = url
        close()
        Windows.finishMany { try await VideoOps.split(url, at: t) }
    }

    private func snap() {
        player.pause()
        let t = player.currentTime(), url = url
        Windows.finish { try await VideoOps.snapshot(url, at: t) }
    }
}

// MARK: - Speed

final class SpeedModel: ObservableObject {
    @Published var factor = 2.0
    @Published var keepPitch = true
}

@MainActor enum SpeedPanel {
    static func open(_ url: URL) {
        let model = SpeedModel()
        _ = Windows.show("Change Speed", size: NSSize(width: 460, height: 210)) { close in
            SpeedView(url: url, m: model, close: close)
        }
    }
}

struct SpeedView: View {
    let url: URL
    @ObservedObject var m: SpeedModel
    let close: () -> Void
    private let choices: [Double] = [0.25, 0.5, 0.75, 1.25, 1.5, 2, 3, 4]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("", selection: $m.factor) {
                ForEach(choices, id: \.self) { Text(String(format: "%g×", $0)).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle("Keep the pitch of voices natural", isOn: $m.keepPitch)
            Spacer()
            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply") {
                    let f = m.factor, k = m.keepPitch, url = url
                    close()
                    Windows.finish { try await VideoOps.changeSpeed(url, factor: f, keepPitch: k) }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 16, trailing: 18))
    }
}

// MARK: - PDF Organize

final class OrganizeModel: ObservableObject {
    struct Page: Identifiable { let id = UUID(); let index: Int; var rotation: Int; let thumb: NSImage }
    let url: URL
    let doc: PDFDocument
    @Published var pages: [Page]
    @Published var selected: UUID?

    init(url: URL) throws {
        self.url = url
        let doc = try PDFOps.open(url)
        self.doc = doc
        pages = (0..<doc.pageCount).compactMap { i in
            guard let p = doc.page(at: i) else { return nil }
            return Page(index: i, rotation: 0, thumb: p.thumbnail(of: NSSize(width: 220, height: 220), for: .cropBox))
        }
    }

    var selectedIndex: Int? { pages.firstIndex { $0.id == selected } }

    func move(_ delta: Int) {
        guard let i = selectedIndex, pages.indices.contains(i + delta) else { return }
        pages.swapAt(i, i + delta)
    }

    func save() throws -> URL {
        let result = PDFDocument()
        for p in pages {
            guard let page = doc.page(at: p.index)?.copy() as? PDFPage else { continue }
            page.rotation += p.rotation
            result.insert(page, at: result.pageCount)
        }
        return try PDFOps.save(result, to: Output.url(for: url, suffix: "organized", ext: "pdf"))
    }
}

@MainActor enum PDFOrganizePanel {
    static func open(_ url: URL) {
        do {
            let model = try OrganizeModel(url: url)
            _ = Windows.show("Organize Pages", size: NSSize(width: 720, height: 600)) { close in
                OrganizeView(m: model, close: close)
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
    }
}

struct OrganizeView: View {
    @ObservedObject var m: OrganizeModel
    let close: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Button { m.move(-1) } label: { Image(systemName: "arrow.left") }.help("Move Earlier")
                Button { m.move(1) } label: { Image(systemName: "arrow.right") }.help("Move Later")
                Button { if let i = m.selectedIndex { m.pages[i].rotation -= 90 } } label: { Image(systemName: "rotate.left") }
                Button { if let i = m.selectedIndex { m.pages[i].rotation += 90 } } label: { Image(systemName: "rotate.right") }
                Button {
                    if let i = m.selectedIndex {
                        let p = m.pages[i]
                        m.pages.insert(OrganizeModel.Page(index: p.index, rotation: p.rotation, thumb: p.thumb), at: i + 1)
                    }
                } label: { Image(systemName: "plus.square.on.square") }.help("Duplicate")
                Button(role: .destructive) {
                    if let i = m.selectedIndex, m.pages.count > 1 { m.pages.remove(at: i); m.selected = nil }
                } label: { Image(systemName: "trash") }.help("Delete Page")
                Spacer()
                Button("Reverse") { m.pages.reverse() }
            }
            .disabled(false)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 14)], spacing: 14) {
                    ForEach(Array(m.pages.enumerated()), id: \.element.id) { i, page in
                        VStack(spacing: 4) {
                            Image(nsImage: page.thumb).resizable().scaledToFit()
                                .rotationEffect(.degrees(Double(page.rotation)))
                                .frame(height: 150)
                                .padding(6)
                                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                                .overlay(RoundedRectangle(cornerRadius: 6)
                                    .stroke(m.selected == page.id ? Color.red : Color.gray.opacity(0.3), lineWidth: m.selected == page.id ? 3 : 1))
                            Text("\(i + 1)").font(.caption).foregroundStyle(.secondary)
                        }
                        .onTapGesture { m.selected = page.id }
                    }
                }
                .padding(4)
            }
            HStack {
                Text("Select a page, then move, rotate, duplicate or delete it.").font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save") { let m = m; close(); Windows.finish { try m.save() } }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 16, bottom: 16, trailing: 16))
    }
}

// MARK: - Metadata (view + edit)

final class MetadataModel: ObservableObject {
    struct Field: Identifiable { let id: String; let label: String; var value: String }
    let url: URL
    let kind: FileKind
    @Published var rows: [(String, String)] = []
    @Published var fields: [Field] = []
    @Published var removeLocation = false
    var original: [String: String] = [:]

    init(url: URL) {
        self.url = url
        kind = FileKind.of(url)
    }

    var editable: Bool { [FileKind.image, .video, .audio, .pdf].contains(kind) }
}

@MainActor enum MetadataPanel {
    static func open(_ url: URL) {
        Task { @MainActor in
            let model = MetadataModel(url: url)
            model.rows = await collect(url)
            model.fields = await MetadataIO.read(url, kind: model.kind)
            model.original = Dictionary(uniqueKeysWithValues: model.fields.map { ($0.id, $0.value) })
            _ = Windows.show("Metadata — \(url.lastPathComponent)", size: NSSize(width: 560, height: 640)) { close in
                MetadataView(m: model, close: close)
            }
        }
    }

    static func collect(_ url: URL) async -> [(String, String)] {
        var rows: [(String, String)] = []
        if let v = try? url.resourceValues(forKeys: [.fileSizeKey, .creationDateKey, .contentModificationDateKey, .contentTypeKey]) {
            if let s = v.fileSize { rows.append(("File Size", ByteCountFormatter.string(fromByteCount: Int64(s), countStyle: .file))) }
            if let t = v.contentType { rows.append(("Kind", t.localizedDescription ?? t.identifier)) }
            if let d = v.creationDate { rows.append(("Created", d.formatted())) }
            if let d = v.contentModificationDate { rows.append(("Modified", d.formatted())) }
        }
        switch FileKind.of(url) {
        case .image:
            if let src = CGImageSourceCreateWithURL(url as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [String: Any] {
                flatten(props, prefix: "", into: &rows)
            }
        case .video, .audio:
            guard let asset = try? await VideoOps.readableAsset(url) else { break }
            if let d = try? await asset.load(.duration) { rows.append(("Duration", AudioTrimView.time(d.seconds))) }
            if let tracks = try? await asset.load(.tracks) {
                for t in tracks {
                    var desc = t.mediaType.rawValue
                    if t.mediaType == .video, let size = try? await t.load(.naturalSize) {
                        desc += " \(Int(size.width))×\(Int(size.height))"
                        if let fps = try? await t.load(.nominalFrameRate) { desc += String(format: " @ %.2f fps", fps) }
                    }
                    if let rate = try? await t.load(.estimatedDataRate), rate > 0 { desc += " · \(Int(rate / 1000)) kbps" }
                    rows.append(("Track \(t.trackID)", desc))
                }
            }
            if let meta = try? await asset.load(.metadata) {
                for item in meta {
                    let key = item.commonKey?.rawValue ?? item.identifier?.rawValue ?? "Item"
                    if let v = try? await item.load(.stringValue) { rows.append((key, v)) }
                }
            }
        case .pdf:
            if let doc = PDFDocument(url: url) {
                rows.append(("Pages", "\(doc.pageCount)"))
                for (k, v) in doc.documentAttributes ?? [:] { rows.append(("\(k)", "\(v)")) }
            }
        default: break
        }
        return rows
    }

    private static func flatten(_ dict: [String: Any], prefix: String, into rows: inout [(String, String)]) {
        for key in dict.keys.sorted() {
            let name = prefix.isEmpty ? key : "\(prefix) › \(key)"
            if let sub = dict[key] as? [String: Any] {
                flatten(sub, prefix: key.trimmingCharacters(in: CharacterSet(charactersIn: "{}")), into: &rows)
            } else if let arr = dict[key] as? [Any] {
                rows.append((name, arr.map { "\($0)" }.joined(separator: ", ")))
            } else if let v = dict[key] {
                rows.append((name, "\(v)"))
            }
        }
    }
}

struct MetadataView: View {
    @ObservedObject var m: MetadataModel
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if m.editable {
                Text("Edit").font(.headline)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                    ForEach($m.fields) { $f in
                        GridRow {
                            Text(f.label).foregroundStyle(.secondary)
                            TextField(f.label, text: $f.value)
                        }
                    }
                }
                if m.kind == .image { Toggle("Remove GPS location", isOn: $m.removeLocation) }
            }
            Text("All Metadata").font(.headline).padding(.top, 4)
            List(Array(m.rows.enumerated()), id: \.offset) { _, row in
                HStack(alignment: .top) {
                    Text(row.0).foregroundStyle(.secondary).frame(width: 170, alignment: .leading)
                    Text(row.1).textSelection(.enabled)
                    Spacer(minLength: 0)
                }
                .font(.callout)
            }
            HStack {
                Button("Remove All Metadata") { strip() }.disabled(!m.editable)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                if m.editable { Button("Save Copy") { save() }.keyboardShortcut(.defaultAction) }
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 16, trailing: 18))
    }

    private func save() {
        let m = m
        let changed = Dictionary(uniqueKeysWithValues: m.fields.filter { m.original[$0.id] != $0.value }.map { ($0.id, $0.value) })
        let gps = m.removeLocation
        close()
        Windows.finish { try await MetadataIO.write(m.url, kind: m.kind, changes: changed, removeLocation: gps) }
    }

    private func strip() {
        let url = m.url, kind = m.kind
        close()
        Windows.finish {
            switch kind {
            case .image: return try ImageOps.stripMetadata(url)
            case .video: return try await VideoOps.stripMetadata(url)
            case .audio: return try await AudioOps.process(url, suffix: "no metadata") { $0 }
            default: return try PDFOps.stripMetadata(url)
            }
        }
    }
}

/// Reading and writing the common editable tags.
enum MetadataIO {
    typealias Field = MetadataModel.Field

    static func read(_ url: URL, kind: FileKind) async -> [Field] {
        switch kind {
        case .image:
            let props = (CGImageSourceCreateWithURL(url as CFURL, nil)
                .flatMap { CGImageSourceCopyPropertiesAtIndex($0, 0, nil) } as? [CFString: Any]) ?? [:]
            let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
            let iptc = props[kCGImagePropertyIPTCDictionary] as? [CFString: Any] ?? [:]
            let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
            return [
                Field(id: "title", label: "Title", value: tiff[kCGImagePropertyTIFFImageDescription] as? String ?? ""),
                Field(id: "author", label: "Author", value: tiff[kCGImagePropertyTIFFArtist] as? String ?? ""),
                Field(id: "copyright", label: "Copyright", value: tiff[kCGImagePropertyTIFFCopyright] as? String ?? ""),
                Field(id: "keywords", label: "Keywords", value: (iptc[kCGImagePropertyIPTCKeywords] as? [String])?.joined(separator: ", ") ?? ""),
                Field(id: "comment", label: "Comment", value: exif[kCGImagePropertyExifUserComment] as? String ?? ""),
            ]
        case .pdf:
            let a = PDFDocument(url: url)?.documentAttributes ?? [:]
            func v(_ k: PDFDocumentAttribute) -> String {
                if let s = a[k] as? String { return s }
                if let arr = a[k] as? [String] { return arr.joined(separator: ", ") }
                return ""
            }
            return [
                Field(id: "title", label: "Title", value: v(.titleAttribute)),
                Field(id: "author", label: "Author", value: v(.authorAttribute)),
                Field(id: "subject", label: "Subject", value: v(.subjectAttribute)),
                Field(id: "keywords", label: "Keywords", value: v(.keywordsAttribute)),
            ]
        case .audio, .video:
            var values: [String: String] = [:]
            if let asset = try? await VideoOps.readableAsset(url), let items = try? await asset.load(.commonMetadata) {
                for item in items {
                    guard let key = item.commonKey, let s = try? await item.load(.stringValue) else { continue }
                    values[key.rawValue] = s
                }
            }
            return [
                Field(id: "title", label: "Title", value: values["title"] ?? ""),
                Field(id: "artist", label: "Artist", value: values["artist"] ?? values["creator"] ?? ""),
                Field(id: "album", label: "Album", value: values["albumName"] ?? ""),
                Field(id: "date", label: "Year", value: values["creationDate"] ?? ""),
                Field(id: "comment", label: "Comment", value: values["description"] ?? ""),
            ]
        default:
            return []
        }
    }

    static func write(_ url: URL, kind: FileKind, changes: [String: String], removeLocation: Bool) async throws -> URL {
        switch kind {
        case .image: return try writeImage(url, changes: changes, removeLocation: removeLocation)
        case .pdf:
            let doc = try PDFOps.open(url)
            var attrs = doc.documentAttributes ?? [:]
            let map: [String: PDFDocumentAttribute] = ["title": .titleAttribute, "author": .authorAttribute,
                                                        "subject": .subjectAttribute, "keywords": .keywordsAttribute]
            for (k, v) in changes {
                guard let key = map[k] else { continue }
                attrs[key] = k == "keywords" ? v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } as Any : v
            }
            doc.documentAttributes = attrs
            return try PDFOps.save(doc, to: Output.url(for: url, suffix: "edited", ext: "pdf"))
        default: return try await writeAV(url, changes: changes)
        }
    }

    private static func writeImage(_ url: URL, changes: [String: String], removeLocation: Bool) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw AppError("Couldn’t read \(url.lastPathComponent)")
        }
        let out = Output.url(for: url, suffix: "edited", ext: url.pathExtension)
        guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw AppError("Can’t write this image type") }
        let meta = CGImageSourceCopyMetadataAtIndex(src, 0, nil).flatMap { CGImageMetadataCreateMutableCopy($0) } ?? CGImageMetadataCreateMutable()
        let map: [String: (CFString, CFString)] = [
            "title": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription),
            "author": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist),
            "copyright": (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright),
            "keywords": (kCGImagePropertyIPTCDictionary, kCGImagePropertyIPTCKeywords),
            "comment": (kCGImagePropertyExifDictionary, kCGImagePropertyExifUserComment),
        ]
        for (k, v) in changes {
            guard let (dict, prop) = map[k] else { continue }
            let value: CFTypeRef = k == "keywords"
                ? v.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) } as CFArray
                : v as CFString
            CGImageMetadataSetValueMatchingImageProperty(meta, dict, prop, value)
        }
        let opts: [CFString: Any] = [
            kCGImageDestinationMetadata: meta,
            kCGImageDestinationMergeMetadata: false,
            kCGImageMetadataShouldExcludeGPS: removeLocation,
        ]
        // Copies the image data losslessly where the format allows.
        var err: Unmanaged<CFError>?
        guard CGImageDestinationCopyImageSource(dest, src, opts as CFDictionary, &err) else {
            throw AppError("Couldn’t save metadata: \(err?.takeRetainedValue().localizedDescription ?? "unknown error")")
        }
        return out
    }

    private static func writeAV(_ url: URL, changes: [String: String]) async throws -> URL {
        let ext = url.pathExtension.lowercased()
        let out = Output.url(for: url, suffix: "edited", ext: ext)
        if ["mp4", "mov", "m4v", "m4a"].contains(ext) {
            let asset = AVURLAsset(url: url)
            let ids: [String: AVMetadataIdentifier] = [
                "title": .commonIdentifierTitle, "artist": .commonIdentifierArtist, "album": .commonIdentifierAlbumName,
                "date": .commonIdentifierCreationDate, "comment": .commonIdentifierDescription,
            ]
            var items = try await asset.load(.metadata).filter { item in
                !changes.keys.contains { ids[$0] == item.identifier }
            }
            for (k, v) in changes where !v.isEmpty {
                guard let id = ids[k] else { continue }
                let item = AVMutableMetadataItem()
                item.identifier = id
                item.value = v as NSString
                item.extendedLanguageTag = "und"
                items.append(item)
            }
            try await VideoOps.export(asset, preset: AVAssetExportPresetPassthrough, to: out, ext: ext, metadata: items)
            return out
        }
        // MP3, WAV, FLAC, OGG, MKV… — ffmpeg rewrites tags without re-encoding.
        let keys = ["title": "title", "artist": "artist", "album": "album", "date": "date", "comment": "comment"]
        var args = ["-i", url.path, "-map", "0", "-c", "copy"]
        for (k, v) in changes { if let key = keys[k] { args += ["-metadata", "\(key)=\(v)"] } }
        try FFmpeg.run(args + [out.path], for: "Editing tags in \(ext.uppercased()) files")
        return out
    }
}
