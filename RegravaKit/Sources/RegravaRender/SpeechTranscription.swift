@preconcurrency import AVFoundation
import Foundation
import RegravaCore
import Speech

/// The "Local" transcript method: macOS's own speech recognition (SpeechAnalyzer +
/// SpeechTranscriber).
public enum SpeechTranscription {
    public enum Failure: LocalizedError {
        case unsupportedLocale(String)
        case noMicrophone

        public var errorDescription: String? {
            switch self {
            case .unsupportedLocale(let locale): return "The speech recognizer does not transcribe \(locale)"
            case .noMicrophone: return "There is no microphone audio to transcribe."
            }
        }
    }

    /// `transcription.supportedLocales`: identifiers like `en_US`, sorted.
    public static func supportedLocales() async -> [String] {
        await SpeechTranscriber.supportedLocales.map { identifier($0) }.sorted()
    }

    static func identifier(_ locale: Locale) -> String { locale.identifier.replacingOccurrences(of: "-", with: "_") }

    /// Every word of the recording's microphone track with when it was said, in the file's time.
    /// A missing locale model is downloaded first (`onModelDownloadProgress`, 0…1).
    public static func transcribe(
        recording: URL,
        audioTrackIndex: Int,
        locale localeIdentifier: String,
        onWord: @escaping @Sendable (TranscriptWord) -> Void = { _ in },
        onModelDownloadProgress: @escaping @Sendable (Double) -> Void = { _ in }
    ) async throws -> [TranscriptWord] {
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: localeIdentifier)) else {
            throw Failure.unsupportedLocale(localeIdentifier)
        }
        let audioURL = try await extractTrack(recording: recording, index: audioTrackIndex)
        defer { try? FileManager.default.removeItem(at: audioURL) }

        let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            let observation = request.progress.observe(\.fractionCompleted) { progress, _ in onModelDownloadProgress(progress.fractionCompleted) }
            try await request.downloadAndInstall()
            observation.invalidate()
        }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [TranscriptWord] in
            var words: [TranscriptWord] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters).trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    let word = TranscriptWord(index: words.count, startMs: range.start.seconds * 1000, endMs: range.end.seconds * 1000, text: words.isEmpty ? text : " " + text)
                    words.append(word)
                    onWord(word)
                }
            }
            return words
        }
        let file = try AVAudioFile(forReading: audioURL)
        if let end = try await analyzer.analyzeSequence(from: file) {
            try await analyzer.finalizeAndFinish(through: end)
        } else {
            await analyzer.cancelAndFinishNow()
        }
        return SessionTranscript.normalized(try await collector.value)
    }

    /// The one audio track as an M4A file.
    private static func extractTrack(recording: URL, index: Int) async throws -> URL {
        let asset = AVURLAsset(url: recording)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard index < tracks.count else { throw Failure.noMicrophone }
        let composition = AVMutableComposition()
        guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw Failure.noMicrophone }
        let range = try await tracks[index].load(.timeRange)
        try target.insertTimeRange(range, of: tracks[index], at: range.start)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("regrava-transcript-\(UUID().uuidString).m4a")
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else { throw Failure.noMicrophone }
        try await export.export(to: url, as: .m4a)
        return url
    }
}
