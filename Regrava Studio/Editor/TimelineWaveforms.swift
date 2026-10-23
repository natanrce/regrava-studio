import AppKit
import Combine
import RegravaCore
import RegravaRender
import SwiftUI

/// The audio waveforms drawn inside the clips: one layer per audio source, loaded in the
/// background and kept by file.
@MainActor
final class TimelineWaveforms: ObservableObject {
    enum Volume: Hashable {
        /// The clip's volume for that source (`FIRST_VOLUME_COLUMN + volumeColumn`).
        case slice(AudioSource)
        /// One volume for the whole timeline (background music).
        case fixed(Double)
    }

    struct Layer: Identifiable, Equatable {
        /// The file and track the levels come from.
        var id: String
        var pyramid: WaveformPyramid
        var hex: UInt32
        var opacity: Double
        var volume: Volume
        /// Background music follows the playback clock and repeats (`loopSampleCount`).
        var isLooping: Bool

        static func == (a: Layer, b: Layer) -> Bool {
            a.id == b.id && a.hex == b.hex && a.opacity == b.opacity && a.volume == b.volume && a.isLooping == b.isLooping
        }
    }

    private struct Input {
        var url: URL
        var track: Int
        var hex: UInt32
        var opacity: Double
        var volume: Volume
        var isLooping: Bool
        var key: String { "\(url.path)#\(track)" }
    }

    @Published private(set) var layers: [Layer] = []
    private var inputs: [Input] = []
    private var pyramids: [String: WaveformPyramid] = [:]
    private var loading: Set<String> = []

    /// Sources in drawing order, each skipped when missing or muted.
    func update(project: Project, bundle: URL, video: URL) {
        let audio = project.audio
        let sources = project.recording.audioSources
        var inputs: [Input] = []
        if let index = sources.firstIndex(of: .microphone), !audio.muteMicrophone {
            // The microphone's best finished render (`bestReadyPath`), else the take.
            if let rendered = MicrophoneRenderer.bestReadyURL(bundle: bundle, preset: audio.microphoneAudioPreset) {
                inputs.append(Input(url: rendered, track: 0, hex: 0xFFFFFF, opacity: 0.35, volume: .slice(.microphone), isLooping: false))
            } else {
                inputs.append(Input(url: video, track: index, hex: 0xFFFFFF, opacity: 0.35, volume: .slice(.microphone), isLooping: false))
            }
        }
        if let index = sources.firstIndex(of: .systemAudio), !audio.muteSystemAudio {
            inputs.append(Input(url: video, track: index, hex: 0x4D2FF5, opacity: 0.5, volume: .slice(.systemAudio), isLooping: false))
        }
        if let index = sources.firstIndex(of: .externalDevice), !audio.muteExternalDeviceAudio {
            inputs.append(Input(url: video, track: index, hex: 0x4A4453, opacity: 0.6, volume: .slice(.externalDevice), isLooping: false))
        }
        if let name = audio.backgroundAudioFileName, !audio.muteBackgroundAudio {
            let url = ProjectStore.assetsURL(bundle: bundle).appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                inputs.append(Input(url: url, track: 0, hex: 0x4D5344, opacity: 0.8, volume: .fixed(audio.backgroundAudioVolume), isLooping: true))
            }
        }
        self.inputs = inputs
        for input in inputs where pyramids[input.key] == nil && !loading.contains(input.key) {
            loading.insert(input.key)
            let key = input.key, url = input.url, track = input.track
            Task.detached(priority: .utility) {
                let levels = (try? await WaveformReader.levels(url: url, trackIndex: track)) ?? []
                let pyramid = WaveformPyramid(samples: levels)
                await MainActor.run {
                    self.loading.remove(key)
                    self.pyramids[key] = pyramid
                    self.publish()
                }
            }
        }
        publish()
    }

    private func publish() {
        let updated = inputs.compactMap { input -> Layer? in
            guard let pyramid = pyramids[input.key], pyramid.sampleCount > 0 else { return nil }
            return Layer(id: input.key, pyramid: pyramid, hex: input.hex, opacity: input.opacity, volume: input.volume, isLooping: input.isLooping)
        }
        if updated != layers { layers = updated }
    }
}

/// The waveforms of one clip's visible part, per device pixel like the `timeline/slice-waveform`
/// shader: filled from the clip's bottom edge, at most 32 px, 50 % → 100 % up each column, with a
/// 10 % full-volume ghost behind a lowered volume.
struct SliceWaveform: View, Equatable {
    var layers: [TimelineWaveforms.Layer]
    var slice: Slice
    var geometry: TimelineGeometry
    /// Timeline x of the clip's local x = 0.
    var originX: CGFloat
    /// Drawn part, in clip-local x.
    var visible: ClosedRange<CGFloat>
    var isSmooth: Bool
    var scale: CGFloat

