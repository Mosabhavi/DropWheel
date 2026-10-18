import AppKit
import UniformTypeIdentifiers

struct WheelAction {
    let title: String
    var symbol: String? = nil
    /// Actions that open a window instead of producing files right away.
    var opensPanel = false
    let run: ([URL]) async throws -> [URL]
}

enum FileKind {
    case image, video, audio, pdf, document, subtitle, archive, other

    static let documentExts: Set<String> = ["txt", "text", "md", "markdown", "rtf", "rtfd", "doc", "docx",
                                             "odt", "html", "htm", "webarchive"]
    static let subtitleExts: Set<String> = ["srt", "vtt"]
    static let archiveExts: Set<String> = ["zip", "tar", "gz", "tgz", "bz2", "xz", "rar", "7z"]
    // Containers macOS doesn't register types for; ffmpeg handles them.
    static let extraVideoExts: Set<String> = ["mkv", "webm", "avi", "wmv", "flv", "mpg", "mpeg", "ts", "m2ts", "ogv", "3gp"]
    static let extraAudioExts: Set<String> = ["ogg", "oga", "opus", "wma", "ape", "mka"]

    static func of(_ url: URL) -> FileKind {
        if url.hasDirectoryPath { return .other }
        let ext = url.pathExtension.lowercased()
        if archiveExts.contains(ext) { return .archive }
        if subtitleExts.contains(ext) { return .subtitle }
        if documentExts.contains(ext) { return .document }
        if extraVideoExts.contains(ext) { return .video }
        if extraAudioExts.contains(ext) { return .audio }
        guard let t = UTType(filenameExtension: ext) else { return .other }
        if t.conforms(to: .pdf) { return .pdf }
        if t.conforms(to: .image) { return .image }
        if t.conforms(to: .movie) || t.conforms(to: .video) { return .video }
        if t.conforms(to: .audio) { return .audio }
        if t.conforms(to: .text) { return .document }
        return .other
    }

    static func of(_ urls: [URL]) -> FileKind {
        let kinds = Set(urls.map { of($0) })
        return kinds.count == 1 ? kinds.first! : .other
    }
}

enum Catalog {
    static func actions(for urls: [URL], mode: Mode) -> [WheelAction] {
        let kind = FileKind.of(urls)
        let ext = urls.first.map { normalizedExt($0) } ?? ""
        switch mode {
        case .convert: return convert(kind, ext: ext, urls: urls)
        case .tools: return tools(kind, many: urls.count > 1)
        }
    }

    static func normalizedExt(_ url: URL) -> String {
        let e = url.pathExtension.lowercased()
        switch e {
        case "jpeg": return "jpg"
        case "tif": return "tiff"
        case "aif": return "aiff"
        case "htm": return "html"
        default: return e
        }
    }

    static func each(_ title: String, _ symbol: String? = nil, _ f: @escaping (URL) async throws -> URL) -> WheelAction {
        WheelAction(title: title, symbol: symbol) { urls in
            var outs: [URL] = []
            for u in urls { outs.append(try await f(u)) }
            return outs
        }
    }

    static func panel(_ title: String, _ symbol: String, _ f: @escaping @MainActor ([URL]) -> Void) -> WheelAction {
        WheelAction(title: title, symbol: symbol, opensPanel: true) { urls in
            await MainActor.run { f(urls) }
            return []
        }
    }

    static func all(_ title: String, _ symbol: String? = nil, _ f: @escaping ([URL]) async throws -> URL) -> WheelAction {
        WheelAction(title: title, symbol: symbol) { [try await f($0)] }
    }

    // MARK: Convert

