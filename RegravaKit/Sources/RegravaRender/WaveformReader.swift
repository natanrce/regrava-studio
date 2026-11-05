import AVFoundation
import Foundation
import RegravaCore

/// Reads an audio track into timeline waveform levels: mono, 800 a second, each the peak of its
/// 1.25 ms window, normalized by `AudioWaveform.normalized`.
public enum WaveformReader {
    public static func levels(url: URL, trackIndex: Int = 0) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard trackIndex < tracks.count else { return [] }
        let sampleRate = 48_000
        let window = sampleRate / AudioWaveform.samplesPerSecond
        let track = tracks[trackIndex]
        return try await BlockingWork.run("waveform") { cancellation in
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsNonInterleaved: false,
                AVLinearPCMIsBigEndianKey: false,
                AVSampleRateKey: sampleRate,
                AVNumberOfChannelsKey: 1,
            ])
            output.alwaysCopiesSampleData = false
            reader.add(output)
            guard reader.startReading() else { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            var peaks: [Float] = []
            var current: Float = 0
            var filled = 0
            // Reused across sample buffers.
            var samples: [Float] = []
            while let buffer = output.copyNextSampleBuffer() {
                try cancellation.check()
                guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
                let count = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
                if samples.count < count { samples = [Float](repeating: 0, count: count) }
                guard samples.withUnsafeMutableBytes({ CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * 4, destination: $0.baseAddress!) }) == noErr else { continue }
                for sample in samples[..<count] {
                    current = max(current, abs(sample))
                    filled += 1
                    if filled == window {
                        peaks.append(current)
                        current = 0
                        filled = 0
                    }
                }
            }
            if filled > 0 { peaks.append(current) }
            if reader.status == .failed { throw reader.error ?? CocoaError(.fileReadCorruptFile) }
            return AudioWaveform.normalized(peaks: peaks)
        }
    }
}
