import AppKit
import PDFKit
import Vision

enum SubtitleOps {
    struct Cue { var start: String; var end: String; var text: String }

    static func parse(_ text: String) -> [Cue] {
        let blocks = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n\n")
        var cues: [Cue] = []
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let i = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[i].components(separatedBy: "-->")
            let start = parts[0].trimmingCharacters(in: .whitespaces)
            let end = parts[1].trimmingCharacters(in: .whitespaces).components(separatedBy: " ")[0]
            cues.append(Cue(start: start, end: end, text: lines[(i + 1)...].joined(separator: "\n")))
        }
        return cues
    }

    /// Normalises "00:01.500" / "00:00:01,500" to the target style.
    static func stamp(_ t: String, srt: Bool) -> String {
        var t = t.replacingOccurrences(of: ",", with: ".")
        if t.split(separator: ":").count == 2 { t = "00:" + t }
        return srt ? t.replacingOccurrences(of: ".", with: ",") : t
    }

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let cues = parse(try String(contentsOf: src, encoding: .utf8))
        guard !cues.isEmpty else { throw AppError("No subtitles found in \(src.lastPathComponent)") }
        let out = Output.url(for: src, ext: ext)
        var result = ""
        switch ext {
        case "srt":
            for (i, c) in cues.enumerated() {
                result += "\(i + 1)\n\(stamp(c.start, srt: true)) --> \(stamp(c.end, srt: true))\n\(c.text)\n\n"
            }
        case "vtt":
            result = "WEBVTT\n\n"
            for c in cues { result += "\(stamp(c.start, srt: false)) --> \(stamp(c.end, srt: false))\n\(c.text)\n\n" }
        default:
            result = cues.map { $0.text.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
                .joined(separator: "\n")
        }
        try result.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}

extension ArchiveOps {
    static func gzip(_ src: URL) throws -> URL {
        let out = Output.url(for: src.appendingPathExtension("x"), ext: "gz")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/gzip")
        p.arguments = ["-c", "-9", src.path]
        FileManager.default.createFile(atPath: out.path, contents: nil)
        let handle = try FileHandle(forWritingTo: out)
        defer { try? handle.close() }
        p.standardOutput = handle
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: out)
            throw AppError("gzip failed")
        }
        return out
    }
}

extension PDFOps {
    /// Text from scanned pages, recognised with Vision.
    static func recognizeText(_ src: URL) throws -> URL {
        let doc = try open(src)
        var pages: [String] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let box = page.bounds(for: .cropBox)
            let img = page.thumbnail(of: NSSize(width: box.width * 2.5, height: box.height * 2.5), for: .cropBox)
            var rect = NSRect(origin: .zero, size: img.size)
            guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            try VNImageRequestHandler(cgImage: cg).perform([request])
            pages.append((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n"))
        }
        let text = pages.joined(separator: "\n\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AppError("No text found") }
        let out = Output.url(for: src, suffix: "OCR", ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }
}
