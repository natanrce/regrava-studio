import Foundation
import RegravaCore

/// While paused, loops the mix around a changed clip so its new level can be heard: up to
/// 2 s, kept playing until 0.5 s after the last change. A new mix (the change) crossfades in
/// at the same position; a new stretch crossfades in at its start.
final class PreviewPlayer {
    /// Voices kept at most; the quietest older one goes.
    static let maximumVoices = 4

    private final class Voice {
        let renderer: MixRenderer
        var gain: Float
        init(renderer: MixRenderer, gain: Float) {
            self.renderer = renderer
            self.gain = gain
        }
    }

    private let catalog: MixSourceCatalog
    private var layout: MixLayout
    private(set) var loop: AudioPreviewLoop?
    private var voices: [Voice] = []
    private(set) var master: Float = 0
    /// Host time the preview fades out at, ms.
    private(set) var untilHostMs = -Double.infinity
    private var scratchLeft = [Float](repeating: 0, count: 1024)
    private var scratchRight = [Float](repeating: 0, count: 1024)
    private var gainSum = [Float](repeating: 0, count: 1024)

    init(layout: MixLayout, catalog: MixSourceCatalog) {
        self.layout = layout
        self.catalog = catalog
    }

    var hasVoices: Bool { !voices.isEmpty }
    /// Where the newest voice is.
    var newestPosition: Int64? { voices.last?.renderer.position }

    func request(timeMs: Double, changed: (startMs: Double, endMs: Double), hostMs: Double) {
        let next = AudioPreviewLoop(timeMs: timeMs, changedStartMs: changed.startMs, changedEndMs: changed.endMs)
        let audible = master > 0 || (!voices.isEmpty && hostMs < untilHostMs)
        untilHostMs = hostMs + AudioPreviewLoop.holdMs
        if loop != next {
            loop = next
            if audible {
                startVoice(at: Int64(next.startFrame), layout: layout)
                return
            }
        } else {
            if audible { return }
            loop = next
        }
        let renderer = MixRenderer(layout: layout, catalog: catalog)
        renderer.seek(to: Int64(next.startFrame))
        voices = [Voice(renderer: renderer, gain: 1)]
        master = 0
    }

    /// A new mix: a voice of it takes over where the newest one is.
    func setLayout(_ layout: MixLayout) {
        self.layout = layout
        if let position = voices.last?.renderer.position { startVoice(at: position, layout: layout) }
    }

    private func startVoice(at frame: Int64, layout: MixLayout) {
        let renderer = MixRenderer(layout: layout, catalog: catalog)
        renderer.seek(to: frame)
        voices.append(Voice(renderer: renderer, gain: 0))
        if voices.count > Self.maximumVoices {
            // The quietest of the older voices (the first one when tied).
            var quietest = 0
            for i in 1..<(voices.count - 1) where !(voices[quietest].gain <= voices[i].gain) { quietest = i }
            voices.remove(at: quietest)
        }
    }

    /// Renders `count` frames heard from `hostMs` on.
    func renderVoices(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int, hostMs: Double) {
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        guard let loop, let newest = voices.last else { return }
        if newest.renderer.position >= Int64(loop.endFrame) { startVoice(at: Int64(loop.startFrame), layout: layout) }
        if gainSum.count < count {
            scratchLeft = [Float](repeating: 0, count: count)
            scratchRight = [Float](repeating: 0, count: count)
            gainSum = [Float](repeating: 0, count: count)
        }
        for i in 0..<gainSum.count { gainSum[i] = 0 }
        scratchLeft.withUnsafeMutableBufferPointer { sl in
            scratchRight.withUnsafeMutableBufferPointer { sr in
                gainSum.withUnsafeMutableBufferPointer { sum in
                    let count0 = voices.count
                    for (index, voice) in voices.enumerated() {
                        voice.renderer.render(left: sl.baseAddress!, right: sr.baseAddress!, count: count)
                        var g = voice.gain
                        let isNewest = index == count0 - 1
                        for k in 0..<count {
                            g = PreviewGainRamp.stepVoice(g, isNewest: isNewest)
                            left[k] += g * sl[k]
                            right[k] += g * sr[k]
                            sum[k] = g + sum[k]
                        }
                        voice.gain = g
                    }
                    let fadingOut = untilHostMs <= hostMs
                    for k in 0..<count {
                        master = PreviewGainRamp.stepMaster(master, fadingOut: fadingOut)
                        let scale = PreviewGainRamp.outputScale(master: master, voiceGainSum: sum[k])
                        left[k] *= scale
                        right[k] *= scale
                    }
                }
            }
        }
        let last = voices.removeLast()
        voices.removeAll { $0.gain == 0 }
        voices.append(last)
        if master == 0 && untilHostMs <= hostMs {
            voices = []
            self.loop = nil
        }
    }
}
