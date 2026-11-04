@preconcurrency import AVFoundation
import Foundation
import RegravaCore
import RegravaRender

/// While paused, a volume being dragged plays the mix around the playhead so the change can be
/// heard: a stretch of up to 2 s repeated until 0.5 s after the last change, then faded out.
/// A newer mix takes over at the same point of the stretch, crossfaded.
@MainActor
final class AudioChangePreview {
    private let engine = AVAudioEngine()
    private let format = AVAudioFormat(standardFormatWithSampleRate: AudioPreviewLoop.sampleRate, channels: 2)!

    private final class Voice {
        let node = AVAudioPlayerNode()
        let loop: AudioPreviewLoop
        let frames: AVAudioFramePosition
        /// The stretch frame this voice started at.
        let offset: AVAudioFramePosition

        init(loop: AudioPreviewLoop, frames: AVAudioFramePosition, offset: AVAudioFramePosition) {
            self.loop = loop
            self.frames = frames
            self.offset = offset
        }

        /// Where in the stretch it is now.
        var position: AVAudioFramePosition? {
            guard let time = node.lastRenderTime, let played = node.playerTime(forNodeTime: time) else { return nil }
            return (offset + max(played.sampleTime, 0)) % max(frames, 1)
        }
    }

    private var voices: [Voice] = []
    private var renderTask: Task<Void, Never>?
    private var pending: (editor: EditorModel, loop: AudioPreviewLoop)?
    private var playsUntil: Date = .distantPast
    private var holdTimer: Timer?
    private var ramps: [ObjectIdentifier: Timer] = [:]

    /// `previewAudioChange`: the changed clips' playback ranges; the one under the playhead, else
    /// the first.
    func request(_ editor: EditorModel, changed ranges: [(startMs: Double, endMs: Double)]) {
        guard !editor.isPlaying, !editor.player.isMuted, !editor.exports.isExporting else { return }
        let t = editor.clock.currentTimeMs
        guard let range = ranges.first(where: { $0.startMs <= t && t < $0.endMs }) ?? ranges.first else { return }
        let loop = AudioPreviewLoop(timeMs: t, changedStartMs: range.startMs, changedEndMs: range.endMs)
        playsUntil = Date().addingTimeInterval(AudioPreviewLoop.holdMs / 1000)
        armHoldTimer(editor)
        pending = (editor, loop)
        if renderTask == nil { renderNext() }
    }

    /// Renders the latest request's mix; requests arriving meanwhile wait for it, only the newest.
    private func renderNext() {
        guard let (editor, loop) = pending else { return }
        pending = nil
        let project = editor.project, video = editor.videoURL, assets = ProjectStore.assetsURL(bundle: editor.bundleURL), format = format
        renderTask = Task { [weak self] in
            let buffer = try? await Self.mix(video: video, project: project, assets: assets, loop: loop, format: format)
            guard let self else { return }
            self.renderTask = nil
            if let buffer, Date() < self.playsUntil, !editor.isPlaying { self.play(buffer, loop: loop) }
            self.renderNext()
        }
    }

