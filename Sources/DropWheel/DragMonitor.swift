import AppKit

enum Mode { case convert, tools }

/// The key held during a drag to open the wheel. Adding Option switches to tools.
enum TriggerKey: String, CaseIterable {
    case shift, command, control

    static var current: TriggerKey {
        get { TriggerKey(rawValue: UserDefaults.standard.string(forKey: "triggerKey") ?? "") ?? .shift }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "triggerKey") }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .shift: return .shift
        case .command: return .command
        case .control: return .control
        }
    }

    var title: String {
        switch self {
        case .shift: return "Shift ⇧"
        case .command: return "Command ⌘"
        case .control: return "Control ⌃"
        }
    }
}

/// Watches system-wide drags. When a file drag is in progress and Shift is held,
/// it asks for the wheel; Option+Shift switches it to tools.
final class DragMonitor {
    var onShow: (([URL], Mode, NSPoint) -> Void)?
    var onModeChange: ((Mode) -> Void)?
    var onEnd: (() -> Void)?

    private let dragPasteboard = NSPasteboard(name: .drag)
    private var changeCountAtMouseDown = 0
    private var timer: Timer?
    private var shownMode: Mode?
    private var monitors: [Any] = []

    func start() {
        changeCountAtMouseDown = dragPasteboard.changeCount
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: { [weak self] _ in
            self?.mouseDown()
        }) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged, handler: { [weak self] _ in
            self?.dragged()
        }) { monitors.append(m) }
    }

    private func mouseDown() {
        changeCountAtMouseDown = dragPasteboard.changeCount
        shownMode = nil
    }

    private func dragged() {
        if timer == nil {
            // Poll while the button is held so modifier changes register even when the pointer is still.
            let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        }
        tick()
    }

    private func tick() {
        guard NSEvent.pressedMouseButtons & 1 != 0 else {
            finish()
            return
        }
        // Only real drags write to the drag pasteboard; window moves and selections don't.
        guard dragPasteboard.changeCount != changeCountAtMouseDown else { return }

        let flags = NSEvent.modifierFlags
        guard flags.contains(TriggerKey.current.flag) else { return }
        let mode: Mode = flags.contains(.option) ? .tools : .convert

        if let shown = shownMode {
            if shown != mode {
                shownMode = mode
                onModeChange?(mode)
            }
            return
        }
        let urls = fileURLs()
        guard !urls.isEmpty else { return }
        shownMode = mode
        onShow?(urls, mode, NSEvent.mouseLocation)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        if shownMode != nil {
            shownMode = nil
            onEnd?()
        }
        changeCountAtMouseDown = dragPasteboard.changeCount
    }

    private func fileURLs() -> [URL] {
        let objs = dragPasteboard.readObjects(forClasses: [NSURL.self],
                                              options: [.urlReadingFileURLsOnly: true]) as? [URL]
        return objs ?? []
    }
}
