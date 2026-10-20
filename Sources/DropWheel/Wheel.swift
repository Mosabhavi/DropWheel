import AppKit
import QuickLookThumbnailing

final class WheelPanel: NSPanel {
    static let side: CGFloat = 380
    let wheel: WheelView

    init() {
        let rect = NSRect(x: 0, y: 0, width: Self.side, height: Self.side)
        wheel = WheelView(frame: rect)
        super.init(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let root = NSView(frame: rect)
        let blur = NSVisualEffectView(frame: rect)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        let discRect = rect.insetBy(dx: Self.side / 2 - wheel.outerR - 6, dy: Self.side / 2 - wheel.outerR - 6)
        blur.maskImage = NSImage(size: rect.size, flipped: false) { _ in
            NSColor.black.setFill()
            NSBezierPath(ovalIn: discRect).fill()
            return true
        }
        root.addSubview(blur)
        root.addSubview(wheel)
        contentView = root
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class WheelView: NSView {
    let outerR: CGFloat = 168
    let innerR: CGFloat = 62
    private let accent = NSColor(srgbRed: 0.95, green: 0.27, blue: 0.20, alpha: 1)

    var onDrop: ((WheelAction, [URL]) -> Void)?
    private(set) var actions: [WheelAction] = []
    private var urls: [URL] = []
    private var thumbnail: NSImage?
    private var sizeText = ""

    var highlighted: Int? {
        didSet {
            guard oldValue != highlighted else { return }
            needsDisplay = true
            if highlighted != nil {
                NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
            }
        }
    }

    private var center: CGPoint { CGPoint(x: bounds.midX, y: bounds.midY) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(urls: [URL], mode: Mode) {
        self.urls = urls
        highlighted = nil
        actions = Catalog.actions(for: urls, mode: mode)
        sizeText = Self.totalSize(urls)
        thumbnail = NSWorkspace.shared.icon(forFile: urls[0].path)
        needsDisplay = true

        let request = QLThumbnailGenerator.Request(fileAt: urls[0], size: CGSize(width: 160, height: 160),
                                                   scale: 2, representationTypes: .thumbnail)
        let expected = urls
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { [weak self] rep, _ in
            guard let rep else { return }
            DispatchQueue.main.async {
                guard let self, self.urls == expected else { return }
                self.thumbnail = rep.nsImage
                self.needsDisplay = true
            }
        }
    }

    func setMode(_ mode: Mode) {
        actions = Catalog.actions(for: urls, mode: mode)
        highlighted = nil
        needsDisplay = true
    }

    private static func totalSize(_ urls: [URL]) -> String {
        var total: Int64 = 0
        for u in urls {
            if let v = try? u.resourceValues(forKeys: [.totalFileSizeKey, .fileSizeKey]) {
                total += Int64(v.totalFileSize ?? v.fileSize ?? 0)
            }
        }
        let s = ByteCountFormatter.string(fromByteCount: total, countStyle: .file)
        return urls.count > 1 ? "\(urls.count) files · \(s)" : s
    }

    // MARK: Geometry

    private func span() -> CGFloat { 2 * .pi / CGFloat(max(actions.count, 1)) }

    /// Segment i is centred at the top for i = 0 and proceeds clockwise.
    private func midAngle(_ i: Int) -> CGFloat { .pi / 2 - CGFloat(i) * span() }

    private func sectorPath(_ i: Int) -> NSBezierPath {
        let mid = midAngle(i), half = span() / 2
        let gap: CGFloat = 6, inset: CGFloat = 10
        let ro = outerR - inset, ri = innerR + inset
        let dOut = (gap / 2 + inset) / ro
        let dIn = min((gap / 2 + inset) / ri, half * 0.9)
        let deg: (CGFloat) -> CGFloat = { $0 * 180 / .pi }
        let p = NSBezierPath()
        p.appendArc(withCenter: center, radius: ro, startAngle: deg(mid + half - dOut),
                    endAngle: deg(mid - half + dOut), clockwise: true)
        p.appendArc(withCenter: center, radius: ri, startAngle: deg(mid - half + dIn),
                    endAngle: deg(mid + half - dIn), clockwise: false)
        p.close()
        // Stroking with a wide round join rounds the corners and grows the shape back to full size.
        p.lineWidth = inset * 2
        p.lineJoinStyle = .round
        return p
    }

    private func index(at p: CGPoint) -> Int? {
        let dx = p.x - center.x, dy = p.y - center.y
        let d = hypot(dx, dy)
        guard !actions.isEmpty, d > innerR - 2, d < outerR + 50 else { return nil }
        let s = span()
        var t = (.pi / 2 + s / 2) - atan2(dy, dx)
        t = t.truncatingRemainder(dividingBy: 2 * .pi)
        if t < 0 { t += 2 * .pi }
        return min(Int(t / s), actions.count - 1)
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua

        // Outer rim
        let rim = NSBezierPath(ovalIn: NSRect(x: center.x - outerR - 5, y: center.y - outerR - 5,
                                              width: (outerR + 5) * 2, height: (outerR + 5) * 2))
        NSColor.white.withAlphaComponent(dark ? 0.18 : 0.6).setStroke()
        rim.lineWidth = 1
        rim.stroke()

        for (i, action) in actions.enumerated() {
            let path = sectorPath(i)
            let isOn = highlighted == i
            // Fill and stroke overlap, so draw them opaque inside a layer and apply the alpha once.
            let ctx = NSGraphicsContext.current!.cgContext
            ctx.saveGState()
            ctx.setAlpha(isOn ? 1 : (dark ? 0.16 : 0.62))
            ctx.beginTransparencyLayer(auxiliaryInfo: nil)
            let fill: NSColor = isOn ? accent : .white
            fill.setFill()
            fill.setStroke()
            path.fill()
            path.stroke()
            ctx.endTransparencyLayer()
            ctx.restoreGState()
            drawLabel(action, at: i, highlighted: isOn, dark: dark)
        }

        drawCenter(dark: dark)
    }

    private func drawLabel(_ action: WheelAction, at i: Int, highlighted: Bool, dark: Bool) {
        let mid = midAngle(i)
        let r = (innerR + outerR) / 2 + 4
        let pt = CGPoint(x: center.x + cos(mid) * r, y: center.y + sin(mid) * r)
        let color: NSColor = highlighted ? .white : (dark ? .white : NSColor(white: 0.12, alpha: 1))
        // Shrink long labels until they fit the segment's width at this radius.
        let room = 2 * r * sin(span() / 2) - 16
        var fontSize: CGFloat = action.symbol == nil ? 14 : 10
        var text: NSAttributedString
        repeat {
            let font = NSFont.systemFont(ofSize: fontSize, weight: action.symbol == nil ? .bold : .heavy)
            text = NSAttributedString(string: action.title.uppercased(), attributes: [
                .font: font, .foregroundColor: color, .kern: 0.4,
            ])
            fontSize -= 0.5
        } while text.size().width > room && fontSize >= 8
        let ts = text.size()

        if let name = action.symbol,
           let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 17, weight: .semibold)) {
            let tinted = img.tinted(color)
            let iconRect = NSRect(x: pt.x - tinted.size.width / 2, y: pt.y + 1,
                                  width: tinted.size.width, height: tinted.size.height)
            tinted.draw(in: iconRect)
            text.draw(at: CGPoint(x: pt.x - ts.width / 2, y: pt.y - ts.height - 3))
        } else {
            text.draw(at: CGPoint(x: pt.x - ts.width / 2, y: pt.y - ts.height / 2))
        }
    }

    private func drawCenter(dark: Bool) {
        let r = innerR - 8
        let disc = NSRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2)
        if let thumb = thumbnail {
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(ovalIn: disc).addClip()
            // Aspect-fill into the disc.
            let s = thumb.size
            let scale = max(disc.width / max(s.width, 1), disc.height / max(s.height, 1))
            let w = s.width * scale, h = s.height * scale
            thumb.draw(in: NSRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h))
            NSGraphicsContext.restoreGraphicsState()
        }

        let label = NSAttributedString(string: highlighted.map { actions[$0].title } ?? sizeText, attributes: [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: NSColor(white: 0.1, alpha: 1),
        ])
        let ls = label.size()
        let pill = NSRect(x: center.x - ls.width / 2 - 10, y: center.y - ls.height / 2 - 5,
                          width: ls.width + 20, height: ls.height + 10)
        NSColor.white.withAlphaComponent(0.82).setFill()
        NSBezierPath(roundedRect: pill, xRadius: pill.height / 2, yRadius: pill.height / 2).fill()
        label.draw(at: CGPoint(x: pill.minX + 10, y: pill.minY + 5))
    }

    // MARK: Drop target

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { highlighted = nil }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        highlighted = index(at: convert(sender.draggingLocation, from: nil))
        return highlighted == nil ? [] : .copy
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let i = index(at: convert(sender.draggingLocation, from: nil)) else { return false }
        let dropped = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                                            options: [.urlReadingFileURLsOnly: true]) as? [URL]
        let targets = (dropped?.isEmpty == false) ? dropped! : urls
        let action = actions[i]
        highlighted = nil
        DispatchQueue.main.async { self.onDrop?(action, targets) }
        return true
    }
}

extension NSImage {
    func tinted(_ color: NSColor) -> NSImage {
        let img = NSImage(size: size, flipped: false) { rect in
            self.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return img
    }
}
