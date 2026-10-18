import AppKit
import AVFoundation
import AVKit
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PDFKit
import SwiftUI

/// Opens tool windows and keeps them alive until closed.
@MainActor enum Windows {
    private static var open: [NSWindow] = []

    static func show<V: View>(_ title: String, size: NSSize, @ViewBuilder content: (_ close: @escaping () -> Void) -> V) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        let close: () -> Void = { [weak window] in window?.close() }
        window.contentView = NSHostingView(rootView: content(close).frame(width: size.width, height: size.height))
        window.center()
        open.append(window)
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { note in
            MainActor.assumeIsolated { open.removeAll { $0 === note.object as? NSWindow } }
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        return window
    }

    static func finish(_ task: @escaping () async throws -> URL) {
        finishMany { [try await task()] }
    }

    static func finishMany(_ task: @escaping () async throws -> [URL]) {
        Toast.shared.show("Saving…", style: .progress)
        Task.detached {
            do {
                let outs = try await task()
                await MainActor.run { Runner.finished(outs) }
            } catch {
                await MainActor.run { Toast.shared.show(error.localizedDescription, style: .error) }
            }
        }
    }
}

// MARK: - Edit Photo

struct Adjustments: Equatable {
    var exposure = 0.0, brightness = 0.0, contrast = 0.0, saturation = 0.0
    var highlights = 0.0, shadows = 0.0, warmth = 0.0, vibrance = 0.0, sharpness = 0.0

    func apply(_ input: CIImage) -> CIImage {
        var img = input
        if exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(exposure); img = f.outputImage!
        }
        if brightness != 0 || contrast != 0 || saturation != 0 {
            let f = CIFilter.colorControls(); f.inputImage = img
            f.brightness = Float(brightness / 100 * 0.3)
            f.contrast = Float(1 + contrast / 100 * 0.5)
            f.saturation = Float(1 + saturation / 100)
            img = f.outputImage!
        }
        if highlights != 0 || shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = img
            f.highlightAmount = Float(1 + highlights / 100)
            f.shadowAmount = Float(shadows / 100)
            img = f.outputImage!
        }
        if warmth != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: 6500 + warmth * 30, y: 0)
            img = f.outputImage!
        }
        if vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(vibrance / 100); img = f.outputImage!
        }
        if sharpness > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(sharpness / 100 * 2); img = f.outputImage!
        }
        return img.cropped(to: input.extent)
    }
}

@MainActor enum EditPhotoPanel {
    static func open(_ url: URL) {
        do {
            let preview = try ImageOps.load(url, maxPixel: 1400)
            _ = Windows.show("Edit Photo", size: NSSize(width: 520, height: 720)) { close in
                EditPhotoView(url: url, base: CIImage(cgImage: preview), close: close)
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
    }
}

final class EditState: ObservableObject {
    @Published var adj = Adjustments()
    @Published var rendered: NSImage?
}

struct EditPhotoView: View {
    let url: URL
    let base: CIImage
    let close: () -> Void
    @StateObject private var st = EditState()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.85))
                if let img = st.rendered { Image(nsImage: img).resizable().scaledToFit().padding(8) }
            }
            .frame(height: 330)

            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    section("Light")
                    row("Exposure", $st.adj.exposure, -2...2, format: "%.2f EV")
                    row("Brightness", $st.adj.brightness, -100...100)
                    row("Contrast", $st.adj.contrast, -100...100)
                    row("Highlights", $st.adj.highlights, -100...0)
                    row("Shadows", $st.adj.shadows, 0...100)
                    section("Color")
                    row("Saturation", $st.adj.saturation, -100...100)
                    row("Vibrance", $st.adj.vibrance, -100...100)
                    row("Warmth", $st.adj.warmth, -100...100)
                    section("Detail")
                    row("Sharpness", $st.adj.sharpness, 0...100)
                }
            }

            HStack {
                Button("Reset") { st.adj = Adjustments() }.disabled(st.adj == Adjustments())
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 16, trailing: 18))
        .onAppear(perform: render)
        .onChange(of: st.adj) { render() }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(.subheadline.bold()).foregroundStyle(.red).padding(.top, 6)
    }

    private func row(_ name: String, _ value: Binding<Double>, _ range: ClosedRange<Double>, format: String = "%+.0f") -> some View {
        HStack {
            Text(name).frame(width: 90, alignment: .leading)
            Slider(value: value, in: range).tint(.red)
            Text(String(format: format, value.wrappedValue)).monospacedDigit().frame(width: 70, alignment: .trailing)
            Button { value.wrappedValue = 0 } label: { Image(systemName: "arrow.counterclockwise") }
                .buttonStyle(.borderless).disabled(value.wrappedValue == 0)
        }
        .font(.callout)
    }

    private func render() {
        let out = st.adj.apply(base)
        if let cg = ImageOps.ciContext.createCGImage(out, from: out.extent) {
            st.rendered = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }
    }

    private func apply() {
        let adj = st.adj, url = url
        close()
        Windows.finish {
            try ImageOps.save(adj.apply(CIImage(cgImage: try ImageOps.load(url))), from: url, suffix: "edited")
        }
    }
}

// MARK: - Trim Audio

