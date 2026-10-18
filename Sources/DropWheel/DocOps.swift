import AppKit
import PDFKit

enum PDFOps {
    static func open(_ url: URL) throws -> PDFDocument {
        guard let doc = PDFDocument(url: url) else { throw AppError("Couldn’t open \(url.lastPathComponent)") }
        if doc.isLocked { throw AppError("\(url.lastPathComponent) is password-protected") }
        return doc
    }

    static func save(_ doc: PDFDocument, to out: URL, options: [PDFDocumentWriteOption: Any] = [:]) throws -> URL {
        guard doc.write(to: out, withOptions: options) else { throw AppError("Couldn’t save \(out.lastPathComponent)") }
        return out
    }

    static func compress(_ src: URL) throws -> URL {
        let doc = try open(src)
        return try save(doc, to: Output.url(for: src, suffix: "compressed", ext: "pdf"),
                        options: [.saveImagesAsJPEGOption: true, .optimizeImagesForScreenOption: true])
    }

    static func merge(_ urls: [URL]) throws -> URL {
        let result = PDFDocument()
        for u in urls {
            let doc = try open(u)
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
            }
        }
        return try save(result, to: Output.url(for: urls[0], suffix: "merged", ext: "pdf"))
    }

    static func split(_ src: URL) throws -> URL {
        let doc = try open(src)
        let folder = Output.url(for: src, suffix: "pages", ext: "", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            let single = PDFDocument()
            if let page = doc.page(at: i)?.copy() as? PDFPage { single.insert(page, at: 0) }
            _ = try save(single, to: folder.appendingPathComponent("Page \(i + 1).pdf"))
        }
        return folder
    }

    static func rotate(_ src: URL) throws -> URL {
        let doc = try open(src)
        for i in 0..<doc.pageCount { doc.page(at: i)?.rotation += 90 }
        return try save(doc, to: Output.url(for: src, suffix: "rotated", ext: "pdf"))
    }

    static func reverse(_ src: URL) throws -> URL {
        let doc = try open(src)
        let result = PDFDocument()
        for i in stride(from: doc.pageCount - 1, through: 0, by: -1) {
            if let page = doc.page(at: i)?.copy() as? PDFPage { result.insert(page, at: result.pageCount) }
        }
        return try save(result, to: Output.url(for: src, suffix: "reversed", ext: "pdf"))
    }

    static func stripMetadata(_ src: URL) throws -> URL {
        let doc = try open(src)
        doc.documentAttributes = [:]
        return try save(doc, to: Output.url(for: src, suffix: "no metadata", ext: "pdf"))
    }

    /// One image for a single page, or a folder of "Page N" images.
    static func pagesToImages(_ src: URL, ext: String) throws -> URL {
        let doc = try open(src)
        func render(_ i: Int) throws -> CGImage {
            guard let page = doc.page(at: i) else { throw AppError("Missing page") }
            let box = page.bounds(for: .cropBox)
            let scale: CGFloat = 2
            let size = NSSize(width: box.width * scale, height: box.height * scale)
            let img = page.thumbnail(of: size, for: .cropBox)
            var rect = NSRect(origin: .zero, size: size)
            guard let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { throw AppError("Couldn’t render page") }
            return cg
        }
        if doc.pageCount == 1 {
            let out = Output.url(for: src, ext: ext)
            try ImageOps.write(try render(0), to: out, ext: ext)
            return out
        }
        let folder = Output.url(for: src, suffix: ext.uppercased(), ext: "", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for i in 0..<doc.pageCount {
            try ImageOps.write(try render(i), to: folder.appendingPathComponent("Page \(i + 1).\(ext)"), ext: ext)
        }
        return folder
    }
}

