import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let monitor = DragMonitor()
    private lazy var panel = WheelPanel()
    private var hideWork: DispatchWorkItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()

        monitor.onShow = { [weak self] urls, mode, point in self?.showWheel(urls: urls, mode: mode, at: point) }
        monitor.onModeChange = { [weak self] mode in self?.panel.wheel.setMode(mode) }
        monitor.onEnd = { [weak self] in self?.scheduleHide() }
        panel.wheel.onDrop = { action, urls in Runner.run(action, urls) }
        monitor.start()

        if !UserDefaults.standard.bool(forKey: "didShowWelcome") {
            UserDefaults.standard.set(true, forKey: "didShowWelcome")
            showHelp()
        }
    }

    private func showWheel(urls: [URL], mode: Mode, at point: NSPoint) {
        hideWork?.cancel()
        panel.wheel.configure(urls: urls, mode: mode)
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: point.x - size.width / 2, y: point.y - size.height / 2))
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        // Give the drop a moment to be delivered before the window goes away.
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.panel.animator().alphaValue = 0
            }, completionHandler: {
                self.panel.orderOut(nil)
                self.panel.wheel.highlighted = nil
            })
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    // MARK: Menu bar

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "circle.circle", accessibilityDescription: "DropWheel")
        let menu = NSMenu()
        menu.addItem(withTitle: "How to Use DropWheel", action: #selector(showHelp), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let triggerItem = menu.addItem(withTitle: "Trigger Key", action: nil, keyEquivalent: "")
        let triggerMenu = NSMenu()
        for key in TriggerKey.allCases {
            let item = triggerMenu.addItem(withTitle: key.title, action: #selector(chooseTrigger(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = key == TriggerKey.current ? .on : .off
        }
        triggerItem.submenu = triggerMenu
        let login = menu.addItem(withTitle: "Open at Login", action: #selector(toggleLogin(_:)), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit DropWheel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        statusItem.menu = menu
    }

    @objc private func chooseTrigger(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let key = TriggerKey(rawValue: raw) else { return }
        TriggerKey.current = key
        item.menu?.items.forEach { $0.state = ($0 === item) ? .on : .off }
    }

    @objc private func toggleLogin(_ item: NSMenuItem) {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
        item.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }

    @objc private func showHelp() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "DropWheel"
        alert.informativeText = """
        Start dragging a file in Finder, then hold \(TriggerKey.current.title) — a wheel of output formats appears around your pointer. Drop the file on the format you want, and the converted copy is saved right beside the original.

        Hold Option + \(TriggerKey.current.title) instead, and the wheel fills with tools for that kind of file. (You can change the trigger key from the menu bar icon.)

        Drop back in the middle to cancel. Everything happens on your Mac — nothing is uploaded.
        """
        alert.runModal()
    }
}

// Developer self-test: `DropWheel --test convert|tools <file>...` runs every non-window action on the files.
if CommandLine.arguments.count > 3, CommandLine.arguments[1] == "--test" {
    let mode: Mode = CommandLine.arguments[2] == "tools" ? .tools : .convert
    let urls = CommandLine.arguments.dropFirst(3).map { URL(fileURLWithPath: $0) }
    _ = NSApplication.shared
    Task { @MainActor in
        for action in Catalog.actions(for: urls, mode: mode) where !action.opensPanel {
            do {
                let outs = try await action.run(urls)
                print("OK   \(action.title): \(outs.map(\.lastPathComponent).joined(separator: ", "))")
            } catch {
                print("FAIL \(action.title): \(error.localizedDescription)")
            }
        }
        exit(0)
    }
    RunLoop.main.run()
}

if CommandLine.arguments.count > 4, CommandLine.arguments[1] == "--render-panel" {
    let a = CommandLine.arguments
    _ = NSApplication.shared
    NSApp.setActivationPolicy(.accessory)
    Task { @MainActor in
        do { try await SelfTest.renderPanel(a[2], file: URL(fileURLWithPath: a[3]), out: URL(fileURLWithPath: a[4])) }
        catch { print("FAIL \(error.localizedDescription)") }
        exit(0)
    }
    NSApp.run()
}

if CommandLine.arguments.count > 5, CommandLine.arguments[1] == "--test-panels" {
    _ = NSApplication.shared
    let a = CommandLine.arguments.map { URL(fileURLWithPath: $0) }
    Task { @MainActor in
        await SelfTest.panels(image: a[2], audio: a[3], video: a[4], pdf: a[5])
        exit(0)
    }
    RunLoop.main.run()
}

// Developer preview: `DropWheel --render convert|tools <file> <out.png> [highlight]` draws the wheel to a PNG.
if CommandLine.arguments.count > 4, CommandLine.arguments[1] == "--render" {
    _ = NSApplication.shared
    let args = CommandLine.arguments
    let view = WheelView(frame: NSRect(x: 0, y: 0, width: WheelPanel.side, height: WheelPanel.side))
    view.appearance = NSAppearance(named: .aqua)
    view.configure(urls: [URL(fileURLWithPath: args[3])], mode: args[2] == "tools" ? .tools : .convert)
    if args.count > 5 { view.highlighted = Int(args[5]) }
    RunLoop.main.run(until: Date().addingTimeInterval(1.5))  // let the Quick Look thumbnail arrive
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width * 2), pixelsHigh: Int(view.bounds.height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = view.bounds.size
    let bg = NSImage(size: view.bounds.size, flipped: false) { r in
        NSGradient(colors: [.systemOrange, .systemPink, .systemPurple])!.draw(in: r, angle: -45)
        NSColor.white.withAlphaComponent(0.25).setFill()
        NSBezierPath(ovalIn: r.insetBy(dx: 10, dy: 10)).fill()
        return true
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    bg.draw(in: view.bounds)
    NSGraphicsContext.restoreGraphicsState()
    view.cacheDisplay(in: view.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[4]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
