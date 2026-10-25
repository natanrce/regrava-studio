import Foundation
import Testing
@testable import RegravaCore

struct SensitiveDataTests {
    @Test func phrasesAreTrimmedAndDeduplicated() {
        #expect(ProcessingConfig.parsePhrases(" Jane   Appleseed, acme inc., ,ACME Inc. ,Bob") == ["Jane Appleseed", "acme inc.", "Bob"])
    }

    @Test func textBetweenKeyframesCoversBoth() {
        let d = SensitiveDataDetection(kind: .email, text: "a@b.c", startMs: 0, endMs: 1000, keyframes: [
            .init(timeMs: 0, x: 0, y: 0, width: 10, height: 10),
            .init(timeMs: 500, x: 100, y: 0, width: 10, height: 10),
        ])
        let r = AutoMasks.rect(of: d, at: 250)!
        #expect(r.x == 0 && r.width == 110)
        #expect(AutoMasks.rect(of: d, at: 800)!.x == 100)
    }

    @Test func facesHoldTheirLastKeyframe() {
        let d = SensitiveDataDetection(kind: .face, text: "", startMs: 0, endMs: 1000, keyframes: [
            .init(timeMs: 0, x: 0, y: 0, width: 10, height: 10),
            .init(timeMs: 500, x: 100, y: 0, width: 10, height: 10),
        ])
        #expect(AutoMasks.rect(of: d, at: 499)!.x == 0)
    }

    @Test func framePadsMergesAndFilters() {
        var config = ProcessingConfig()
        config.autoMaskSensitiveData = true
        let video = Size2(width: 1000, height: 500)
        let a = SensitiveDataDetection(kind: .email, text: "", startMs: 0, endMs: 1000, keyframes: [.init(timeMs: 0, x: 100, y: 100, width: 50, height: 20)])
        let b = SensitiveDataDetection(kind: .phone, text: "", startMs: 0, endMs: 1000, keyframes: [.init(timeMs: 0, x: 155, y: 100, width: 50, height: 20)])
        let face = SensitiveDataDetection(kind: .face, text: "", startMs: 0, endMs: 1000, keyframes: [.init(timeMs: 0, x: 0, y: 0, width: 10, height: 10)])
        let frame = AutoMasks.frame(at: 10, detections: [a, b, face], config: config, videoSize: video)
        #expect(frame.bounds01.count == 1) // padded by 8, they overlap
        #expect(abs(frame.bounds01[0].x - 0.092) < 1e-9)
        #expect(frame.faceBounds01.isEmpty) // faces off
        #expect(AutoMasks.frame(at: 1000, detections: [a], config: config, videoSize: video).isEmpty)
    }

    @Test func capMergesTheCheapestPair() {
        let boxes = (0..<40).map { Rect2(x: Double($0) * 30, y: 0, width: 10, height: 10) }
        #expect(AutoMasks.capped(boxes, max: 32).count == 32)
    }
}
