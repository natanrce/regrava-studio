import Foundation

/// A clip of the recording (`SliceModel`): a source range played at a speed, with per-clip
/// audio volumes and cursor options. Slices are ordered and never overlap; gaps between them
/// are cut out of the video.
public struct Slice: Codable, Hashable, Sendable, Identifiable {
    public static let minimumDurationMs = 100.0
    /// Speeds offered for a slice.
    public static let speedOptions: [Double] = [1, 1.2, 1.4, 1.6, 1.8, 2, 3, 4, 8, 16, 24, 0.5, 0.75]

    public var id: UUID
    public var sourceStartMs: Double
    public var sourceEndMs: Double
    /// Playback duration / source duration (1 / speed).
    public var timeScale: Double
    public var volume: Double
    public var systemAudioVolume: Double
    public var externalDeviceAudioVolume: Double
    public var hideCursor: Bool
    public var disableSmoothMouseMovement: Bool

    public init(
        id: UUID = UUID(),
        sourceStartMs: Double,
        sourceEndMs: Double,
        timeScale: Double = 1,
        volume: Double = 1,
        systemAudioVolume: Double = 1,
        externalDeviceAudioVolume: Double = 1,
        hideCursor: Bool = false,
        disableSmoothMouseMovement: Bool = false
    ) {
        self.id = id
        self.sourceStartMs = sourceStartMs
        self.sourceEndMs = sourceEndMs
        self.timeScale = timeScale
        self.volume = volume
        self.systemAudioVolume = systemAudioVolume
        self.externalDeviceAudioVolume = externalDeviceAudioVolume
        self.hideCursor = hideCursor
        self.disableSmoothMouseMovement = disableSmoothMouseMovement
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.value(.id, default: UUID())
        sourceStartMs = try c.decode(Double.self, forKey: .sourceStartMs)
        sourceEndMs = try c.decode(Double.self, forKey: .sourceEndMs)
        timeScale = c.value(.timeScale, default: 1)
        volume = c.value(.volume, default: 1)
        systemAudioVolume = c.value(.systemAudioVolume, default: 1)
        externalDeviceAudioVolume = c.value(.externalDeviceAudioVolume, default: 1)
        hideCursor = c.value(.hideCursor, default: false)
        disableSmoothMouseMovement = c.value(.disableSmoothMouseMovement, default: false)
    }

    public var speed: Double { timeScale == 0 ? .infinity : 1 / timeScale }
    public var sourceDurationMs: Double { sourceEndMs - sourceStartMs }
    public var playbackDurationMs: Double { sourceDurationMs * timeScale }

    public func contains(sourceTime t: Double) -> Bool { t >= sourceStartMs && t <= sourceEndMs }
}

/// Maps between source (recording) time and playback (edited video) time.
public struct TimeResolver: Sendable, Hashable {
    public struct Link: Sendable, Hashable {
        public var sourceStartMs: Double
        public var sourceEndMs: Double
        public var playbackStartMs: Double
        public var playbackEndMs: Double
        public var timeScale: Double

        /// Linear map, clamped to the link.
        public func playbackToSource(_ t: Double) -> Double {
            Self.map(t, playbackStartMs, playbackEndMs, sourceStartMs, sourceEndMs)
        }

        public func sourceToPlayback(_ t: Double) -> Double {
            Self.map(t, sourceStartMs, sourceEndMs, playbackStartMs, playbackEndMs)
        }

        static func map(_ value: Double, _ a0: Double, _ a1: Double, _ b0: Double, _ b1: Double) -> Double {
            let v = clamp(value, a0, a1)
            guard a1 != a0 else { return b0 }
            return b0 + (v - a0) / (a1 - a0) * (b1 - b0)
        }
    }

    public let links: [Link]

    public init(slices: [Slice]) {
        var links: [Link] = []
        var playback = 0.0
        for slice in slices {
            let duration = slice.playbackDurationMs
            links.append(Link(
                sourceStartMs: slice.sourceStartMs,
                sourceEndMs: slice.sourceEndMs,
                playbackStartMs: playback,
                playbackEndMs: playback + duration,
                timeScale: slice.timeScale
            ))
            playback += duration
        }
        self.links = links
    }

    /// Link playing at `t`: the first ending at or after it, else the last (`getLinkAtPlaybackTimeIndex`).
    public func linkIndex(atPlayback t: Double) -> Int? {
        guard !links.isEmpty else { return nil }
        return ceilSearch(count: links.count, value: t, key: { links[$0].playbackEndMs }) ?? links.count - 1
    }

    /// Link containing source time `t`: the last starting at or before it, else the first.
    public func linkIndex(atSource t: Double) -> Int? {
        guard !links.isEmpty else { return nil }
        return floorSearch(count: links.count, value: t, key: { links[$0].sourceStartMs }) ?? 0
    }

    public func playbackToSource(_ t: Double) -> Double {
        linkIndex(atPlayback: t).map { links[$0].playbackToSource(t) } ?? 0
    }

    public func sourceToPlayback(_ t: Double) -> Double {
        linkIndex(atSource: t).map { links[$0].sourceToPlayback(t) } ?? 0
    }

    public func isSourceTimePresent(_ t: Double) -> Bool {
        guard let i = linkIndex(atSource: t) else { return false }
        return t >= links[i].sourceStartMs && t <= links[i].sourceEndMs
    }

    public func speed(atPlayback t: Double) -> Double {
        let scale = linkIndex(atPlayback: t).map { links[$0].timeScale } ?? 1
        return 1 / scale
    }

