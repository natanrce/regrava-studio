import Testing
@testable import RegravaCore

@Suite struct MaskTests {
    private let rect = Rect2(x: 100, y: 100, width: 350, height: 80)

    @Test func limitedSpringSettlesInTime() {
        let rapid = SpringConfig(stiffness: 530, damping: 40, mass: 1)
        let limited = SpringMath.limited(toDurationMs: 200, rapid)
        #expect(SpringMath.settleTime(limited) <= SpringMath.settleTime(rapid))
        #expect(SpringMath.limited(toDurationMs: 20, rapid) == .instant)
        #expect(SpringMath.limited(toDurationMs: 100_000, rapid) == rapid)
    }

    @Test func sensitiveMasksTakeOverEarly() {
        let mask = MaskRange(startMs: 1000, endMs: 2000, bounds: [rect])
        let animator = MaskAnimator(masks: [mask], recordingSize: Size2(width: 1920, height: 1080))
        #expect(animator.current(at: 850)?.id == mask.id)    // 200 ms before a sensitive mask
        #expect(animator.current(at: 700) == nil)
        #expect(animator.current(at: 2150)?.id == mask.id)   // fades out after the end
        var disabled = mask
        disabled.isDisabled = true
        #expect(MaskAnimator(masks: [disabled], recordingSize: Size2(width: 1920, height: 1080)).current(at: 1500) == nil)
    }

    @Test func trackCoversSensitiveDataAndFadesHighlights() {
        var project = Project(
            recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 6000, fps: 60),
            mouseEvents: []
        )
        project.masks = [
            MaskRange(startMs: 1000, endMs: 2000, bounds: [rect]),
            MaskRange(startMs: 4000, endMs: 5000, bounds: [rect], type: .highlight),
        ]
        let track = CameraTrack(project: project)
        let sensitive = track.frame(at: 1500).mask
        #expect(sensitive.active && sensitive.effectiveOpacity == 1 && sensitive.coversArea)
        #expect(abs(sensitive.bounds01.width - 350.0 / 1920) < 1e-9)
        let highlight = track.frame(at: 4500).mask
        #expect(!highlight.coversArea && highlight.effectiveOpacity > 0.99)
        #expect(track.frame(at: 3000).mask.effectiveOpacity < 0.01)
    }
}