enum DocOps {
    static let types: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "odt": .openDocument, "rtf": .rtf, "html": .html, "txt": .plain, "doc": .docFormat,
    ]

    @MainActor static func read(_ url: URL) throws -> NSAttributedString {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown"].contains(ext) {
            let text = try String(contentsOf: url, encoding: .utf8)
            if let md = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
                return NSAttributedString(md)
            }
            return NSAttributedString(string: text)
        }
        if ["srt", "vtt", "txt", "text"].contains(ext) {
            return NSAttributedString(string: try String(contentsOf: url, encoding: .utf8),
                                      attributes: [.font: NSFont.systemFont(ofSize: 12)])
        }
        return try NSAttributedString(url: url, options: [:], documentAttributes: nil)
    }

    @MainActor static func write(_ s: NSAttributedString, to out: URL, ext: String) throws {
        if ext == "pdf" { return try writePDF(s, to: out) }
        guard let type = types[ext] else { throw AppError("Can’t write \(ext.uppercased())") }
        var attrs: [NSAttributedString.DocumentAttributeKey: Any] = [.documentType: type]
        if type == .plain { attrs[.characterEncoding] = String.Encoding.utf8.rawValue }
        let data = try s.data(from: NSRange(location: 0, length: s.length), documentAttributes: attrs)
        try data.write(to: out)
    }

    /// Lays the text out on US Letter pages via the print system.
    @MainActor static func writePDF(_ s: NSAttributedString, to out: URL) throws {
        let info = NSPrintInfo()
        info.paperSize = NSSize(width: 612, height: 792)
        for m in [\NSPrintInfo.topMargin, \.bottomMargin, \.leftMargin, \.rightMargin] { info[keyPath: m] = 54 }
        info.horizontalPagination = .fit
        info.verticalPagination = .automatic
        info.isVerticallyCentered = false
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = out

        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: 612 - 108, height: 792 - 108))
        view.isVerticallyResizable = true
        view.textContainer?.widthTracksTextView = true
        view.textStorage?.setAttributedString(s)
        view.sizeToFit()

        let op = NSPrintOperation(view: view, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else { throw AppError("Couldn’t create PDF") }
    }

    static func convert(_ src: URL, to ext: String) async throws -> URL {
        let out = Output.url(for: src, ext: ext)
        try await MainActor.run { try write(try read(src), to: out, ext: ext) }
        return out
    }

    static func pdfToText(_ src: URL) throws -> URL {
        let doc = try PDFOps.open(src)
        guard let text = doc.string, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AppError("This PDF has no selectable text")
        }
        let out = Output.url(for: src, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static func pdfToDocument(_ src: URL, ext: String) async throws -> URL {
        let doc = try PDFOps.open(src)
        let out = Output.url(for: src, ext: ext)
        try await MainActor.run {
            let all = NSMutableAttributedString()
            for i in 0..<doc.pageCount {
                if let page = doc.page(at: i)?.attributedString { all.append(page) }
                if i < doc.pageCount - 1 { all.append(NSAttributedString(string: "\n\u{0C}")) }
            }
            guard all.length > 0 else { throw AppError("This PDF has no selectable text") }
            try write(all, to: out, ext: ext)
        }
        return out
    }
}

enum ArchiveOps {
    static func run(_ tool: String, _ args: [String], in dir: URL? = nil) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.currentDirectoryURL = dir
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw AppError(msg.isEmpty ? "\(URL(fileURLWithPath: tool).lastPathComponent) failed" : msg)
        }
    }

    static func zip(_ urls: [URL]) throws -> URL {
        if urls.count == 1 {
            let out = Output.url(for: urls[0], ext: "zip")
            try run("/usr/bin/ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", urls[0].path, out.path])
            return out
        }
        let dir = urls[0].deletingLastPathComponent()
        let out = Output.url(for: dir.appendingPathComponent("Archive"), ext: "zip")
        try run("/usr/bin/zip", ["-r", "-q", "-y", out.path] + urls.map(\.lastPathComponent), in: dir)
        return out
    }

    static func tar(_ urls: [URL], gzip: Bool) throws -> URL {
        let dir = urls[0].deletingLastPathComponent()
        let ext = gzip ? "tar.gz" : "tar"
        let base = urls.count == 1 ? urls[0] : dir.appendingPathComponent("Archive")
        let out = Output.url(for: base, ext: ext)
        try run("/usr/bin/tar", [gzip ? "-czf" : "-cf", out.path] + urls.map(\.lastPathComponent), in: dir)
        return out
    }

    static func extract(_ src: URL) throws -> URL {
        var name = src
        while ["gz", "tar", "bz2", "xz", "tgz", "zip", "rar", "7z"].contains(name.pathExtension.lowercased()) {
            name = name.deletingPathExtension()
        }
        let folder = Output.url(for: name.appendingPathExtension("x"), ext: "", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if src.pathExtension.lowercased() == "zip" {
            try run("/usr/bin/ditto", ["-x", "-k", src.path, folder.path])
        } else {
            try run("/usr/bin/tar", ["-xf", src.path, "-C", folder.path])
        }
        return folder
    }
}
