import Foundation
import RegravaCore

/// Renders a layout from a position on: each clip as a voice from its source (through a time
/// stretcher when it plays at another speed), summed at its gain and clipped to ±1.
final class MixRenderer {
    /// A source starts this much earlier when stretched, so the stretcher has audio to work on.
    static let stretchLeadSeconds = 0.1

    private final class Voice {
        let clip: MixClip
        let reader: MixSourceReader
        let stretcher: TimeStretcher?

        init(clip: MixClip, startingAt offset: Int64, catalog: MixSourceCatalog) throws {
            self.clip = clip
            let source = try catalog.source(at: clip.source)
            let start = clip.sourceStartSeconds + (Double(offset) / MixFormat.sampleRate) * clip.speed
            if clip.speed == 1 {
                reader = try makeReader(for: source, startSeconds: start)
                stretcher = nil
            } else {
                let readerStart = max(start - MixRenderer.stretchLeadSeconds, 0)
                let reader = try makeReader(for: source, startSeconds: readerStart)
                self.reader = reader
                let stretcher = try TimeStretcher(speed: clip.speed, algorithm: .current) { left, right, count in
                    reader.read(left: left, right: right, count: count)
                }
                stretcher.skip(stretcher.latencyFrames + Int(MixFormat.frames(seconds: (start - readerStart) / clip.speed)))
                self.stretcher = stretcher
            }
        }
    }

    let layout: MixLayout
    private let catalog: MixSourceCatalog
    private(set) var position: Int64 = 0
    /// The first problem met, kept.
    private(set) var failure: String?
    private var voices: [Voice] = []
    private var nextClipIndex = 0
    private var scratchLeft: [Float] = []
    private var scratchRight: [Float] = []

    init(layout: MixLayout, catalog: MixSourceCatalog) {
        self.layout = layout
        self.catalog = catalog
    }

    func seek(to frame: Int64) {
        voices = []
        position = max(frame, 0)
        let clips = layout.clips
        nextClipIndex = clips.firstIndex { position <= $0.startFrame } ?? clips.count
        for clip in clips[0..<nextClipIndex] where position < clip.endFrame {
            do {
                voices.append(try Voice(clip: clip, startingAt: max(position - clip.startFrame, 0), catalog: catalog))
            } catch {
                if failure == nil { failure = String(describing: error) }
            }
        }
    }

    func render(left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, count: Int) {
        left.update(repeating: 0, count: count)
        right.update(repeating: 0, count: count)
        let end = position + Int64(count)
        let clips = layout.clips
        while nextClipIndex < clips.count, clips[nextClipIndex].startFrame < end {
            let clip = clips[nextClipIndex]
            do {
                voices.append(try Voice(clip: clip, startingAt: max(position - clip.startFrame, 0), catalog: catalog))
            } catch {
                if failure == nil { failure = String(describing: error) }
            }
            nextClipIndex += 1
        }
        if scratchLeft.count < count {
            scratchLeft = [Float](repeating: 0, count: count)
            scratchRight = [Float](repeating: 0, count: count)
        }
        scratchLeft.withUnsafeMutableBufferPointer { sl in
            scratchRight.withUnsafeMutableBufferPointer { sr in
                let sLeft = sl.baseAddress!, sRight = sr.baseAddress!
                for voice in voices {
                    let clip = voice.clip
                    let from = max(clip.startFrame, position), to = min(clip.endFrame, end)
                    guard from < to else { continue }
                    let n = Int(to - from)
                    if let stretcher = voice.stretcher {
                        stretcher.render(left: sLeft, right: sRight, count: n)
                    } else {
                        voice.reader.read(left: sLeft, right: sRight, count: n)
                    }
                    let outOffset = Int(from - position)
                    var local = from - clip.startFrame
                    for i in 0..<n {
                        let g = clip.gain(atLocalFrame: local)
                        left[outOffset + i] += g * sLeft[i]
                        right[outOffset + i] += g * sRight[i]
                        local += 1
                    }
                }
            }
        }
        if failure == nil, let broken = voices.first(where: { $0.reader.failure != nil }) {
            failure = "Cannot read the audio of \(broken.clip.source.path): \(broken.reader.failure!)"
        }
        voices.removeAll { $0.clip.endFrame <= end }
        for i in 0..<count {
            left[i] = min(max(left[i], -1), 1)
            right[i] = min(max(right[i], -1), 1)
        }
        position = end
    }
}
