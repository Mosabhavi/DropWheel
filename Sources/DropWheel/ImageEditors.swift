import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI
import Vision

// Crop, Redact and Annotate share one editor: the picture fitted into the window, with
// geometry kept in normalised image coordinates (0…1, origin top-left).

enum EditorMode { case crop, redact, annotate }
enum RedactStyle: String, CaseIterable { case black = "Black Box", pixelate = "Pixelate", blur = "Blur" }
enum AnnotateTool: String, CaseIterable {
    case arrow, rectangle, ellipse, pen, highlight, text
    var symbol: String {
        switch self {
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .pen: return "scribble"
        case .highlight: return "highlighter"
        case .text: return "textformat"
        }
    }
}

struct Mark {
    var tool: AnnotateTool
    var points: [CGPoint]
    var color: NSColor
    var width: CGFloat      // per-mille of the image's long side
    var text = ""
}

final class EditorModel: ObservableObject {
    let url: URL
    let mode: EditorMode
    @Published var base: CGImage
    @Published var display: NSImage
    private var previewBase: CGImage

    // Crop
    @Published var crop = CGRect(x: 0, y: 0, width: 1, height: 1)
    @Published var aspect: CGFloat? = nil

    // Redact
    @Published var boxes: [CGRect] = [] { didSet { refresh() } }
    @Published var style: RedactStyle = .pixelate { didSet { refresh() } }
    @Published var busy = false

    // Annotate
    @Published var marks: [Mark] = [] { didSet { refresh() } }
    @Published var draft: Mark? { didSet { refresh() } }
    @Published var draftBox: CGRect? { didSet { refresh() } }
    @Published var tool: AnnotateTool = .arrow
    @Published var color = Color.red
    @Published var lineWidth: CGFloat = 5
    @Published var text = "Text"

    /// Set for video crop: receives the normalised crop rect instead of saving a picture.
    var customApply: ((CGRect) async throws -> URL)?

    init(url: URL, mode: EditorMode) throws {
        self.url = url
        self.mode = mode
        base = try ImageOps.load(url)
        previewBase = try ImageOps.load(url, maxPixel: 1600)
        display = NSImage(cgImage: previewBase, size: NSSize(width: previewBase.width, height: previewBase.height))
    }

    init(frame: CGImage, url: URL, apply: @escaping (CGRect) async throws -> URL) {
        self.url = url
        mode = .crop
        base = frame
        previewBase = frame
        customApply = apply
        display = NSImage(cgImage: frame, size: NSSize(width: frame.width, height: frame.height))
    }

    func finish() async throws -> URL {
        if let customApply { return try await customApply(crop) }
        return try save()
    }

    var pixelSize: CGSize { CGSize(width: base.width, height: base.height) }

    func refresh() {
        let img = mode == .crop ? previewBase : render(previewBase, includeDraft: true)
        display = NSImage(cgImage: img, size: NSSize(width: img.width, height: img.height))
    }

    // MARK: Crop

    func rotate(clockwise: Bool) {
        transform { $0.oriented(clockwise ? .right : .left) }
    }

    func flip() {
        transform { $0.oriented(.upMirrored) }
    }

    private func transform(_ f: (CIImage) -> CIImage) {
        func apply(_ cg: CGImage) -> CGImage {
            let ci = f(CIImage(cgImage: cg))
            return ImageOps.ciContext.createCGImage(ci, from: ci.extent) ?? cg
        }
        base = apply(base)
        previewBase = apply(previewBase)
        crop = CGRect(x: 0, y: 0, width: 1, height: 1)
        if let a = aspect { setAspect(a) }
        refresh()
    }

    func setAspect(_ a: CGFloat?) {
        aspect = a
        guard let a else { return }
        // Largest centred rect with that pixel aspect.
        let imgAspect = pixelSize.width / pixelSize.height
        var w: CGFloat = 1, h: CGFloat = 1
        if a > imgAspect { h = imgAspect / a } else { w = a / imgAspect }
        crop = CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }

