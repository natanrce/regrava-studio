import Testing
@testable import RegravaCore

@Suite struct ExportProgressTests {
    @Test func estimatesFromTheMeasuredPace() {
        var estimator = ExportTimeEstimator(createdAtMs: 0)
        estimator.reportProgress(0.1, atMs: 1000, isPaused: false)
        // Under a second of measurement: no estimate yet.
        estimator.reportProgress(0.15, atMs: 1500, isPaused: false)
        #expect(estimator.timeLeftMs(nowMs: 1500, isPaused: false) == nil)
        estimator.reportProgress(0.2, atMs: 2000, isPaused: false)
        // 0.1 per second from the start sample: 8 s left at the latest sample, 7.5 s half a second later.
        #expect(estimator.timeLeftMs(nowMs: 2000, isPaused: false)! == 8000)
        #expect(estimator.timeLeftMs(nowMs: 2500, isPaused: false)! == 7500)
        #expect(estimator.elapsedMs(nowMs: 2500) == 2500)
    }

    @Test func restartsAfterAStallOrGoingBack() {
        var estimator = ExportTimeEstimator(createdAtMs: 0)
        estimator.reportProgress(0.1, atMs: 0, isPaused: false)
        estimator.reportProgress(0.2, atMs: 2000, isPaused: false)
        // More than 3 s since the latest sample.
        #expect(estimator.timeLeftMs(nowMs: 5001, isPaused: false) == nil)
        estimator.reportProgress(0.3, atMs: 5500, isPaused: false)
        #expect(estimator.measurementStart?.atMs == 5500)
        estimator.reportProgress(0.25, atMs: 6000, isPaused: false)
        #expect(estimator.measurementStart?.progress01 == 0.25)
    }

    @Test func pausesWhileOtherWorkRuns() {
        var estimator = ExportTimeEstimator(createdAtMs: 0)
        estimator.reportProgress(0.1, atMs: 0, isPaused: false)
        estimator.reportProgress(0.2, atMs: 1000, isPaused: true)
        #expect(estimator.measurementStart == nil)
        #expect(estimator.timeLeftMs(nowMs: 1000, isPaused: false) == nil)
        estimator.reportProgress(0.3, atMs: 2000, isPaused: false)
        estimator.reportProgress(0.4, atMs: 3000, isPaused: false)
        #expect(abs(estimator.timeLeftMs(nowMs: 3000, isPaused: false)! - 6000) < 1e-6)
        #expect(estimator.timeLeftMs(nowMs: 3000, isPaused: true) == nil)
        estimator.reportProgress(1, atMs: 3500, isPaused: false)
        #expect(estimator.timeLeftMs(nowMs: 9000, isPaused: false) == 0)
    }

    @Test func percentAndDurationTexts() {
        #expect(ExportProgressText.percent(0.996, decimals: 0) == "99%")
        #expect(ExportProgressText.percent(0.12346, decimals: 1) == "12.3%")
        #expect(ExportProgressText.percent(0.12346, decimals: 2) == "12.35%")
        #expect(ExportProgressText.percent(nil, decimals: 2) == "0%")
        #expect(ExportProgressText.percentDecimals(totalMs: 5 * 60_000) == 0)
        #expect(ExportProgressText.percentDecimals(totalMs: 5 * 60_000 + 1) == 1)
        #expect(ExportProgressText.percentDecimals(totalMs: 30 * 60_000 + 1) == 2)
        #expect(ExportProgressText.duration(ms: 4001) == "00:05")
        #expect(ExportProgressText.duration(ms: 75 * 60_000) == "1:15:00")
        #expect(ExportProgressText.duration(ms: 3_599_500) == "1:00:00")
        #expect(ExportProgressText.duration(ms: 600_000) == "10:00")
    }
}
