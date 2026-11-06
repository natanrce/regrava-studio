@preconcurrency import AVFoundation
import CoreAudio
import Foundation
import RegravaCore

/// Host time in milliseconds (`mach_absolute_time`).
public enum HostClock {
    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    public static func milliseconds(_ hostTime: UInt64) -> Double {
        Double(hostTime) * Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }

    public static var nowMs: Double { milliseconds(mach_absolute_time()) }
}

/// What the output delays audio by: the device's and its stream's latency, else the output
/// node's presentation latency.
enum OutputLatency {
    static func seconds(of engine: AVAudioEngine) -> Double {
        guard let unit = engine.outputNode.audioUnit else { return engine.outputNode.presentationLatency }
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &device, &size) == noErr else {
            return engine.outputNode.presentationLatency
        }
        var rate = Float64(0)
        var rateSize = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &rateSize, &rate) == noErr, rate > 0 else {
            return engine.outputNode.presentationLatency
        }
        var deviceLatency = UInt32(0)
        var latencySize = UInt32(MemoryLayout<UInt32>.size)
        address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyLatency, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        AudioObjectGetPropertyData(device, &address, 0, nil, &latencySize, &deviceLatency)
        var streamLatency = UInt32(0)
        if let stream = firstOutputStream(of: device) {
            address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyLatency, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            latencySize = UInt32(MemoryLayout<UInt32>.size)
            AudioObjectGetPropertyData(stream, &address, 0, nil, &latencySize, &streamLatency)
        }
        return Double(deviceLatency + streamLatency) / rate
    }

    private static func firstOutputStream(of device: AudioDeviceID) -> AudioStreamID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(0)
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size != 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr else { return nil }
        return streams.first
    }
}

/// Plays a project's mix on its own thread: following the transport while playing (at any
/// rate, backwards too), chasing the playhead while scrubbing, and looping audio change
/// previews while paused. It reports which timeline time is being heard.
public final class LiveAudioPlayer: @unchecked Sendable {
    /// `timeMs` is heard at `hostTimeMs` (host clock, ms).
    public struct Clock: Equatable, Sendable {
        public var timeMs: Double
        public var hostTimeMs: Double
        public var rate: Double
        public var generation: Int
    }

    public struct Transport: Equatable, Sendable {
        public var isPlaying: Bool
        public var timeMs: Double
        public var rate: Double
        public var generation: Int

        public init(isPlaying: Bool, timeMs: Double, rate: Double, generation: Int) {
            self.isPlaying = isPlaying
            self.timeMs = timeMs
            self.rate = rate
            self.generation = generation
        }
    }

    enum Command {
        case layout(MixLayout)
        case transport(Transport)
        case scrub(timeMs: Double, hostMs: Double)
        case preview(timeMs: Double, changed: (startMs: Double, endMs: Double), hostMs: Double)
    }

    /// Frames queued ahead while playing, and per mix call.
    static let playingAheadFrames = 9600
    static let chunkFrames = 512
    /// The longest a playing fill runs before the thread looks at new commands.
    static let fillBudgetSeconds = 0.02
    static let scrubAheadSeconds = 0.03
    static let previewAheadSeconds = 0.05
    static let pausedChunkFrames = 256
    static let clockReportIntervalSeconds = 0.05
    /// The output stops after this long without sound.
    static let idleStopSeconds = 30.0
    /// A new mix while playing keeps 40 ms of what is queued and crossfades over 256 frames.
    static let swapKeepFrames = 1920
    static let swapCrossfadeFrames = 256

    public let catalog = MixSourceCatalogHandle()
    private let onClock: @Sendable (Clock) -> Void
    private let onFailure: @Sendable (String) -> Void

    private let engine = AVAudioEngine()
    private let ring = AudioRing(capacity: 48_000)
    private let lock = NSLock()
    private var commands: [Command] = []
    private var stopped = false
    private var configurationChanged = false
    private let wake = DispatchSemaphore(value: 0)
    private var configurationObserver: NSObjectProtocol?

    // Mixing thread state.
    private var renderer: MixRenderer?
    private var stretcher: TimeStretcher?
    private var head: MixHead?
    private var blockCache: MixBlockCache?
    private var transport = Transport(isPlaying: false, timeMs: 0, rate: 1, generation: 0)
    private var transportReceivedAt = Date()
    private var scrub: ScrubPlayer?
    private var preview: PreviewPlayer?
    private var outputLatencySeconds = 0.0
    private var lastSoundAt = Date.distantPast
    private var lastClockReportAt = Date.distantPast
    private var reportedFailure: String?
    private var chunkLeft = [Float](repeating: 0, count: LiveAudioPlayer.chunkFrames)
    private var chunkRight = [Float](repeating: 0, count: LiveAudioPlayer.chunkFrames)