    // MARK: Redact helpers

    func detect(faces: Bool) {
        busy = true
        let cg = previewBase
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [CGRect] = []
            let handler = VNImageRequestHandler(cgImage: cg)
            if faces {
                let r = VNDetectFaceRectanglesRequest()
                try? handler.perform([r])
                found = (r.results ?? []).map { $0.boundingBox.insetBy(dx: -$0.boundingBox.width * 0.15, dy: -$0.boundingBox.height * 0.2) }
            } else {
                let r = VNRecognizeTextRequest()
                r.recognitionLevel = .accurate
                try? handler.perform([r])
                found = (r.results ?? []).map { $0.boundingBox.insetBy(dx: -0.004, dy: -0.006) }
            }
            // Vision uses a bottom-left origin.
            let boxes = found.map { CGRect(x: $0.minX, y: 1 - $0.maxY, width: $0.width, height: $0.height) }
            DispatchQueue.main.async {
                self.busy = false
                if boxes.isEmpty {
                    Toast.shared.show(faces ? "No faces found" : "No text found", style: .error)
                } else {
                    self.boxes += boxes
                }
            }
        }
    }

    // MARK: Rendering (shared by preview and final output)

    func render(_ image: CGImage, includeDraft: Bool) -> CGImage {
        switch mode {
        case .crop:
            let W = CGFloat(image.width), H = CGFloat(image.height)
            let r = CGRect(x: crop.minX * W, y: crop.minY * H, width: crop.width * W, height: crop.height * H).integral
            return image.cropping(to: r) ?? image
        case .redact:
            var all = boxes
            if includeDraft, let d = draftBox { all.append(d) }
            return redact(image, boxes: all)
        case .annotate:
            var all = marks
            if includeDraft, let d = draft { all.append(d) }
            return annotate(image, marks: all)
        }
    }

    private func pixelRect(_ r: CGRect, _ W: CGFloat, _ H: CGFloat, flipY: Bool) -> CGRect {
        CGRect(x: r.minX * W, y: (flipY ? 1 - r.maxY : r.minY) * H, width: r.width * W, height: r.height * H)
    }

    private func redact(_ image: CGImage, boxes: [CGRect]) -> CGImage {
        guard !boxes.isEmpty else { return image }
        let W = CGFloat(image.width), H = CGFloat(image.height)
        if style == .black {
            guard let ctx = Self.context(image) else { return image }
            ctx.setFillColor(.black)
            for b in boxes { ctx.fill(pixelRect(b, W, H, flipY: true)) }
            return ctx.makeImage() ?? image
        }
        let src = CIImage(cgImage: image)
        let effect: CIImage
        if style == .pixelate {
            let f = CIFilter.pixellate()
            f.inputImage = src.clampedToExtent()
            f.scale = Float(max(W, H) / 45)
            f.center = .zero
            effect = f.outputImage!
        } else {
            let f = CIFilter.gaussianBlur()
            f.inputImage = src.clampedToExtent()
            f.radius = Float(max(W, H) / 40)
            effect = f.outputImage!
        }
        var out = src
        for b in boxes { out = effect.cropped(to: pixelRect(b, W, H, flipY: true)).composited(over: out) }
        return ImageOps.ciContext.createCGImage(out, from: src.extent) ?? image
    }

    private func annotate(_ image: CGImage, marks: [Mark]) -> CGImage {
        guard !marks.isEmpty, let ctx = Self.context(image) else { return image }
        let W = CGFloat(image.width), H = CGFloat(image.height), long = max(W, H)
        // Work top-left like the editor.
        ctx.translateBy(x: 0, y: H)
        ctx.scaleBy(x: 1, y: -1)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        func p(_ n: CGPoint) -> CGPoint { CGPoint(x: n.x * W, y: n.y * H) }

        for m in marks {
            let lw = m.width * long / 1000
            ctx.setStrokeColor(m.color.cgColor)
            ctx.setFillColor(m.color.cgColor)
            ctx.setLineWidth(lw)
            guard let first = m.points.first else { continue }
            let last = m.points.last!
            let rect = CGRect(x: min(p(first).x, p(last).x), y: min(p(first).y, p(last).y),
                              width: abs(p(last).x - p(first).x), height: abs(p(last).y - p(first).y))
            switch m.tool {
            case .rectangle:
                ctx.stroke(rect)
            case .ellipse:
                ctx.strokeEllipse(in: rect)
            case .highlight:
                ctx.setFillColor(m.color.withAlphaComponent(0.35).cgColor)
                ctx.fill(rect)
            case .pen:
                ctx.beginPath()
                ctx.move(to: p(first))
                for pt in m.points.dropFirst() { ctx.addLine(to: p(pt)) }
                ctx.strokePath()
            case .arrow:
                let a = p(first), b = p(last)
                let angle = atan2(b.y - a.y, b.x - a.x)
                let head = max(lw * 4, 14)
                let base = CGPoint(x: b.x - cos(angle) * head * 0.8, y: b.y - sin(angle) * head * 0.8)
                ctx.beginPath(); ctx.move(to: a); ctx.addLine(to: base); ctx.strokePath()
                ctx.beginPath()
                ctx.move(to: b)
                ctx.addLine(to: CGPoint(x: b.x - cos(angle - 0.45) * head, y: b.y - sin(angle - 0.45) * head))
                ctx.addLine(to: CGPoint(x: b.x - cos(angle + 0.45) * head, y: b.y - sin(angle + 0.45) * head))
                ctx.closePath()
                ctx.fillPath()
            case .text:
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
                let font = NSFont.systemFont(ofSize: max(12, m.width * 6 * long / 1000), weight: .bold)
                let shadow = NSShadow()
                shadow.shadowColor = NSColor.black.withAlphaComponent(0.4)
                shadow.shadowBlurRadius = font.pointSize / 10
                NSAttributedString(string: m.text, attributes: [.font: font, .foregroundColor: m.color, .shadow: shadow])
                    .draw(at: p(first))
                NSGraphicsContext.restoreGraphicsState()
            }
        }
        return ctx.makeImage() ?? image
    }

    static func context(_ image: CGImage) -> CGContext? {
        let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        ctx?.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx
    }

    func save() throws -> URL {
        let result = render(base, includeDraft: false)
        let ext = ImageOps.outputExt(for: url)
        let suffix = mode == .crop ? "cropped" : mode == .redact ? "redacted" : "annotated"
        let out = Output.url(for: url, suffix: suffix, ext: ext)
        // Redacted copies drop metadata too, so location/camera info doesn't leak.
        try ImageOps.write(result, to: out, ext: ext, properties: mode == .redact ? [:] : ImageOps.metadata(url))
        return out
    }
}