    public var playbackDurationMs: Double { links.last?.playbackEndMs ?? 0 }
    public var sourceStartMs: Double { links.first?.sourceStartMs ?? 0 }
    public var sourceEndMs: Double { links.last?.sourceEndMs ?? 0 }
}

// MARK: - Slice editing (collection splitAt/canSplitAt)

public extension Project {
    var resolver: TimeResolver { TimeResolver(slices: slices) }
    var playbackDurationMs: Double { resolver.playbackDurationMs }

    /// The default single clip spanning the whole recording.
    static func defaultSlices(durationMs: Double) -> [Slice] {
        [Slice(sourceStartMs: 0, sourceEndMs: durationMs)]
    }

    func sliceIndex(at sourceTime: Double) -> Int? {
        slices.firstIndex { $0.contains(sourceTime: sourceTime) }
    }

    func canSplitSlice(at sourceTime: Double) -> Bool {
        guard let i = sliceIndex(at: sourceTime) else { return false }
        let slice = slices[i]
        return sourceTime - slice.sourceStartMs >= Slice.minimumDurationMs
            && slice.sourceEndMs - sourceTime >= Slice.minimumDurationMs
    }

    /// Splits the slice at `sourceTime`; the new right half copies the slice's settings.
    @discardableResult
    mutating func splitSlice(at sourceTime: Double) -> Bool {
        guard canSplitSlice(at: sourceTime), let i = sliceIndex(at: sourceTime) else { return false }
        var right = slices[i]
        right.id = UUID()
        right.sourceStartMs = sourceTime
        slices[i].sourceEndMs = sourceTime
        slices.insert(right, at: i + 1)
        return true
    }

    /// Trims a slice (`prepareUpdateInfo` / `canUpdate`): clamped to its neighbours and the
    /// recording, refused when it would become shorter than 100 ms (unless it already was).
    @discardableResult
    mutating func updateSlice(_ id: UUID, sourceStartMs: Double? = nil, sourceEndMs: Double? = nil) -> Bool {
        guard let i = slices.firstIndex(where: { $0.id == id }) else { return false }
        var start = max(sourceStartMs ?? slices[i].sourceStartMs, 0)
        if i > 0 { start = max(start, slices[i - 1].sourceEndMs) }
        var end = min(sourceEndMs ?? slices[i].sourceEndMs, recording.durationMs)
        if i + 1 < slices.count { end = min(end, slices[i + 1].sourceStartMs) }
        let newDuration = end - start
        if newDuration < Slice.minimumDurationMs && newDuration < slices[i].sourceDurationMs { return false }
        slices[i].sourceStartMs = start
        slices[i].sourceEndMs = end
        return true
    }

    /// Removes a slice (never the last one). With `closeGap`, the previous slice is extended up
    /// to the next one (`remove(true)`).
    @discardableResult
    mutating func removeSlice(_ id: UUID, closeGap: Bool = false) -> Bool {
        guard slices.count > 1, let i = slices.firstIndex(where: { $0.id == id }) else { return false }
        let previous = i > 0 ? slices[i - 1].id : nil
        let nextStart = i + 1 < slices.count ? slices[i + 1].sourceStartMs : nil
        slices.remove(at: i)
        if closeGap, let previous, let nextStart {
            updateSlice(previous, sourceEndMs: nextStart - 1)
        }
        return true
    }

    enum SliceNeighbour { case previous, next }

    /// Joins a slice with a neighbour, keeping this slice's settings (`mergeWith`).
    mutating func mergeSlice(_ id: UUID, with neighbour: SliceNeighbour) {
        guard let i = slices.firstIndex(where: { $0.id == id }) else { return }
        switch neighbour {
        case .next:
            guard i + 1 < slices.count else { return }
            let end = slices[i + 1].sourceEndMs
            slices.remove(at: i + 1)
            updateSlice(id, sourceEndMs: end)
        case .previous:
            guard i > 0 else { return }
            let start = slices[i - 1].sourceStartMs
            slices.remove(at: i - 1)
            updateSlice(id, sourceStartMs: start)
        }
    }

    func sliceHasStartTrim(_ index: Int) -> Bool {
        let slice = slices[index]
        return index > 0 ? slice.sourceStartMs > slices[index - 1].sourceEndMs : slice.sourceStartMs > 0
    }

    func sliceHasEndTrim(_ index: Int) -> Bool {
        let slice = slices[index]
        return index + 1 < slices.count ? slice.sourceEndMs < slices[index + 1].sourceStartMs : slice.sourceEndMs < recording.durationMs
    }

    enum SliceEdge { case start, end }

    /// Restores trimmed time on one or both edges (`removeTrim`).
    mutating func removeSliceTrim(_ id: UUID, edge: SliceEdge? = nil) {
        guard let i = slices.firstIndex(where: { $0.id == id }) else { return }
        if edge == nil || edge == .start {
            updateSlice(id, sourceStartMs: i > 0 ? slices[i - 1].sourceEndMs : 0)
        }
        if edge == nil || edge == .end {
            updateSlice(id, sourceEndMs: i + 1 < slices.count ? slices[i + 1].sourceStartMs : recording.durationMs)
        }
    }

    /// "Reset trims and cuts for all slices".
    mutating func resetSlices() {
        slices = Self.defaultSlices(durationMs: recording.durationMs)
    }

    /// The slice playing at a source time, if that time is not cut out.
    func slice(atSource t: Double) -> Slice? {
        slices.first { $0.contains(sourceTime: t) }
    }
}