    static func == (a: SliceWaveform, b: SliceWaveform) -> Bool {
        a.layers == b.layers && a.slice == b.slice && a.originX == b.originX && a.visible == b.visible && a.isSmooth == b.isSmooth
            && a.scale == b.scale && a.geometry.pxPerMs == b.geometry.pxPerMs && a.geometry.scrollOffsetMs == b.geometry.scrollOffsetMs
    }

    var body: some View {
        let height = AudioWaveform.heightPx
        if let image = render() {
            Image(decorative: image, scale: scale)
                .frame(width: visible.upperBound - visible.lowerBound, height: height)
                .offset(x: visible.lowerBound)
        }
    }

    private func render() -> CGImage? {
        let s = Double(scale)
        let columns = Int(((visible.upperBound - visible.lowerBound) * scale).rounded(.up))
        let rows = Int(AudioWaveform.heightPx * s)
        guard columns > 0, rows > 0, !layers.isEmpty else { return nil }
        var pixels = [Float](repeating: 0, count: columns * rows * 4)
        let pxPerMs = Double(geometry.pxPerMs)
        let pxPerBin: Double = isSmooth ? 5 : 2
        let playbackStart = geometry.resolver.sourceToPlayback(slice.sourceStartMs)
        let speed = slice.timeScale
        for layer in layers {
            let r = Float(Double((layer.hex >> 16) & 0xFF) / 255), g = Float(Double((layer.hex >> 8) & 0xFF) / 255), b = Float(Double(layer.hex & 0xFF) / 255)
            let volume: Double
            switch layer.volume {
            case .slice(let source): volume = slice.volume(for: source)
            case .fixed(let value): volume = value
            }
            let ghost = volume < 0.999
            let count = Double(layer.pyramid.sampleCount)
            let samplesPerBin = (layer.isLooping ? 1 : speed) / pxPerMs * AudioWaveform.samplesPerMs * pxPerBin
            for column in 0..<columns {
                let x = Double(originX + visible.lowerBound) + (Double(column) + 0.5) / s
                let playbackMs = geometry.scrollOffsetMs + (x - Double(EditorTimeline.horizontalPadding)) / pxPerMs
                let position = layer.isLooping
                    ? (playbackMs * AudioWaveform.samplesPerMs).truncatingRemainder(dividingBy: max(count, 1))
                    : (slice.sourceStartMs + (playbackMs - playbackStart) * speed) * AudioWaveform.samplesPerMs
                let level = layer.pyramid.envelope(at: position, samplesPerBin: samplesPerBin)
                guard level > 0 else { continue }
                let shapeHeight = level * volume * AudioWaveform.heightPx
                let ghostHeight = level * AudioWaveform.heightPx
                for row in 0..<rows {
                    let fromBottom = (Double(rows - row) - 0.5) / s
                    let shape = Float(layer.opacity * Self.fillUnder(shapeHeight, fromBottom, s))
                    let outline = ghost ? Float(0.1 * Self.fillUnder(ghostHeight, fromBottom, s)) : 0
                    let alpha = shape + outline * (1 - shape)
                    guard alpha > 0 else { continue }
                    // Premultiplied source-over onto the layers below.
                    let i = (row * columns + column) * 4
                    let keep = 1 - alpha
                    pixels[i] = r * alpha + pixels[i] * keep
                    pixels[i + 1] = g * alpha + pixels[i + 1] * keep
                    pixels[i + 2] = b * alpha + pixels[i + 2] * keep
                    pixels[i + 3] = alpha + pixels[i + 3] * keep
                }
            }
        }
        var bytes = [UInt8](repeating: 0, count: pixels.count)
        for i in 0..<pixels.count { bytes[i] = UInt8(min(max(pixels[i], 0), 1) * 255 + 0.5) }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: columns, height: rows, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: columns * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    /// `fillUnder`: 1 device px of anti-aliasing at the top, fading from 50 % at the bottom to
    /// 100 % at the column's own top.
    private static func fillUnder(_ height: Double, _ fromBottom: Double, _ scale: Double) -> Double {
        let coverage = min(max((height - fromBottom) * scale + 0.5, 0), 1)
        guard coverage > 0 else { return 0 }
        return coverage * (0.5 + 0.5 * min(max(fromBottom / max(height, 1), 0), 1))
    }
}