    private static func convert(_ kind: FileKind, ext: String, urls: [URL]) -> [WheelAction] {
        switch kind {
        case .image:
            let formats = ["JPG", "PNG", "HEIC", "WEBP", "TIFF", "AVIF", "BMP", "GIF", "SVG"]
            return formats.filter { $0.lowercased() != ext }.map { fmt in
                each(fmt) { try ImageOps.convert($0, to: fmt.lowercased()) }
            } + [
                all("PDF") { try ImageOps.imagesToPDF($0) },
                each("Text") { try ImageOps.recognizeText($0) },
            ]

        case .video:
            let video = ["MP4", "MOV", "MKV", "WEBM", "AVI", "WMV"].filter { $0.lowercased() != ext }
            return video.map { fmt in each(fmt) { try await VideoOps.convert($0, to: fmt.lowercased()) } } + [
                each("GIF") { try await VideoOps.gif($0) },
                each("MP3") { try await VideoOps.extractAudio($0, ext: "mp3") },
                each("M4A") { try await VideoOps.extractAudio($0, ext: "m4a") },
                each("WAV") { try await VideoOps.extractAudio($0, ext: "wav") },
            ]

        case .audio:
            return ["MP3", "M4A", "WAV", "FLAC", "OGG", "OPUS", "AIFF"].filter { $0.lowercased() != ext }.map { fmt in
                each(fmt == "OPUS" ? "Opus" : fmt) { try await AudioOps.convert($0, to: fmt.lowercased()) }
            }

        case .pdf:
            return [
                each("TXT") { try DocOps.pdfToText($0) },
                each("DOCX") { try await DocOps.pdfToDocument($0, ext: "docx") },
                each("PNG") { try PDFOps.pagesToImages($0, ext: "png") },
                each("JPG") { try PDFOps.pagesToImages($0, ext: "jpg") },
                each("HEIC") { try PDFOps.pagesToImages($0, ext: "heic") },
                each("TIFF") { try PDFOps.pagesToImages($0, ext: "tiff") },
                each("RTF") { try await DocOps.pdfToDocument($0, ext: "rtf") },
                each("HTML") { try await DocOps.pdfToDocument($0, ext: "html") },
            ]

        case .document:
            return ["PDF", "DOCX", "TXT", "RTF", "HTML", "ODT", "DOC"].filter { $0.lowercased() != ext }.map { fmt in
                each(fmt) { try await DocOps.convert($0, to: fmt.lowercased()) }
            }

        case .subtitle:
            return ["SRT", "VTT"].filter { $0.lowercased() != ext }.map { fmt in
                each(fmt) { try SubtitleOps.convert($0, to: fmt.lowercased()) }
            } + [each("TXT") { try SubtitleOps.convert($0, to: "txt") }]

        case .archive:
            return [
                each("Extract") { try ArchiveOps.extract($0) },
                all("ZIP") { try ArchiveOps.zip($0) },
                all("TAR") { try ArchiveOps.tar($0, gzip: false) },
                all("TGZ") { try ArchiveOps.tar($0, gzip: true) },
            ]

        case .other:
            var list = [
                all("ZIP") { try ArchiveOps.zip($0) },
                all("TAR") { try ArchiveOps.tar($0, gzip: false) },
                all("TGZ") { try ArchiveOps.tar($0, gzip: true) },
            ]
            if urls.allSatisfy({ !$0.hasDirectoryPath }) {
                list.append(each("GZIP") { try ArchiveOps.gzip($0) })
            }
            return list
        }
    }

    // MARK: Tools