    private nonisolated static func mix(video: URL, project: Project, assets: URL, loop: AudioPreviewLoop, format: AVAudioFormat) async throws -> AVAudioPCMBuffer? {
        let media = try await PlaybackComposition.media(asset: AVURLAsset(url: video), project: project, assetsDirectory: assets)
        let tracks = try await media.asset.loadTracks(withMediaType: .audio)
        guard !tracks.isEmpty else { return nil }
        let reader = try AVAssetReader(asset: media.asset)
        let output = AVAssetReaderAudioMixOutput(audioTracks: tracks, audioSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: AudioPreviewLoop.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        output.audioMix = media.audioMix
        reader.add(output)
        let timescale = CMTimeScale(AudioPreviewLoop.sampleRate)
        reader.timeRange = CMTimeRange(
            start: CMTime(value: CMTimeValue(loop.startFrame), timescale: timescale),
            duration: CMTime(value: CMTimeValue(loop.endFrame - loop.startFrame), timescale: timescale)
        )
        guard reader.startReading() else { return nil }
        let capacity = AVAudioFrameCount(max(loop.endFrame - loop.startFrame, 1))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var interleaved: [Float] = []
        while let sample = output.copyNextSampleBuffer() {
            guard let block = CMSampleBufferGetDataBuffer(sample) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            var chunk = [Float](repeating: 0, count: length / MemoryLayout<Float>.size)
            chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
            interleaved += chunk
        }
        let frames = min(Int(capacity), interleaved.count / 2)
        guard frames > 0, let left = buffer.floatChannelData?[0], let right = buffer.floatChannelData?[1] else { return nil }
        for i in 0..<frames {
            left[i] = interleaved[2 * i]
            right[i] = interleaved[2 * i + 1]
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        return buffer
    }

    /// Starts a voice on the stretch, taking over from the current one at its position.
    private func play(_ buffer: AVAudioPCMBuffer, loop: AudioPreviewLoop) {
        let frames = AVAudioFramePosition(buffer.frameLength)
        let previous = voices.last
        // A new stretch starts from its beginning; the same stretch continues where it is.
        let offset = previous.flatMap { $0.loop == loop ? $0.position : nil } ?? 0
        let voice = Voice(loop: loop, frames: frames, offset: offset % max(frames, 1))
        engine.attach(voice.node)
        engine.connect(voice.node, to: engine.mainMixerNode, format: format)
        if !engine.isRunning { try? engine.start() }
        if voice.offset > 0, let tail = Self.slice(buffer, from: voice.offset) {
            voice.node.scheduleBuffer(tail, at: nil)
        }
        voice.node.scheduleBuffer(buffer, at: nil, options: .loops)
        voice.node.volume = 0
        voice.node.play()
        voices.append(voice)
        if let previous {
            ramp(voice, to: 1, frames: AudioPreviewLoop.crossfadeFrames)
            ramp(previous, to: 0, frames: AudioPreviewLoop.crossfadeFrames) { [weak self] in self?.remove(previous) }
        } else {
            ramp(voice, to: 1, frames: AudioPreviewLoop.fadeInFrames)
        }
    }

    private static func slice(_ buffer: AVAudioPCMBuffer, from frame: AVAudioFramePosition) -> AVAudioPCMBuffer? {
        let count = AVAudioFrameCount(AVAudioFramePosition(buffer.frameLength) - frame)
        guard count > 0, let tail = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count),
              let source = buffer.floatChannelData, let target = tail.floatChannelData else { return nil }
        for channel in 0..<Int(buffer.format.channelCount) {
            target[channel].update(from: source[channel] + Int(frame), count: Int(count))
        }
        tail.frameLength = count
        return tail
    }

    /// Linear gain ramp over `frames` output frames.
    private func ramp(_ voice: Voice, to target: Float, frames: Int, completion: (() -> Void)? = nil) {
        let id = ObjectIdentifier(voice)
        ramps[id]?.invalidate()
        let from = voice.node.volume
        let duration = Double(frames) / AudioPreviewLoop.sampleRate
        let start = Date()
        let timer = Timer(timeInterval: 0.002, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                let progress = min(Date().timeIntervalSince(start) / duration, 1)
                voice.node.volume = from + (target - from) * Float(progress)
                guard progress >= 1 else { return }
                timer.invalidate()
                self?.ramps[id] = nil
                completion?()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        ramps[id] = timer
    }

    private func remove(_ voice: Voice) {
        voice.node.stop()
        engine.detach(voice.node)
        voices.removeAll { $0 === voice }
        if voices.isEmpty { engine.stop() }
    }

    /// Fades out once 0.5 s pass without a change, or as soon as playback starts.
    private func armHoldTimer(_ editor: EditorModel) {
        guard holdTimer == nil else { return }
        let timer = Timer(timeInterval: 0.01, repeats: true) { [weak self, weak editor] timer in
            MainActor.assumeIsolated {
                guard let self else { return timer.invalidate() }
                guard Date() >= self.playsUntil || editor?.isPlaying != false else { return }
                timer.invalidate()
                self.holdTimer = nil
                self.fadeOut()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        holdTimer = timer
    }

    private func fadeOut() {
        pending = nil
        for voice in voices {
            ramp(voice, to: 0, frames: AudioPreviewLoop.fadeOutFrames) { [weak self] in self?.remove(voice) }
        }
    }

    func stop() {
        holdTimer?.invalidate()
        holdTimer = nil
        renderTask?.cancel()
        pending = nil
        for timer in ramps.values { timer.invalidate() }
        ramps = [:]
        for voice in voices { remove(voice) }
    }
}

extension EditorModel {
    /// Plays the changed clips' sound while paused (`previewAudioChange`).
    func previewAudioChange(slices ids: [UUID]) {
        let resolver = project.resolver
        let ranges = ids.compactMap { id in
            project.slices.firstIndex { $0.id == id }.map { (startMs: resolver.links[$0].playbackStartMs, endMs: resolver.links[$0].playbackEndMs) }
        }
        audioChangePreview.request(self, changed: ranges)
    }
}