@MainActor enum ImageEditorPanel {
    static func open(_ url: URL, mode: EditorMode) {
        do {
            let model = try EditorModel(url: url, mode: mode)
            let title = mode == .crop ? "Crop Photo" : mode == .redact ? "Redact Photo" : "Annotate Photo"
            _ = Windows.show(title, size: NSSize(width: 760, height: 680)) { close in
                ImageEditorView(m: model, close: close)
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
    }
}

struct ImageEditorView: View {
    @ObservedObject var m: EditorModel
    let close: () -> Void
    @StateObject private var drag = DragState()

    final class DragState: ObservableObject {
        var startCrop = CGRect.zero
        var handle: Int? = nil   // 0…3 corners, 4 = move, nil = new
        var active = false
    }

    var body: some View {
        VStack(spacing: 12) {
            toolbar
            GeometryReader { geo in
                let fit = fitRect(in: geo.size)
                ZStack(alignment: .topLeading) {
                    Color.black.opacity(0.85)
                    Image(nsImage: m.display).resizable().interpolation(.high)
                        .frame(width: fit.width, height: fit.height)
                        .offset(x: fit.minX, y: fit.minY)
                    if m.mode == .crop {
                        Canvas { ctx, size in drawCrop(ctx, fit: fit, size: size) }.allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0)
                    .onChanged { changed($0, fit: fit) }
                    .onEnded { ended($0, fit: fit) })
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))

            HStack {
                Text(hint).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 16, bottom: 16, trailing: 16))
    }

    private var hint: String {
        switch m.mode {
        case .crop: return "Drag the corners or the frame. Drag outside to draw a new crop."
        case .redact: return m.boxes.isEmpty ? "Drag over anything you want to hide." : "\(m.boxes.count) area\(m.boxes.count == 1 ? "" : "s") hidden"
        case .annotate: return m.tool == .text ? "Click where the text should go." : "Drag on the photo to draw."
        }
    }

    @ViewBuilder private var toolbar: some View {
        switch m.mode {
        case .crop:
            HStack(spacing: 8) {
                ForEach(aspects, id: \.0) { name, value in
                    Button(name) { m.setAspect(value == -1 ? m.pixelSize.width / m.pixelSize.height : value) }
                        .buttonStyle(.bordered)
                        .tint(isAspect(value) ? .red : nil)
                }
                Spacer()
                if m.customApply == nil {
                    Button { m.rotate(clockwise: false) } label: { Image(systemName: "rotate.left") }.help("Rotate Left")
                    Button { m.rotate(clockwise: true) } label: { Image(systemName: "rotate.right") }.help("Rotate Right")
                    Button { m.flip() } label: { Image(systemName: "arrow.left.and.right.righttriangle.left.righttriangle.right") }.help("Flip")
                }
            }
        case .redact:
            HStack(spacing: 8) {
                ForEach(RedactStyle.allCases, id: \.self) { st in
                    Button(st.rawValue) { m.style = st }.buttonStyle(.bordered).tint(m.style == st ? .red : nil)
                }
                Spacer()
                if m.busy { ProgressView().controlSize(.small) }
                Button { m.detect(faces: true) } label: { Label("Find Faces", systemImage: "face.smiling") }
                Button { m.detect(faces: false) } label: { Label("Find Text", systemImage: "text.viewfinder") }
                Button { _ = m.boxes.popLast() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(m.boxes.isEmpty)
                Button("Clear") { m.boxes = [] }.disabled(m.boxes.isEmpty)
            }
        case .annotate:
            HStack(spacing: 8) {
                ForEach(AnnotateTool.allCases, id: \.self) { t in
                    Button { m.tool = t } label: { Image(systemName: t.symbol).frame(width: 18) }
                        .buttonStyle(.bordered).tint(m.tool == t ? .red : nil)
                        .help(t.rawValue.capitalized)
                }
                ColorPicker("", selection: $m.color).labelsHidden()
                Slider(value: $m.lineWidth, in: 1...20).frame(width: 90)
                if m.tool == .text { TextField("Text", text: $m.text).frame(width: 110) }
                Spacer()
                Button { _ = m.marks.popLast() } label: { Image(systemName: "arrow.uturn.backward") }.disabled(m.marks.isEmpty)
            }
        }
    }

    private let aspects: [(String, CGFloat?)] = [("Free", nil), ("Original", -1), ("1:1", 1), ("4:3", 4.0 / 3), ("3:2", 1.5), ("16:9", 16.0 / 9), ("9:16", 9.0 / 16), ("4:5", 0.8)]

    private func isAspect(_ v: CGFloat?) -> Bool {
        guard let a = m.aspect else { return v == nil }
        guard let v else { return false }
        let target = v == -1 ? m.pixelSize.width / m.pixelSize.height : v
        return abs(a - target) < 0.001
    }

    private func fitRect(in size: CGSize) -> CGRect {
        let s = m.display.size
        let scale = min(size.width / s.width, size.height / s.height)
        let w = s.width * scale, h = s.height * scale
        return CGRect(x: (size.width - w) / 2, y: (size.height - h) / 2, width: w, height: h)
    }

    private func norm(_ p: CGPoint, _ fit: CGRect) -> CGPoint {
        CGPoint(x: min(max((p.x - fit.minX) / fit.width, 0), 1), y: min(max((p.y - fit.minY) / fit.height, 0), 1))
    }

    private func rect(_ a: CGPoint, _ b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    // MARK: Gestures

    private func changed(_ v: DragGesture.Value, fit: CGRect) {
        let start = norm(v.startLocation, fit), now = norm(v.location, fit)
        switch m.mode {
        case .crop: cropDrag(start: start, now: now, startView: v.startLocation, fit: fit)
        case .redact: m.draftBox = rect(start, now)
        case .annotate:
            let ns = NSColor(m.color)
            switch m.tool {
            case .pen:
                if m.draft == nil { m.draft = Mark(tool: .pen, points: [start], color: ns, width: m.lineWidth) }
                m.draft?.points.append(now)
            case .text: break
            default:
                m.draft = Mark(tool: m.tool, points: [start, now], color: ns, width: m.lineWidth)
            }
        }
    }

    private func ended(_ v: DragGesture.Value, fit: CGRect) {
        drag.active = false
        switch m.mode {
        case .crop: break
        case .redact:
            if let d = m.draftBox, d.width > 0.005, d.height > 0.005 { m.boxes.append(d) }
            m.draftBox = nil
        case .annotate:
            if m.tool == .text {
                guard !m.text.isEmpty else { return }
                m.marks.append(Mark(tool: .text, points: [norm(v.location, fit)], color: NSColor(m.color),
                                    width: m.lineWidth, text: m.text))
            } else if let d = m.draft {
                m.draft = nil
                m.marks.append(d)
            }
        }
    }

    private func cropDrag(start: CGPoint, now: CGPoint, startView: CGPoint, fit: CGRect) {
        if !drag.active {
            drag.active = true
            drag.startCrop = m.crop
            let c = m.crop
            let corners = [CGPoint(x: c.minX, y: c.minY), CGPoint(x: c.maxX, y: c.minY),
                           CGPoint(x: c.minX, y: c.maxY), CGPoint(x: c.maxX, y: c.maxY)]
            drag.handle = corners.firstIndex { pt in
                hypot(fit.minX + pt.x * fit.width - startView.x, fit.minY + pt.y * fit.height - startView.y) < 18
            } ?? (c.contains(start) ? 4 : nil)
        }
        let s = drag.startCrop
        // Normalised height per normalised width for the locked aspect.
        let ratio: CGFloat? = m.aspect.map { m.pixelSize.width / ($0 * m.pixelSize.height) }
        switch drag.handle {
        case 4:
            let dx = now.x - start.x, dy = now.y - start.y
            m.crop.origin = CGPoint(x: min(max(s.minX + dx, 0), 1 - s.width), y: min(max(s.minY + dy, 0), 1 - s.height))
        case let corner?:
            // The opposite corner stays put.
            let anchor = CGPoint(x: corner % 2 == 0 ? s.maxX : s.minX, y: corner < 2 ? s.maxY : s.minY)
            var r = rect(anchor, now)
            if let ratio {
                r.size.height = min(r.width * ratio, corner < 2 ? anchor.y : 1 - anchor.y)
                r.size.width = r.height / ratio
                r.origin.x = corner % 2 == 0 ? anchor.x - r.width : anchor.x
                r.origin.y = corner < 2 ? anchor.y - r.height : anchor.y
            }
            if r.width > 0.02, r.height > 0.02 { m.crop = r }
        case nil:
            var r = rect(start, now)
            if let ratio {
                r.size.height = r.width * ratio
                if r.maxY > 1 { r.size.height = 1 - r.minY; r.size.width = r.height / ratio }
                if now.y < start.y { r.origin.y = start.y - r.height }
            }
            if r.width > 0.02, r.height > 0.02 { m.crop = r }
        }
    }

    private func drawCrop(_ ctx: GraphicsContext, fit: CGRect, size: CGSize) {
        let c = m.crop
        let r = CGRect(x: fit.minX + c.minX * fit.width, y: fit.minY + c.minY * fit.height,
                       width: c.width * fit.width, height: c.height * fit.height)
        var dim = Path(CGRect(origin: .zero, size: size))
        dim.addRect(r)
        ctx.fill(dim, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))
        ctx.stroke(Path(r), with: .color(.white), lineWidth: 1.5)
        for i in 1...2 {
            let x = r.minX + r.width * CGFloat(i) / 3, y = r.minY + r.height * CGFloat(i) / 3
            var grid = Path()
            grid.move(to: CGPoint(x: x, y: r.minY)); grid.addLine(to: CGPoint(x: x, y: r.maxY))
            grid.move(to: CGPoint(x: r.minX, y: y)); grid.addLine(to: CGPoint(x: r.maxX, y: y))
            ctx.stroke(grid, with: .color(.white.opacity(0.35)), lineWidth: 0.75)
        }
        for pt in [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)] {
            ctx.fill(Path(ellipseIn: CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)), with: .color(.white))
            ctx.stroke(Path(ellipseIn: CGRect(x: pt.x - 7, y: pt.y - 7, width: 14, height: 14)), with: .color(.red), lineWidth: 2)
        }
        let px = "\(Int(c.width * m.pixelSize.width)) × \(Int(c.height * m.pixelSize.height))"
        ctx.draw(Text(px).font(.caption.bold()).foregroundColor(.white), at: CGPoint(x: r.midX, y: max(r.minY - 10, 10)))
    }

