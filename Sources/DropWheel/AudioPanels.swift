import AVFoundation
import SwiftUI

extension AudioOps {
    static func copy(_ b: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        slice(b, from: 0, to: Int(b.frameLength))
    }

    /// Replaces each range (fractions of the length) with a 1 kHz tone, ramped to avoid clicks.
    static func bleep(_ b: AVAudioPCMBuffer, ranges: [ClosedRange<Double>]) -> AVAudioPCMBuffer {
        let out = copy(b)
        let n = Int(out.frameLength), rate = out.format.sampleRate
        let ramp = Int(rate * 0.005)
        for r in ranges {
            let s = Int(r.lowerBound * Double(n)), e = min(Int(r.upperBound * Double(n)), n)
            guard e > s else { continue }
            for c in 0..<Int(out.format.channelCount) {
                let d = out.floatChannelData![c]
                for i in s..<e {
                    let edge = min(i - s, e - 1 - i)
                    let g = edge < ramp ? Float(edge) / Float(ramp) : 1
                    let tone = Float(sin(2 * .pi * 1000 * Double(i - s) / rate)) * 0.35
                    d[i] = d[i] * (1 - g) + tone * g
                }
            }
        }
        return out
    }

    /// Mono or stereo output with per-channel volume (0…2).
    static func channels(_ b: AVAudioPCMBuffer, stereo: Bool, left: Float, right: Float) -> AVAudioPCMBuffer {
        let n = Int(b.frameLength), ch = Int(b.format.channelCount)
        let l = b.floatChannelData![0], r = b.floatChannelData![min(1, ch - 1)]
        let out = make(b.format.sampleRate, stereo ? 2 : 1, n)
        if stereo {
            let ol = out.floatChannelData![0], or = out.floatChannelData![1]
            for i in 0..<n { ol[i] = l[i] * left; or[i] = r[i] * right }
        } else {
            let o = out.floatChannelData![0]
            for i in 0..<n { o[i] = (l[i] * left + r[i] * right) / 2 }
        }
        return out
    }
}

/// Plays a rendered buffer by writing it to a temporary WAV.
final class BufferPlayer: ObservableObject {
    @Published var playingTag: String?
    private var player: AVAudioPlayer?
    private var file: URL?

    func toggle(_ tag: String, _ make: () throws -> AVAudioPCMBuffer) {
        if playingTag == tag { stop(); return }
        stop()
        do {
            let tmp = Output.temporary(ext: "wav")
            try AudioOps.write(try make(), to: tmp, ext: "wav")
            let p = try AVAudioPlayer(contentsOf: tmp)
            p.play()
            player = p
            file = tmp
            playingTag = tag
            DispatchQueue.main.asyncAfter(deadline: .now() + p.duration) { [weak self, weak p] in
                if let self, self.player === p { self.stop() }
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
    }

    func stop() {
        player?.stop()
        player = nil
        if let file { try? FileManager.default.removeItem(at: file) }
        file = nil
        playingTag = nil
    }
}

struct Waveform: View {
    let peaks: [Float]
    var color: Color = .red
    var body: some View {
        Canvas { ctx, size in
            let bw = size.width / CGFloat(max(peaks.count, 1))
            for (i, p) in peaks.enumerated() {
                let h = max(1.5, CGFloat(p) * size.height * 0.92)
                ctx.fill(Path(CGRect(x: CGFloat(i) * bw, y: (size.height - h) / 2, width: max(1, bw - 0.8), height: h)),
                         with: .color(color))
            }
        }
    }
}

// MARK: - Bleep

final class BleepModel: ObservableObject {
    let url: URL
    let buffer: AVAudioPCMBuffer
    let peaks: [Float]
    let duration: Double
    @Published var ranges: [ClosedRange<Double>] = []
    @Published var draft: ClosedRange<Double>?
    let player = BufferPlayer()

    init(url: URL) throws {
        self.url = url
        buffer = try AudioOps.readAll(url)
        peaks = AudioOps.peaks(buffer, bins: 300)
        duration = Double(buffer.frameLength) / buffer.format.sampleRate
    }
}

@MainActor enum BleepPanel {
    static func open(_ url: URL) {
        do {
            let model = try BleepModel(url: url)
            let window = Windows.show("Bleep Audio", size: NSSize(width: 620, height: 360)) { close in
                BleepView(m: model, close: close)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                model.player.stop()
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
    }
}

struct BleepView: View {
    @ObservedObject var m: BleepModel
    @ObservedObject var player: BufferPlayer
    let close: () -> Void

    init(m: BleepModel, close: @escaping () -> Void) {
        self.m = m
        self.player = m.player
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bleeps \(m.ranges.count)").font(.callout.bold())
                Spacer()
                Text(AudioTrimView.time(m.duration)).font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            GeometryReader { geo in
                let w = geo.size.width
                VStack(spacing: 6) {
                    HStack(spacing: 8) {
                        Text("Bleep").font(.caption.bold()).foregroundStyle(.red).frame(width: 44, alignment: .leading)
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.08))
                            ForEach(Array((m.ranges + (m.draft.map { [$0] } ?? [])).enumerated()), id: \.offset) { _, r in
                                RoundedRectangle(cornerRadius: 4).fill(Color.red)
                                    .frame(width: max(3, (r.upperBound - r.lowerBound) * (w - 52)))
                                    .offset(x: r.lowerBound * (w - 52))
                            }
                        }
                        .frame(height: 30)
                    }
                    HStack(spacing: 8) {
                        Text("Audio").font(.caption.bold()).foregroundStyle(.secondary).frame(width: 44, alignment: .leading)
                        ZStack(alignment: .leading) {
                            Waveform(peaks: m.peaks, color: .red.opacity(0.75))
                            ForEach(Array(m.ranges.enumerated()), id: \.offset) { _, r in
                                Rectangle().fill(Color.black.opacity(0.25))
                                    .frame(width: max(3, (r.upperBound - r.lowerBound) * (w - 52)))
                                    .offset(x: r.lowerBound * (w - 52))
                            }
                        }
                    }
                }
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 2).onChanged { v in
                    let a = min(max((v.startLocation.x - 52) / (w - 52), 0), 1)
                    let b = min(max((v.location.x - 52) / (w - 52), 0), 1)
                    m.draft = min(a, b)...max(a, b)
                }.onEnded { _ in
                    if let d = m.draft, d.upperBound - d.lowerBound > 0.002 { m.ranges.append(d) }
                    m.draft = nil
                })
            }
            .frame(height: 140)

