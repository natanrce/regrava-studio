@preconcurrency import AVFoundation
import Foundation
import RegravaCore

/// Turns a recording folder into what a project reads, from the folder alone: each channel's
/// playlist is flattened, the sessions are joined into `recording.mov` (paused time removed),
/// streams that ran through pauses are cut to the same sessions, and the event logs are mapped
/// onto the joined timeline.
public enum RecordingFinalizer {
    public static let videoFileName = "recording.mov"
    public static let cameraFileName = "camera.mov"

    public static func metadata(in folder: URL) throws -> RecordingMetadata {
        let url = folder.appendingPathComponent(RecordingMetadata.fileName)
        guard let data = try? Data(contentsOf: url) else { throw CaptureError.failed("\(folder.lastPathComponent) holds no recording.") }
        guard let metadata = try? JSONDecoder().decode(RecordingMetadata.self, from: data) else {
            throw CaptureError.failed("\(RecordingMetadata.fileName) is not a JSON object.")
        }
        return metadata
    }

    public static func finalize(folder: URL) async throws -> CaptureResult {
        let metadata = try metadata(in: folder)
        let work = folder.appendingPathComponent(".finalize", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        // Sessions with a picture, flattened.
        struct Flat {
            var session: RecordingMetadata.Session
            var picture: AVURLAsset
            var start: Double
            /// Length on the joined timeline.
            var duration: Double
            /// Length of the picture's file, at most `duration`.
            var pictureDuration: Double
            var audio: [(source: AudioSource, asset: AVURLAsset, start: Double)]
        }
        var sessions: [Flat] = []
        for session in metadata.sessions {
            guard let picture = session.channels.first(where: { $0.source == "display" || $0.source == "device" }),
                  let start = picture.startUptime ?? session.startUptime else { continue }
            let pictureURL = work.appendingPathComponent("\(picture.playlist).mp4")
            guard (try? RecordingFolder.flatten(folder.appendingPathComponent("\(picture.playlist).m3u8"), to: pictureURL)) != nil else { continue }
            let asset = AVURLAsset(url: pictureURL)
            guard let fileDuration = try? await asset.load(.duration).seconds, fileDuration > 0 else { continue }
            // A display session lasts until it ended, even when the picture stood still before
            // that and its file stopped at the last changed frame.
            var duration = fileDuration
            if picture.source == "display", let end = session.endUptime, end - start > 0 { duration = end - start }
            var audio: [(AudioSource, AVURLAsset, Double)] = []
            for channel in session.channels {
                guard let source = AudioSource(rawValue: channel.source), let channelStart = channel.startUptime else { continue }
                let url = work.appendingPathComponent("\(channel.playlist).mp4")
                guard (try? RecordingFolder.flatten(folder.appendingPathComponent("\(channel.playlist).m3u8"), to: url)) != nil else { continue }
                audio.append((source, AVURLAsset(url: url), channelStart))
            }
            sessions.append(Flat(session: session, picture: asset, start: start, duration: duration, pictureDuration: min(fileDuration, duration), audio: audio))
        }
        guard !sessions.isEmpty else { throw CaptureError.failed("\(folder.lastPathComponent) holds no recording.") }

        // Joined timeline: each session after the last; audio placed by its own start.
        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw CaptureError.failed("Could not join the recording segments.")
        }
        var audioTracks: [(AudioSource, AVMutableCompositionTrack)] = []
        var offsets: [(start: Double, offset: Double, duration: Double)] = []
        var cursor = 0.0
        func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 600) }
        for flat in sessions {
            if let track = try await flat.picture.loadTracks(withMediaType: .video).first {
                if videoTrack.preferredTransform == .identity { videoTrack.preferredTransform = try await track.load(.preferredTransform) }
                try videoTrack.insertTimeRange(CMTimeRange(start: .zero, duration: time(flat.pictureDuration)), of: track, at: time(cursor))
            }
            for (source, asset, start) in flat.audio {
                guard let track = try await asset.loadTracks(withMediaType: .audio).first else { continue }
                let target: AVMutableCompositionTrack
                if let existing = audioTracks.first(where: { $0.0 == source })?.1 {
                    target = existing
                } else {
                    guard let created = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                    audioTracks.append((source, created))
                    target = created
                }
                let length = try await asset.load(.duration).seconds
                let lead = start - flat.start
                let from = max(0, -lead), at = max(0, lead)
                let span = min(length - from, flat.duration - at)
                guard span > 0 else { continue }
                try target.insertTimeRange(CMTimeRange(start: time(from), duration: time(span)), of: track, at: time(cursor + at))
            }
            offsets.append((flat.start, cursor, flat.duration))
            cursor += flat.duration
        }
        let ranges = { (start: Double) in offsets.map { (sourceStart: $0.start - start, duration: $0.duration, at: $0.offset) } }

        // Streams that ran through pauses, cut to the sessions: the selected apps' sound joins
        // the movie as a track after the sessions' own; the webcam is a movie of its own.
        var cameraStream: (flat: URL, stream: RecordingMetadata.Continuous, start: Double)?
        for stream in metadata.continuous {
            guard let start = stream.startUptime else { continue }
            let flat = work.appendingPathComponent("\(stream.playlist).mp4")
            guard (try? RecordingFolder.flatten(folder.appendingPathComponent("\(stream.playlist).m3u8"), to: flat)) != nil else { continue }
            if stream.source == "webcam" {
                cameraStream = (flat, stream, start)
            } else if let source = AudioSource(rawValue: stream.source) {
                let asset = AVURLAsset(url: flat)
                guard let track = try? await asset.loadTracks(withMediaType: .audio).first,
                      let total = try? await asset.load(.duration).seconds,
                      let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                var inserted = false
                do {
                    for range in ranges(start) {
                        let from = max(range.sourceStart, 0)
                        let end = min(range.sourceStart + range.duration, total)
                        guard end > from else { continue }
                        try target.insertTimeRange(CMTimeRange(start: time(from), end: time(end)), of: track, at: time(range.at + (from - range.sourceStart)))
                        inserted = true
                    }
                } catch {
                    inserted = false
                }
                if inserted {
                    audioTracks.append((source, target))
                } else {
                    composition.removeTrack(target)
                }
            }
        }

        let output = folder.appendingPathComponent(videoFileName)
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.failed("Could not join the recording segments.")
        }
        try await session.export(to: output, as: .mov)
        let audioSources = audioTracks.map(\.0)

        func timelineMs(_ uptime: Double) -> Double? {
            for entry in offsets {
                let local = uptime - entry.start
                if local >= 0 && local <= entry.duration + 0.05 { return (entry.offset + min(local, entry.duration)) * 1000 }
            }
            return nil
        }

        var cameraURL: URL?
        var cameraSize: Size2?
        if let (flat, stream, start) = cameraStream {
            let target = folder.appendingPathComponent(cameraFileName)
            if (try? await cut(flat, ranges: ranges(start), to: target)) != nil {
                cameraURL = target
                if let width = stream.width, let height = stream.height { cameraSize = Size2(width: width, height: height) }
            }
        }

        let origin = CGPoint(x: metadata.originX, y: metadata.originY)
        let scale = metadata.pointPixelScale
        let mouse = StreamingJSONWriter.read(JournalMouse.self, from: folder.appendingPathComponent(JournalFiles.mouse))
        let events = mouse.compactMap { sample -> MouseEvent? in
            guard let t = timelineMs(sample.uptime) else { return nil }
            return MouseEvent(kind: sample.kind, timeMs: t, position: Vec2((sample.x - origin.x) * scale, (sample.y - origin.y) * scale),
                              button: sample.button, cursorID: sample.cursorId, activeModifiers: sample.modifiers)
        }
        let keys = StreamingJSONWriter.read(JournalKey.self, from: folder.appendingPathComponent(JournalFiles.keys)).compactMap { sample in
            timelineMs(sample.uptime).map { Keystroke(kind: sample.kind, timeMs: $0, character: sample.character, activeModifiers: sample.modifiers, isARepeat: sample.isARepeat) }
        }
        var cursors: [CapturedCursorImage] = []
        if let data = try? Data(contentsOf: folder.appendingPathComponent(JournalFiles.cursors)),
           let list = try? JSONDecoder().decode([JournalCursor].self, from: data) {
            for item in list {
                let png = folder.appendingPathComponent(JournalFiles.cursorsDirectory).appendingPathComponent("\(item.id).png")
                if let data = try? Data(contentsOf: png) { cursors.append(CapturedCursorImage(id: item.id, pngData: data, hotSpot: item.hotSpot, size: item.size)) }
            }
        }
        var result = CaptureResult(
            videoURL: output,
            mouseEvents: events.sorted { $0.timeMs < $1.timeMs },
            customCursors: cursors,
            keystrokes: keys.sorted { $0.timeMs < $1.timeMs },
            audioSources: audioSources,
            cameraURL: cameraURL,
            cameraSize: cameraSize,
            markersMs: metadata.markerUptimes.compactMap(timelineMs),
            videoSize: metadata.videoSize,
            pointPixelScale: scale,
            durationMs: cursor * 1000,
            fps: metadata.fps,
            flags: metadata.flags,
            sessionStartsMs: offsets.dropFirst().map { $0.offset * 1000 }
        )
        if var device = metadata.device {
            device.orientationChanges = metadata.orientationChanges.compactMap { change in
                timelineMs(change.uptime).map { DeviceOrientationChange(timeMs: $0, contentRect: change.contentRect, videoRotationAngleForHorizontalLevel: change.angle, animation: change.animation) }
            }
            result.externalDevice = device
        }
        return result
    }

    /// Copies ranges of a movie (seconds) to new positions on a new timeline.
    static func cut(_ url: URL, ranges: [(sourceStart: Double, duration: Double, at: Double)], to outputURL: URL) async throws {
        try? FileManager.default.removeItem(at: outputURL)
        let asset = AVURLAsset(url: url)
        let total = try await asset.load(.duration).seconds
        let composition = AVMutableComposition()
        for range in ranges {
            let start = max(range.sourceStart, 0)
            let end = min(range.sourceStart + range.duration, total)
            guard end > start else { continue }
            try await composition.insertTimeRange(
                CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), end: CMTime(seconds: end, preferredTimescale: 600)),
                of: asset,
                at: CMTime(seconds: range.at + (start - range.sourceStart), preferredTimescale: 600)
            )
        }
        guard let session = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetPassthrough) else {
            throw CaptureError.failed("Could not save the camera recording.")
        }
        try await session.export(to: outputURL, as: .mov)
    }
}
