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

    /// The linear scan `AutoMasks.frame` replaced: every detection up to the first that starts
    /// later, keyframes searched front to back.
    private func linearFrame(at t: Double, detections: [SensitiveDataDetection], config: ProcessingConfig, videoSize: Size2) -> AutoMaskFrame {
        func rect(_ d: SensitiveDataDetection) -> Rect2? {
            let keys = d.keyframes
            guard let first = keys.first else { return nil }
            if d.kind == .face { return (keys.last { $0.timeMs <= t } ?? first).rect }
            guard let i = keys.firstIndex(where: { $0.timeMs >= t }) else { return keys.last?.rect }
            if i == 0 || keys[i].timeMs == t { return keys[i].rect }
            return AutoMasks.union(keys[i - 1].rect, keys[i].rect)
        }
        var text: [Rect2] = [], faces: [Rect2] = []
        for d in detections {
            if d.startMs > t { break }
            guard d.endMs > t else { continue }
            let isFace = d.kind == .face
            guard isFace ? config.autoMaskFaces : config.autoMaskSensitiveData, var r = rect(d) else { continue }
            guard r.x < videoSize.width, r.y < videoSize.height, r.x + r.width > 0, r.y + r.height > 0 else { continue }
            if isFace { faces.append(r) } else {
                let pad = config.sensitiveDataExpandPx
                r = Rect2(x: r.x - pad, y: r.y - pad, width: r.width + 2 * pad, height: r.height + 2 * pad)
                text.append(r)
            }
        }
        text = AutoMasks.merged(text, shouldMerge: AutoMasks.textBoxesMerge)
        faces = AutoMasks.merged(faces, shouldMerge: AutoMasks.faceBoxesMerge)
        func n(_ r: Rect2) -> Rect2 { Rect2(x: r.x / videoSize.width, y: r.y / videoSize.height, width: r.width / videoSize.width, height: r.height / videoSize.height) }
        return AutoMaskFrame(bounds01: AutoMasks.capped(text, max: AutoMasks.maxTextBoxes).map(n), faceBounds01: AutoMasks.capped(faces, max: AutoMasks.maxFaceBoxes).map(n))
    }

    @Test func indexedFrameMatchesTheLinearScan() {
        var seed: UInt64 = 0x1234_5678
        func next(_ range: Int) -> Int {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Int((seed >> 33) % UInt64(range))
        }
        var config = ProcessingConfig()
        config.autoMaskSensitiveData = true
        config.autoMaskFaces = true
        let video = Size2(width: 1000, height: 600)
        for round in 0..<40 {
            var detections: [SensitiveDataDetection] = (0..<(5 + next(60))).map { i in
                let start = Double(next(200)) * 50, length = Double(1 + next(80)) * 50
                // Keyframes on a coarse grid, so times repeat and land exactly on query times;
                // some lists are out of order.
                var keys = (0..<(1 + next(6))).map { _ in
                    SensitiveDataKeyframe(timeMs: start + Double(next(Int(length / 50) + 1)) * 50, x: Double(next(1100)) - 50, y: Double(next(650)) - 25, width: Double(5 + next(120)), height: Double(5 + next(40)))
                }
                if next(4) > 0 { keys.sort { $0.timeMs < $1.timeMs } }
                return SensitiveDataDetection(id: i, kind: next(3) == 0 ? .face : .email, text: "", startMs: start, endMs: start + length, keyframes: keys)
            }
            if round % 5 != 4 { detections.sort { $0.startMs < $1.startMs } }
            let timeline = AutoMaskTimeline(detections: detections)
            for step in 0..<300 {
                let t = Double(step) * 50 + (step % 3 == 0 ? 0 : 17)
                #expect(AutoMasks.frame(at: t, timeline: timeline, config: config, videoSize: video) == linearFrame(at: t, detections: detections, config: config, videoSize: video), "round \(round) t \(t)")
            }
        }
    }
}