            Text("Drag across the Bleep lane or the waveform to cover a word. Use Undo to remove the last one.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Preview").font(.callout)
                Spacer()
                Button(player.playingTag == "orig" ? "Stop" : "Original") {
                    player.toggle("orig") { m.buffer }
                }
                Button { player.toggle("bleep") { AudioOps.bleep(m.buffer, ranges: m.ranges) } } label: {
                    Label(player.playingTag == "bleep" ? "Stop" : "With Bleeps", systemImage: "play.fill")
                }
                .disabled(m.ranges.isEmpty)
            }
            Divider()
            HStack {
                Button("Undo") { _ = m.ranges.popLast() }.disabled(m.ranges.isEmpty)
                Button("Clear") { m.ranges = [] }.disabled(m.ranges.isEmpty)
                Spacer()
                Button("Cancel") { player.stop(); close() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction).disabled(m.ranges.isEmpty)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 16, trailing: 18))
    }

    private func apply() {
        player.stop()
        let m = m
        close()
        Windows.finish {
            try await AudioOps.process(m.url, suffix: "bleeped") { AudioOps.bleep($0, ranges: m.ranges) }
        }
    }
}

// MARK: - Channels

final class ChannelsModel: ObservableObject {
    let url: URL
    let buffer: AVAudioPCMBuffer
    @Published var stereo: Bool
    @Published var left: Double = 100
    @Published var right: Double = 100
    let player = BufferPlayer()

    init(url: URL) throws {
        self.url = url
        buffer = try AudioOps.readAll(url)
        stereo = buffer.format.channelCount == 1
    }

    func output() -> AVAudioPCMBuffer {
        AudioOps.channels(buffer, stereo: stereo, left: Float(left / 100), right: Float(right / 100))
    }

    func peaks(channel: Int) -> [Float] {
        let out = output()
        let c = min(channel, Int(out.format.channelCount) - 1)
        let single = AudioOps.make(out.format.sampleRate, 1, Int(out.frameLength))
        memcpy(single.floatChannelData![0], out.floatChannelData![c], Int(out.frameLength) * 4)
        return AudioOps.peaks(single, bins: 160)
    }
}

@MainActor enum ChannelsPanel {
    static func open(_ url: URL) {
        do {
            let model = try ChannelsModel(url: url)
            let window = Windows.show("Convert Audio Channels", size: NSSize(width: 520, height: 400)) { close in
                ChannelsView(m: model, close: close)
            }
            NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
                model.player.stop()
            }
        } catch {
            Toast.shared.show(error.localizedDescription, style: .error)
        }
    }
}

struct ChannelsView: View {
    @ObservedObject var m: ChannelsModel
    @ObservedObject var player: BufferPlayer
    let close: () -> Void

    init(m: ChannelsModel, close: @escaping () -> Void) {
        self.m = m
        self.player = m.player
        self.close = close
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Output channel preview").font(.callout).foregroundStyle(.secondary)
            VStack(spacing: 6) {
                if m.stereo {
                    Waveform(peaks: m.peaks(channel: 0)).frame(height: 44)
                    Waveform(peaks: m.peaks(channel: 1)).frame(height: 44)
                } else {
                    Waveform(peaks: m.peaks(channel: 0)).frame(height: 94)
                }
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.red.opacity(0.06)))

            HStack {
                Text("Output")
                Spacer()
                Picker("", selection: $m.stereo) {
                    Text("Mono").tag(false)
                    Text("Stereo").tag(true)
                }
                .pickerStyle(.segmented).frame(width: 160)
            }
            volume("Left", $m.left)
            volume("Right", $m.right)
            HStack {
                Spacer()
                Button { player.toggle("out") { m.output() } } label: {
                    Label(player.playingTag == "out" ? "Stop" : "Play Output", systemImage: "play.fill")
                }
            }
            Divider()
            HStack {
                Text("Input: \(m.buffer.format.channelCount == 1 ? "mono" : "\(m.buffer.format.channelCount) channels")")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { player.stop(); close() }.keyboardShortcut(.cancelAction)
                Button("Apply") { apply() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(EdgeInsets(top: 34, leading: 18, bottom: 16, trailing: 18))
    }

    private func volume(_ name: String, _ v: Binding<Double>) -> some View {
        HStack {
            Text(name).frame(width: 44, alignment: .leading)
            Slider(value: v, in: 0...200).tint(.red)
            Text("\(Int(v.wrappedValue))%").monospacedDigit().frame(width: 48, alignment: .trailing)
        }
    }

    private func apply() {
        player.stop()
        let m = m
        close()
        Windows.finish {
            try await AudioOps.process(m.url, suffix: m.stereo ? "stereo" : "mono") { _ in m.output() }
        }
    }
}
