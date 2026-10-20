import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

/// Runs Apple's recognizer on `say` output; opt-in (REGRAVA_SPEECH=1) since it may download a model.
struct SpeechTranscriptionTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_SPEECH"] == "1"))
    func transcribesSpokenWordsWithTimes() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let audio = dir.appendingPathComponent("speech.aiff")
        let say = Process()
        say.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        say.arguments = ["-v", "Samantha", "-o", audio.path, "Welcome to the screen recording. Today we edit a video."]
        try say.run()
        say.waitUntilExit()
        let locales = await SpeechTranscription.supportedLocales()
        #expect(locales.contains("en_US"))
        let words = try await SpeechTranscription.transcribe(recording: audio, audioTrackIndex: 0, locale: "en_US") { p in print("model download", p) }
        print("WORDS", words.map { "\($0.text)@\(Int($0.startMs))-\(Int($0.endMs))" }.joined(separator: " "))
        #expect(words.count >= 8)
        #expect(words.first?.text.hasPrefix(" ") == false && words.dropFirst().allSatisfy { $0.text.hasPrefix(" ") })
        #expect(zip(words, words.dropFirst()).allSatisfy { $0.startMs <= $1.startMs })
        #expect(words.map(\.text).joined().lowercased().contains("video"))
    }
}