    public init(onClock: @escaping @Sendable (Clock) -> Void, onFailure: @escaping @Sendable (String) -> Void) {
        self.onClock = onClock
        self.onFailure = onFailure
        let ring = self.ring
        let source = AVAudioSourceNode(format: MixPlaybackFormat.avFormat) { _, timestamp, frameCount, data in
            let hostTime = timestamp.pointee.mFlags.contains(.hostTimeValid) ? timestamp.pointee.mHostTime : mach_absolute_time()
            let buffers = UnsafeMutableAudioBufferListPointer(data)
            guard let left = buffers[0].mData?.assumingMemoryBound(to: Float.self),
                  let right = buffers[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            ring.read(left: left, right: right, count: Int(frameCount), hostTime: hostTime)
            return noErr
        }
        engine.attach(source)
        engine.connect(source, to: engine.mainMixerNode, format: MixPlaybackFormat.avFormat)
        configurationObserver = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil) { [weak self] _ in
            guard let self else { return }
            self.lock.lock()
            self.configurationChanged = true
            self.lock.unlock()
            self.wake.signal()
        }
        let thread = Thread { [weak self] in self?.produce() }
        thread.name = "AudioPlayback.producer"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Stops the thread and the output.
    public func close() {
        lock.lock()
        stopped = true
        lock.unlock()
        wake.signal()
        if let configurationObserver { NotificationCenter.default.removeObserver(configurationObserver) }
        configurationObserver = nil
    }

    deinit { close() }

    // MARK: Commands

    /// The mix to play.
    public func setSegments(_ layout: MixLayout) { send(.layout(layout)) }

    public func setTransport(_ transport: Transport) {
        var t = transport
        t.isPlaying = transport.isPlaying && transport.rate != 0
        send(.transport(t))
    }

    /// 0…1.
    public func setVolume(_ volume01: Double) {
        engine.mainMixerNode.outputVolume = Float(volume01 < 0 ? 0 : min(volume01, 1))
    }

    /// The paused playhead moved to `timeMs` at `hostMs` (now when nil).
    public func scrub(timeMs: Double, hostMs: Double? = nil) {
        send(.scrub(timeMs: timeMs, hostMs: hostMs ?? HostClock.nowMs))
    }

    /// Volumes changed in `changed` (playback ms) with the playhead at `timeMs`.
    public func preview(timeMs: Double, changed: (startMs: Double, endMs: Double)) {
        send(.preview(timeMs: timeMs, changed: changed, hostMs: HostClock.nowMs))
    }

    private func send(_ command: Command) {
        lock.lock()
        commands.append(command)
        lock.unlock()
        wake.signal()
    }

    // MARK: Mixing thread

    private func produce() {
        while true {
            _ = wake.wait(timeout: .now() + .milliseconds(5))
            lock.lock()
            let pending = commands
            let isStopped = stopped
            let changed = configurationChanged
            commands = []
            configurationChanged = false
            lock.unlock()
            if isStopped { break }
            if changed && (engine.isRunning || transport.isPlaying) { startEngine(restarting: true) }
            for command in pending { apply(command) }
            fill()
            reportClock()
            if let failure = renderer?.failure, failure != reportedFailure {
                reportedFailure = failure
                onFailure(failure)
            }
            if engine.isRunning && !transport.isPlaying && Date().timeIntervalSince(lastSoundAt) > Self.idleStopSeconds {
                engine.stop()
            }
        }
        engine.stop()
    }

    private func startEngine(restarting: Bool) {
        if restarting {
            engine.stop()
        } else if engine.isRunning {
            return
        }
        engine.prepare()
        do {
            try engine.start()
            outputLatencySeconds = OutputLatency.seconds(of: engine)
        } catch {
            let message = "The audio output would not start: " + error.localizedDescription
            reportedFailure = message
            onFailure(message)
        }
    }

    private static func frame(ms: Double) -> Int64 { MixFormat.frames(seconds: max(ms, 0) / 1000) }

    private func apply(_ command: Command) {
        switch command {
        case .layout(let layout):
            swapLayout(layout)
        case .transport(let next):
            guard transport.generation <= next.generation else { return }
            transport = next
            transportReceivedAt = Date()
            scrub = nil
            preview = nil
            let frame = Self.frame(ms: next.timeMs)
            if next.isPlaying {
                startEngine(restarting: false)
                restart(atTimelineFrame: frame)
            } else {
                ring.flush(toTimelineFrame: Double(frame), rate: 1, generation: next.generation)
                stretcher = nil
                head = nil
            }
        case .scrub(let timeMs, let hostMs):
            guard !transport.isPlaying, let renderer else { return }
            let cache: MixBlockCache
            if let blockCache { cache = blockCache } else {
                cache = MixBlockCache(renderer: renderer)
                blockCache = cache
            }
            startEngine(restarting: false)
            if scrub == nil {
                stretcher = nil
                if preview != nil {
                    preview = nil
                    ring.flush(toTimelineFrame: Double(Self.frame(ms: transport.timeMs)), rate: 1, generation: transport.generation)
                }
                scrub = ScrubPlayer(cache: cache)
            }
            scrub?.add(timeMs: timeMs, hostMs: hostMs)
        case .preview(let timeMs, let changed, let hostMs):
            guard !transport.isPlaying, let renderer else { return }
            startEngine(restarting: false)
            if preview == nil {
                stretcher = nil
                if scrub != nil {
                    scrub = nil
                    ring.flush(toTimelineFrame: Double(Self.frame(ms: transport.timeMs)), rate: 1, generation: transport.generation)
                }
                preview = PreviewPlayer(layout: renderer.layout, catalog: catalog.catalog)
            }
            preview?.request(timeMs: timeMs, changed: changed, hostMs: hostMs)
        }
    }

    private func currentBlockCache() -> MixBlockCache? {
        guard let renderer else { return nil }
        if blockCache == nil { blockCache = MixBlockCache(renderer: renderer) }
        return blockCache
    }

    /// Plays from `frame` at the transport's rate.
    private func restart(atTimelineFrame frame: Int64) {
        ring.flush(toTimelineFrame: Double(frame), rate: transport.rate, generation: transport.generation)
        stretcher = nil
        head = nil
        guard let renderer else { return }
        let rate = transport.rate
        if rate >= 0 || currentBlockCache() == nil {
            renderer.seek(to: frame)
            if rate != 1, let stretcher = try? TimeStretcher(speed: rate, algorithm: .current, pull: { renderer.render(left: $0, right: $1, count: $2) }) {
                stretcher.skip(stretcher.latencyFrames)
                self.stretcher = stretcher
            }
        } else if let cache = currentBlockCache(), let reverse = try? MixHead(at: Double(frame), direction: -1, speed: -rate, cache: cache), let stretcher = reverse.stretcher {
            let priming = stretcher.latencyFrames + MixHead.primingExtraFrames
            reverse.position = Double(frame) + Double(priming)
            stretcher.skip(priming)
            stretcher.setSpeed(-rate)
            head = reverse
        }
    }

    /// A new mix: while playing it takes over without a gap.
    private func swapLayout(_ layout: MixLayout) {
        let next = MixRenderer(layout: layout, catalog: catalog.catalog)
        let previous = renderer
        renderer = next
        blockCache = nil
        scrub = nil
        preview?.setLayout(layout)
        guard transport.isPlaying else { return }
        guard previous != nil else {
            let elapsedMs = Date().timeIntervalSince(transportReceivedAt) * 1000
            restart(atTimelineFrame: Self.frame(ms: transport.timeMs + elapsedMs * transport.rate))
            return
        }
        guard transport.rate == 1 else {
            let kept = ring.truncate(keeping: Self.swapKeepFrames, savingTail: 0)
            restart(atTimelineFrame: Int64(kept.timelineFrame.rounded()))
            return
        }
        let kept = ring.truncate(keeping: Self.swapKeepFrames, savingTail: Self.swapCrossfadeFrames)
        next.seek(to: Int64(kept.timelineFrame.rounded()))
        let n = kept.tailLeft.count
        guard n > 0 else { return }
        var left = [Float](repeating: 0, count: n), right = [Float](repeating: 0, count: n)
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in
                next.render(left: l.baseAddress!, right: r.baseAddress!, count: n)
            }
        }
        let count = Float(n)
        for i in 0..<n {
            let t = (Float(i) + 0.5) / count
            left[i] = left[i] * t + kept.tailLeft[i] * (1 - t)
            right[i] = kept.tailRight[i] * (1 - t) + t * right[i]
        }
        left.withUnsafeBufferPointer { l in
            right.withUnsafeBufferPointer { r in
                _ = ring.write(left: l.baseAddress!, right: r.baseAddress!, count: n)
            }
        }
    }

    private func fill() {
        guard let renderer else { return }
        guard transport.isPlaying else {
            if let preview {
                fillPaused(aheadSeconds: Self.previewAheadSeconds, isActive: { hostMs in
                    preview.master > 0 || (preview.hasVoices && hostMs < preview.untilHostMs)
                }, render: { left, right, count, hostMs in
                    guard let loop = preview.loop, let position = preview.newestPosition else {
                        left.update(repeating: 0, count: count)
                        right.update(repeating: 0, count: count)
                        return
                    }
                    let toEnd = Int64(loop.endFrame) - position
                    if toEnd >= 1 && toEnd < Int64(count) {
                        let first = Int(toEnd)
                        preview.renderVoices(left: left, right: right, count: first, hostMs: hostMs)
                        preview.renderVoices(left: left + first, right: right + first, count: count - first, hostMs: hostMs + Double(first) / MixFormat.sampleRate * 1000)
                    } else {
                        preview.renderVoices(left: left, right: right, count: count, hostMs: hostMs)
                    }
                })
            } else if let scrub {
                fillPaused(aheadSeconds: Self.scrubAheadSeconds, isActive: { scrub.isActive(atHostMs: $0) }, render: { left, right, count, hostMs in
                    scrub.render(left: left, right: right, count: count, hostMs: hostMs)
                })
                if let head = scrub.head { scrub.cache.prefetch(for: head) }
            }
            return
        }
        lastSoundAt = Date()
        let deadline = Date().addingTimeInterval(Self.fillBudgetSeconds)
        chunkLeft.withUnsafeMutableBufferPointer { cl in
            chunkRight.withUnsafeMutableBufferPointer { cr in
                let left = cl.baseAddress!, right = cr.baseAddress!
                let count = cl.count
                while ring.buffered < Self.playingAheadFrames, ring.free >= count, Date() < deadline {
                    if let head, let stretcher = head.stretcher {
                        stretcher.setSpeed(head.speed)
                        stretcher.render(left: left, right: right, count: count)
                    } else if let stretcher {
                        stretcher.render(left: left, right: right, count: count)
                    } else {
                        renderer.render(left: left, right: right, count: count)
                    }
                    ring.write(left: left, right: right, count: count)
                }
            }
        }
        if let head, let blockCache { blockCache.prefetch(for: head) }
    }

    /// Keeps `aheadSeconds` queued in 256-frame blocks while `isActive` says there is sound.
    private func fillPaused(aheadSeconds: Double, isActive: (Double) -> Bool, render: (UnsafeMutablePointer<Float>, UnsafeMutablePointer<Float>, Int, Double) -> Void) {
        let ahead = Int(MixFormat.frames(seconds: aheadSeconds))
        chunkLeft.withUnsafeMutableBufferPointer { cl in
            chunkRight.withUnsafeMutableBufferPointer { cr in
                let left = cl.baseAddress!, right = cr.baseAddress!
                while true {
                    let buffered = ring.buffered
                    guard buffered < ahead else { return }
                    let hostMs = HostClock.nowMs + Double(buffered) / MixFormat.sampleRate * 1000
                    guard isActive(hostMs) else { return }
                    lastSoundAt = Date()
                    render(left, right, Self.pausedChunkFrames, hostMs)
                    ring.write(left: left, right: right, count: Self.pausedChunkFrames)
                }
            }
        }
    }

    private func reportClock() {
        guard transport.isPlaying, Date().timeIntervalSince(lastClockReportAt) >= Self.clockReportIntervalSeconds else { return }
        guard let clock = ring.takeClock(), clock.generation == transport.generation else { return }
        lastClockReportAt = Date()
        onClock(Clock(
            timeMs: clock.timelineFrame / MixFormat.sampleRate * 1000,
            hostTimeMs: outputLatencySeconds * 1000 + HostClock.milliseconds(clock.hostTime),
            rate: clock.rate,
            generation: clock.generation
        ))
    }
}

/// The source catalog shared by a player's mixes; layouts are built from its sources.
public final class MixSourceCatalogHandle: @unchecked Sendable {
    let catalog = MixSourceCatalog()

    /// Opens every source of `segments` and lays them out; forgets sources no longer used.
    public func layout(segments: [AudioMixSegment]) throws -> MixLayout {
        var durations: [AudioMixSource: Double] = [:]
        for source in Set(segments.map(\.source)) {
            durations[source] = try catalog.source(at: source).durationSeconds
        }
        let layout = try MixLayout(segments: segments, durationsSeconds: durations)
        catalog.retainOnly(Set(segments.map(\.source)))
        return layout
    }
}
