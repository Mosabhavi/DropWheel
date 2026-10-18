import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import UniformTypeIdentifiers
import Vision

enum ImageOps {
    /// Formats ImageIO can actually encode on this Mac, in wheel order.
    static let writableFormats: [String] = {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return ["JPG", "PNG", "HEIC", "WEBP", "TIFF", "BMP", "GIF", "AVIF"].filter {
            guard let t = UTType(filenameExtension: $0.lowercased()) else { return false }
            return ids.contains(t.identifier)
        }
    }()

    static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: Loading & writing

    /// Loads the image at full size with its EXIF orientation applied.
    static func load(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            var limit = maxPixel
            if limit == nil {
                let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
                let w = props?[kCGImagePropertyPixelWidth] as? Int ?? 8000
                let h = props?[kCGImagePropertyPixelHeight] as? Int ?? 8000
                limit = max(w, h)
            }
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: limit!,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        }
        // ImageIO can't read some formats (e.g. SVG); NSImage can.
        if let ns = NSImage(contentsOf: url) {
            var rect = NSRect(origin: .zero, size: ns.size)
            if let maxPixel {
                let s = CGFloat(maxPixel) / max(ns.size.width, ns.size.height)
                rect.size = NSSize(width: ns.size.width * s, height: ns.size.height * s)
            } else if ns.size.width < 1024 {
                rect.size = NSSize(width: ns.size.width * 2, height: ns.size.height * 2)
            }
            if let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) { return cg }
        }
        throw AppError("Couldn’t read \(url.lastPathComponent) as an image")
    }

    /// EXIF/GPS/IPTC dictionaries from the original, so conversions keep metadata.
    static func metadata(_ url: URL) -> [CFString: Any] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return [:] }
        var out: [CFString: Any] = [:]
        for key in [kCGImagePropertyExifDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            if let v = props[key] { out[key] = v }
        }
        return out
    }

    static func write(_ image: CGImage, to url: URL, ext: String, quality: Double = 0.92,
                      properties: [CFString: Any] = [:]) throws {
        guard let type = UTType(filenameExtension: ext),
              let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw AppError("Can’t write \(ext.uppercased()) files on this Mac")
        }
        var img = image
        if ["jpg", "jpeg", "bmp"].contains(ext), hasAlpha(image) { img = flatten(image) }
        var opts = properties
        opts[kCGImageDestinationLossyCompressionQuality] = quality
        CGImageDestinationAddImage(dest, img, opts as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw AppError("Couldn’t save \(url.lastPathComponent)") }
    }

    static func hasAlpha(_ img: CGImage) -> Bool {
        switch img.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    /// Composites onto white so transparent areas don't turn black in JPEG.
    static func flatten(_ img: CGImage) -> CGImage {
        guard let ctx = CGContext(data: nil, width: img.width, height: img.height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return img }
        let r = CGRect(x: 0, y: 0, width: img.width, height: img.height)
        ctx.setFillColor(.white)
        ctx.fill(r)
        ctx.draw(img, in: r)
        return ctx.makeImage() ?? img
    }

    static func outputExt(for url: URL) -> String {
        let e = Catalog.normalizedExt(url)
        return writableFormats.contains(e.uppercased()) ? e : "png"
    }

    // MARK: Convert

    static func convert(_ src: URL, to ext: String) throws -> URL {
        let out = Output.url(for: src, ext: ext)
        if ext == "svg" {
            try svg(try load(src), to: out)
            return out
        }
        if ext == "webp", !writableFormats.contains("WEBP") {
            try FFmpeg.webp(src, to: out)
            return out
        }
        // Keep animation / multiple pages when both sides support it.
        if ["gif", "tiff"].contains(ext),
           let source = CGImageSourceCreateWithURL(src as CFURL, nil),
           CGImageSourceGetCount(source) > 1,
           let dest = CGImageDestinationCreateWithURL(out as CFURL, UTType(filenameExtension: ext)!.identifier as CFString,
                                                      CGImageSourceGetCount(source), nil) {
            for i in 0..<CGImageSourceGetCount(source) { CGImageDestinationAddImageFromSource(dest, source, i, nil) }
            guard CGImageDestinationFinalize(dest) else { throw AppError("Couldn’t save \(out.lastPathComponent)") }
            return out
        }
        try write(try load(src), to: out, ext: ext, properties: metadata(src))
        return out
    }

    /// SVG with the picture embedded, so it scales in any vector app or browser.
    static func svg(_ img: CGImage, to out: URL) throws {
        let png = Output.temporary(ext: "png")
        defer { try? FileManager.default.removeItem(at: png) }
        try write(img, to: png, ext: "png")
        let b64 = try Data(contentsOf: png).base64EncodedString()
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" \
        width="\(img.width)" height="\(img.height)" viewBox="0 0 \(img.width) \(img.height)">
          <image width="\(img.width)" height="\(img.height)" xlink:href="data:image/png;base64,\(b64)"/>
        </svg>
        """
        try svg.write(to: out, atomically: true, encoding: .utf8)
    }

    /// Grid collage: images aspect-filled into equal cells with white gutters.
    static func collage(_ urls: [URL], width: Int = 3000, gap: Int = 24) throws -> URL {
        let images = try urls.map { try load($0, maxPixel: 2000) }
        let cols = Int(ceil(sqrt(Double(images.count))))
        let rows = Int(ceil(Double(images.count) / Double(cols)))
        let cell = (width - gap * (cols + 1)) / cols
        let height = rows * cell + gap * (rows + 1)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw AppError("Collage too large") }
        ctx.setFillColor(.white)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.interpolationQuality = .high
        for (i, img) in images.enumerated() {
            let col = i % cols, row = i / cols
            let rect = CGRect(x: gap + col * (cell + gap), y: height - (row + 1) * (cell + gap), width: cell, height: cell)
            let scale = max(rect.width / CGFloat(img.width), rect.height / CGFloat(img.height))
            let w = CGFloat(img.width) * scale, h = CGFloat(img.height) * scale
            ctx.saveGState()
            ctx.clip(to: rect)
            ctx.draw(img, in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
            ctx.restoreGState()
        }
        let out = Output.url(for: urls[0], suffix: "collage", ext: "jpg")
        try write(ctx.makeImage()!, to: out, ext: "jpg", quality: 0.9)
        return out
    }

    static func imagesToPDF(_ urls: [URL]) throws -> URL {
        let doc = PDFDocument()
        for u in urls {
            let cg = try load(u)
            let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
            guard let page = PDFPage(image: img) else { continue }
            doc.insert(page, at: doc.pageCount)
        }
        let out = urls.count == 1 ? Output.url(for: urls[0], ext: "pdf")
                                  : Output.url(for: urls[0], suffix: "and \(urls.count - 1) more", ext: "pdf")
        guard doc.pageCount > 0, doc.write(to: out) else { throw AppError("Couldn’t make PDF") }
        return out
    }

    static func recognizeText(_ src: URL) throws -> URL {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        try VNImageRequestHandler(cgImage: try load(src)).perform([request])
        let text = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.isEmpty else { throw AppError("No text found in the image") }
        let out = Output.url(for: src, ext: "txt")
        try text.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    // MARK: Tools

    static func compress(_ src: URL) throws -> URL {
        let cg = try load(src, maxPixel: 3000)
        let ext = hasAlpha(cg) && Catalog.normalizedExt(src) != "jpg" ? "heic" : "jpg"
        let out = Output.url(for: src, suffix: "compressed", ext: ext)
        try write(cg, to: out, ext: ext, quality: 0.6, properties: metadata(src))
        return out
    }

    static func resize(_ src: URL, factor: Double) throws -> URL {
        let full = try load(src)
        let target = Int(Double(max(full.width, full.height)) * factor)
        let cg = try load(src, maxPixel: target)
        let ext = outputExt(for: src)
        let out = Output.url(for: src, suffix: "\(cg.width)×\(cg.height)", ext: ext)
        try write(cg, to: out, ext: ext, properties: metadata(src))
        return out
    }

    static func rotate(_ src: URL) throws -> URL {
        let ci = CIImage(cgImage: try load(src)).oriented(.right)
        return try save(ci, from: src, suffix: "rotated")
    }

    static func grayscale(_ src: URL) throws -> URL {
        let f = CIFilter.photoEffectMono()
        f.inputImage = CIImage(cgImage: try load(src))
        return try save(f.outputImage!, from: src, suffix: "mono")
    }

    static func stripMetadata(_ src: URL) throws -> URL {
        let ext = outputExt(for: src)
        let out = Output.url(for: src, suffix: "no metadata", ext: ext)
        try write(try load(src), to: out, ext: ext, properties: [:])
        return out
    }

    static func removeBackground(_ src: URL) throws -> URL {
        let cg = try load(src)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])
        guard let result = request.results?.first else { throw AppError("No subject found") }
        let buffer = try result.generateMaskedImage(ofInstances: result.allInstances, from: handler,
                                                    croppedToInstancesExtent: false)
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let masked = ciContext.createCGImage(ci, from: ci.extent) else { throw AppError("Couldn’t cut out subject") }
        let out = Output.url(for: src, suffix: "no background", ext: "png")
        try write(masked, to: out, ext: "png")
        return out
    }

    static func save(_ ci: CIImage, from src: URL, suffix: String) throws -> URL {
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { throw AppError("Couldn’t render image") }
        let ext = outputExt(for: src)
        let out = Output.url(for: src, suffix: suffix, ext: ext)
        try write(cg, to: out, ext: ext, properties: metadata(src))
        return out
    }
}