    private func apply() {
        let m = m
        close()
        Windows.finish { try await m.finish() }
    }
}

// MARK: - Add Background

final class BackgroundModel: ObservableObject {
    enum Fill: Equatable { case color(Color), blur, transparent }
    let url: URL
    let previewImage: CIImage
    let previewMask: CIImage
    @Published var fill: Fill = .color(.white) { didSet { refresh() } }
    @Published var shadow = true { didSet { refresh() } }
    @Published var display: NSImage?

    init(url: URL) throws {
        self.url = url
        let cg = try ImageOps.load(url, maxPixel: 1400)
        previewImage = CIImage(cgImage: cg)
        previewMask = try Self.mask(cg)
        refresh()
    }

    static func mask(_ cg: CGImage) throws -> CIImage {
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: cg)
        try handler.perform([request])
        guard let result = request.results?.first else { throw AppError("No subject found to put on a new background") }
        return CIImage(cvPixelBuffer: try result.generateScaledMaskForImage(forInstances: result.allInstances, from: handler))
    }

    func compose(_ image: CIImage, mask: CIImage) -> CIImage {
        let extent = image.extent
        let background: CIImage
        switch fill {
        case .color(let c):
            background = CIImage(color: CIColor(color: NSColor(c)) ?? .white).cropped(to: extent)
        case .blur:
            background = image.clampedToExtent().applyingGaussianBlur(sigma: max(extent.width, extent.height) / 45).cropped(to: extent)
        case .transparent:
            background = CIImage(color: .clear).cropped(to: extent)
        }
        var bottom = background
        if shadow, fill != .transparent {
            let d = max(extent.width, extent.height)
            let soft = mask.clampedToExtent().applyingGaussianBlur(sigma: d / 120)
                .transformed(by: CGAffineTransform(translationX: d / 150, y: -d / 100)).cropped(to: extent)
            let dark = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.45)).cropped(to: extent)
            bottom = dark.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": background, "inputMaskImage": soft])
        }
        return image.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": bottom, "inputMaskImage": mask])
    }

    func refresh() {
        let out = compose(previewImage, mask: previewMask)
        if let cg = ImageOps.ciContext.createCGImage(out, from: out.extent) {
            display = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    func save() throws -> URL {
        let cg = try ImageOps.load(url)
        let out = compose(CIImage(cgImage: cg), mask: try Self.mask(cg))
        guard let result = ImageOps.ciContext.createCGImage(out, from: out.extent) else { throw AppError("Couldn’t render image") }
        let ext = fill == .transparent ? "png" : ImageOps.outputExt(for: url)
        let file = Output.url(for: url, suffix: "new background", ext: ext)
        try ImageOps.write(result, to: file, ext: ext, properties: ImageOps.metadata(url))
        return file
    }
}

@MainActor enum AddBackgroundPanel {
    static func open(_ url: URL) {
        Toast.shared.show("Finding the subject…", style: .progress)
        DispatchQueue.global(qos: .userInitiated).async {
            let result = Result { try BackgroundModel(url: url) }
            DispatchQueue.main.async {
                switch result {
                case .success(let model):
                    Toast.shared.hide()
                    _ = Windows.show("Add Background", size: NSSize(width: 620, height: 640)) { close in
                        AddBackgroundView(m: model, close: close)
                    }
                case .failure(let error):
                    Toast.shared.show(error.localizedDescription, style: .error)
                }
            }
        }
    }
}

struct AddBackgroundView: View {
    @ObservedObject var m: BackgroundModel
    let close: () -> Void
    @StateObject private var custom = CustomColor()
    final class CustomColor: ObservableObject { @Published var color = Color.teal }

    private let swatches: [Color] = [.white, .black, Color(white: 0.5), .red, .orange, .yellow, .green, .blue, .purple, .pink]

    var body: some View {
        VStack(spacing: 14) {
            ZStack {
                Checkerboard().clipShape(RoundedRectangle(cornerRadius: 10))
                if let d = m.display { Image(nsImage: d).resizable().scaledToFit().padding(8) }
            }
            HStack(spacing: 8) {
                ForEach(swatches.indices, id: \.self) { i in
                    Circle().fill(swatches[i]).frame(width: 26, height: 26)
                        .overlay(Circle().stroke(m.fill == .color(swatches[i]) ? Color.red : Color.gray.opacity(0.4),
                                                 lineWidth: m.fill == .color(swatches[i]) ? 3 : 1))
                        .onTapGesture { m.fill = .color(swatches[i]) }
                }
                ColorPicker("", selection: $custom.color).labelsHidden()
                    .onChange(of: custom.color) { m.fill = .color(custom.color) }
            }
            HStack {
                Button("Blur Original") { m.fill = .blur }.tint(m.fill == .blur ? .red : nil)
                Button("Transparent") { m.fill = .transparent }.tint(m.fill == .transparent ? .red : nil)
                Toggle("Drop Shadow", isOn: $m.shadow).disabled(m.fill == .transparent)
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply") { let m = m; close(); Windows.finish { try m.save() } }.keyboardShortcut(.defaultAction)
            }
            .buttonStyle(.bordered)
        }
        .padding(EdgeInsets(top: 34, leading: 16, bottom: 16, trailing: 16))
    }
}

struct Checkerboard: View {
    var body: some View {
        Canvas { ctx, size in
            let s: CGFloat = 12
            for y in stride(from: 0, to: size.height, by: s) {
                for x in stride(from: 0, to: size.width, by: s) where (Int(x / s) + Int(y / s)) % 2 == 0 {
                    ctx.fill(Path(CGRect(x: x, y: y, width: s, height: s)), with: .color(.gray.opacity(0.25)))
                }
            }
        }
    }
}
