import AppKit

/// A small HUD near the bottom of the screen that reports progress and results.
final class Toast {
    static let shared = Toast()
    enum Style { case progress, success, error }

    private let panel: NSPanel
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private var hideWork: DispatchWorkItem?

    private init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 300, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .statusBar
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 22
        blur.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: 13, weight: .semibold)
        label.lineBreakMode = .byTruncatingMiddle
        spinner.style = .spinning
        spinner.controlSize = .small

        let stack = NSStackView(views: [spinner, icon, label])
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 16, bottom: 0, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.centerYAnchor.constraint(equalTo: blur.centerYAnchor),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 420),
        ])
        panel.contentView = blur
    }

    func show(_ text: String, style: Style) {
        hideWork?.cancel()
        label.stringValue = text
        spinner.isHidden = style != .progress
        icon.isHidden = style == .progress
        if style == .progress { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
        let symbol = style == .success ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.contentTintColor = style == .success ? .systemGreen : .systemOrange

        let width = min(max(label.intrinsicContentSize.width + 70, 160), 480)
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        if let f = screen?.visibleFrame {
            panel.setFrame(NSRect(x: f.midX - width / 2, y: f.minY + 80, width: width, height: 44), display: true)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        if style != .progress {
            let work = DispatchWorkItem { [weak self] in self?.hide() }
            hideWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + (style == .error ? 4 : 2.2), execute: work)
        }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; panel.animator().alphaValue = 0 },
                                             completionHandler: { self.panel.orderOut(nil) })
    }
}