@MainActor enum AudioTrimPanel {
    static func open(_ url: URL) {
        do {
            let buffer = try AudioOps.readAll(url)
            _ = Windows.show("Trim Audio", size: NSSize(width: 560, height: 330)) { close in
                AudioTrimView(url: url, buffer: buffer, close: close)
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
    }
}

final class TrimState: ObservableObject {
    @Published var start = 0.0
    @Published var end = 1.0
    @Published var trimSilence = false
    @Published var player: AVAudioPlayer?
    var stopTimer: Timer?
}

struct AudioTrimView: View {
    let url: URL
    let buffer: AVAudioPCMBuffer
    let close: () -> Void
    private let peaks: [Float]
    private let duration: Double

    @StateObject private var st = TrimState()

    init(url: URL, buffer: AVAudioPCMBuffer, close: @escaping () -> Void) {
        self.url = url
        self.buffer = buffer
        self.close = close
        peaks = AudioOps.peaks(buffer, bins: 220)
        duration = Double(buffer.frameLength) / buffer.format.sampleRate
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Drag the ends to trim").foregroundStyle(.secondary)
                Spacer()
                Text("\(Self.time((st.end - st.start) * duration)) selected").foregroundStyle(.secondary)
            }
            .font(.callout)

            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack(alignment: .topLeading) {
                    Canvas { ctx, size in
                        let bw = size.width / CGFloat(max(peaks.count, 1))
                        for (i, p) in peaks.enumerated() {
                            let x = CGFloat(i) * bw
                            let ph = max(2, CGFloat(p) * size.height * 0.9)
                            let inside = Double(x / size.width) >= st.start && Double(x / size.width) <= st.end
                            ctx.fill(Path(CGRect(x: x, y: (size.height - ph) / 2, width: max(1, bw - 1), height: ph)),
                                     with: .color(inside ? .red : .gray.opacity(0.45)))
                        }
                    }
                    Rectangle().stroke(Color.red, lineWidth: 3)
                        .frame(width: max(0, (st.end - st.start) * w), height: h)
                        .offset(x: st.start * w)
                    handle.offset(x: st.start * w - 7)
                        .gesture(DragGesture().onChanged { st.start = min(max(0, $0.location.x / w), st.end - 0.01) })
                    handle.offset(x: st.end * w - 7)
                        .gesture(DragGesture().onChanged { st.end = max(min(1, $0.location.x / w), st.start + 0.01) })
                }
            }
            .frame(height: 120)

            HStack {
                Text("Start \(Self.time(st.start * duration))")
                Spacer()
                Text("End \(Self.time(st.end * duration))")
            }
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)

            Toggle("Trim silent ends automatically", isOn: $st.trimSilence)
                .onChange(of: st.trimSilence) { if st.trimSilence { detectSilence() } else { st.start = 0; st.end = 1 } }

            HStack {
                Spacer()
                Button { play() } label: { Label(st.player?.isPlaying == true ? "Stop" : "Play Selected Range", systemImage: "play.fill") }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { st.player?.stop(); close() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 16, trailing: 18))
    }

    private var handle: some View {
        RoundedRectangle(cornerRadius: 4).fill(Color.red)
            .frame(width: 14, height: 120)
            .overlay(Capsule().fill(.white).frame(width: 3, height: 34))
            .contentShape(Rectangle())
    }

    static func time(_ s: Double) -> String {
        String(format: "%d:%05.2f", Int(s) / 60, s.truncatingRemainder(dividingBy: 60))
    }

    private func detectSilence() {
        let threshold: Float = 0.02
        guard let first = peaks.firstIndex(where: { $0 > threshold }),
              let last = peaks.lastIndex(where: { $0 > threshold }) else { return }
        st.start = Double(first) / Double(peaks.count)
        st.end = Double(last + 1) / Double(peaks.count)
    }

    private func play() {
        if let p = st.player, p.isPlaying { p.stop(); st.stopTimer?.invalidate(); st.player = nil; return }
        guard let p = try? AVAudioPlayer(contentsOf: url) else { return }
        p.currentTime = st.start * duration
        p.play()
        st.player = p
        st.stopTimer?.invalidate()
        st.stopTimer = Timer.scheduledTimer(withTimeInterval: (st.end - st.start) * duration, repeats: false) { _ in
            p.stop()
            Task { @MainActor in st.player = nil }
        }
    }

    private func apply() {
        st.player?.stop()
        let n = Double(buffer.frameLength)
        let from = Int(st.start * n), to = Int(st.end * n)
        let url = url, buffer = buffer
        close()
        Windows.finish {
            try await AudioOps.process(url, suffix: "trimmed") { _ in AudioOps.slice(buffer, from: from, to: to) }
        }
    }
}

// MARK: - Trim Video

@MainActor enum VideoTrimPanel {
    static func open(_ url: URL) {
        let playerView = AVPlayerView()
        playerView.controlsStyle = .inline
        playerView.player = AVPlayer(url: url)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 480),
                              styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Trim — \(url.lastPathComponent)"
        window.isReleasedWhenClosed = false
        window.contentView = playerView
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        Task { @MainActor in
            // Trimming can only begin once the item is ready.
            for _ in 0..<50 where !playerView.canBeginTrimming { try? await Task.sleep(for: .milliseconds(100)) }
            guard playerView.canBeginTrimming else {
                Toast.shared.show("This video can’t be trimmed", style: .error)
                window.close()
                return
            }
            let result = await playerView.beginTrimming()
            let item = playerView.player?.currentItem
            playerView.player?.pause()
            window.close()
            guard result == .okButton, let item else { return }
            let start = item.reversePlaybackEndTime.isValid ? item.reversePlaybackEndTime : .zero
            let end = item.forwardPlaybackEndTime.isValid ? item.forwardPlaybackEndTime : item.duration
            Windows.finish { try await VideoOps.trim(url, range: CMTimeRange(start: start, end: end)) }
        }
    }
}

