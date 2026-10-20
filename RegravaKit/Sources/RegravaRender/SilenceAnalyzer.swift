@preconcurrency import AVFoundation
import Foundation
import RegravaCore

/// Reads the microphone track and finds its quiet stretches (`detectSilence` on the
/// microphone, `project.silenceChunks`).
public enum SilenceAnalyzer {
    /// RMS of each `windowMs` window of the track's first channel, 0…1 of full scale.
    static func windowRMS(recording: URL, audioTrackIndex: Int, windowMs: Double) async throws -> (rms: [Double], durationMs: Double) {
        let asset = AVURLAsset(url: recording)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard audioTrackIndex < tracks.count else { return ([], 0) }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: tracks[audioTrackIndex], outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadUnknown) }
        var rms: [Double] = []
        var sum = 0.0, count = 0, windowSamples = 0, frames = 0
        var sampleRate = 0.0
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let format = CMSampleBufferGetFormatDescription(buffer),
                  let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee,
                  let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            if sampleRate == 0 {
                sampleRate = asbd.mSampleRate
                windowSamples = max(Int((sampleRate * windowMs / 1000).rounded()), 1)
            }
            let channels = max(Int(asbd.mChannelsPerFrame), 1)
            var length = 0
            var pointer: UnsafeMutablePointer<Int8>?
            CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &pointer)
            guard let pointer else { continue }
            let samples = pointer.withMemoryRebound(to: Float.self, capacity: length / 4) { UnsafeBufferPointer(start: $0, count: length / 4) }
            var i = 0
            while i < samples.count {
                let v = Double(samples[i])
                sum += v * v
                count += 1
                frames += 1
                if count == windowSamples {
                    rms.append((sum / Double(count)).squareRoot())
                    sum = 0
                    count = 0
                }
                i += channels
            }
        }
        if count > 0 { rms.append((sum / Double(count)).squareRoot()) }
        return (rms, sampleRate > 0 ? Double(frames) / sampleRate * 1000 : 0)
    }

    /// The microphone's silences for "Hide during silence" (threshold 0.1, 50 ms windows).
    public static func analyze(recording: URL, audioTrackIndex: Int, hideDuringSilenceMs: Double) async throws -> CameraSilence {
        let minimum = SilenceDetection.minimumDurationMs(hideDuringSilenceMs)
        let (rms, duration) = try await windowRMS(recording: recording, audioTrackIndex: audioTrackIndex, windowMs: SilenceDetection.windowSizeMs)
        return CameraSilence(minSilenceDurationMs: minimum, chunks: SilenceDetection.chunks(windowRMS: rms, durationMs: duration, minSilenceDurationMs: minimum))
    }

    /// Stored silences matching the current setting, if any.
    public static func stored(project: Project, bundle: URL) -> [SilenceChunk]? {
        guard let ms = project.camera.hideDuringSilenceMs, let silence = CameraSilence.load(bundle: bundle),
              silence.minSilenceDurationMs == SilenceDetection.minimumDurationMs(ms) else { return nil }
        return silence.chunks
    }

    /// Runs the analysis when the setting is on and no matching result is stored.
    public static func ensure(project: Project, bundle: URL, recording: URL) async throws {
        guard let ms = project.camera.hideDuringSilenceMs, stored(project: project, bundle: bundle) == nil,
              let track = project.recording.audioSources.firstIndex(of: .microphone) else { return }
        try await analyze(recording: recording, audioTrackIndex: track, hideDuringSilenceMs: ms).save(bundle: bundle)
    }
}