    private static func tools(_ kind: FileKind, many: Bool) -> [WheelAction] {
        let metadata = panel("Metadata", "tag") { MetadataPanel.open($0[0]) }
        let compress = panel("Compress", "arrow.down.right.and.arrow.up.left") { CompressPanel.open($0) }

        switch kind {
        case .image:
            var list = [
                compress,
                metadata,
                panel("Edit", "slider.horizontal.3") { EditPhotoPanel.open($0[0]) },
                panel("Annotate", "pencil.tip.crop.circle") { ImageEditorPanel.open($0[0], mode: .annotate) },
                panel("Add BG", "photo.fill") { AddBackgroundPanel.open($0[0]) },
                each("Remove BG", "person.crop.rectangle") { try ImageOps.removeBackground($0) },
                panel("Crop", "crop") { ImageEditorPanel.open($0[0], mode: .crop) },
                panel("Redact", "eye.slash") { ImageEditorPanel.open($0[0], mode: .redact) },
            ]
            if many {
                list.append(all("Make PDF", "doc.richtext") { try ImageOps.imagesToPDF($0) })
                list.append(all("Collage", "square.grid.2x2") { try ImageOps.collage($0) })
            }
            return list

        case .video:
            return [
                compress,
                metadata,
                panel("Trim", "timeline.selection") { VideoTrimPanel.open($0[0]) },
                panel("Crop", "crop") { VideoCropPanel.open($0[0]) },
                panel("Speed", "hare") { SpeedPanel.open($0[0]) },
                panel("Split", "scissors") { VideoPlayerPanel.open($0[0], mode: .split) },
                panel("Snapshot", "camera") { VideoPlayerPanel.open($0[0], mode: .snapshot) },
                each("Mute", "speaker.slash") { try await VideoOps.mute($0) },
            ] + (many ? [all("Join", "film.stack") { try await VideoOps.join($0) }] : [])

        case .audio:
            return [
                compress,
                metadata,
                panel("Trim", "waveform") { AudioTrimPanel.open($0[0]) },
                panel("Bleep", "speaker.badge.exclamationmark") { BleepPanel.open($0[0]) },
                each("Normalize", "chart.bar") { try await AudioOps.process($0, suffix: "normalized") { AudioOps.normalize($0) } },
                panel("Channels", "speaker.wave.2") { ChannelsPanel.open($0[0]) },
                each("Fade", "waveform.path.ecg") { try await AudioOps.process($0, suffix: "faded") { AudioOps.fade($0) } },
                each("Reverse", "backward") { try await AudioOps.process($0, suffix: "reversed") { AudioOps.reverse($0) } },
            ] + (many ? [all("Join", "rectangle.stack") { try await AudioOps.join($0) }] : [])

        case .pdf:
            return [
                compress,
                metadata,
                panel("Organize", "square.grid.3x3") { PDFOrganizePanel.open($0[0]) },
                each("Split", "scissors") { try PDFOps.split($0) },
                each("Rotate", "rotate.right") { try PDFOps.rotate($0) },
                each("Images", "photo.on.rectangle") { try PDFOps.pagesToImages($0, ext: "png") },
                each("OCR Text", "text.viewfinder") { try PDFOps.recognizeText($0) },
                each("Strip Info", "eye.slash") { try PDFOps.stripMetadata($0) },
            ] + (many ? [all("Merge", "doc.on.doc") { try PDFOps.merge($0) }] : [])

        case .document, .subtitle, .archive, .other:
            return [
                metadata,
                all("ZIP", "doc.zipper") { try ArchiveOps.zip($0) },
                all("TGZ", "archivebox") { try ArchiveOps.tar($0, gzip: true) },
                WheelAction(title: "Duplicate", symbol: "plus.square.on.square") { urls in
                    try urls.map { u in
                        let out = Output.url(for: u, suffix: "copy", ext: u.pathExtension)
                        try FileManager.default.copyItem(at: u, to: out)
                        return out
                    }
                },
            ]
        }
    }
}

// MARK: - Running actions

enum Runner {
    @MainActor static func run(_ action: WheelAction, _ urls: [URL]) {
        if action.opensPanel {
            Task { @MainActor in _ = try? await action.run(urls) }
            return
        }
        Toast.shared.show("\(action.title)…", style: .progress)
        Task.detached(priority: .userInitiated) {
            do {
                let outs = try await action.run(urls)
                await MainActor.run { Runner.finished(outs) }
            } catch {
                await MainActor.run { Toast.shared.show(error.localizedDescription, style: .error) }
            }
        }
    }

    @MainActor static func finished(_ outs: [URL]) {
        guard let first = outs.first else { Toast.shared.hide(); return }
        var msg = outs.count == 1 ? "Saved \(first.lastPathComponent)" : "Saved \(outs.count) files"
        if outs.count == 1, let size = try? first.resourceValues(forKeys: [.fileSizeKey]).fileSize {
            msg += " · " + ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
        Toast.shared.show(msg, style: .success)
        NSSound(named: "Glass")?.play()
    }
}

struct AppError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Output {
    /// "<dir>/<base>[ suffix].<ext>", made unique with " 2", " 3"… so nothing is overwritten.
    static func url(for src: URL, suffix: String? = nil, ext: String, isDirectory: Bool = false) -> URL {
        let dir = src.deletingLastPathComponent()
        var base = src.deletingPathExtension().lastPathComponent
        if let suffix { base += " \(suffix)" }
        func make(_ name: String) -> URL {
            ext.isEmpty ? dir.appendingPathComponent(name, isDirectory: isDirectory)
                        : dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        var candidate = make(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = make("\(base) \(n)")
            n += 1
        }
        return candidate
    }

    static func temporary(ext: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
    }
}
