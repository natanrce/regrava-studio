import Darwin
import Foundation
import Testing
@testable import RegravaCore

/// Rebuild time, memory and frame time of a track on a 30-minute project. Runs only with
/// `REGRAVA_BENCH=1` and prints its measurements.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["REGRAVA_BENCH"] == "1"))
struct CameraTrackBenchmarkTests {
    static let durationMs = 30.0 * 60 * 1000

    /// Mouse moves every 8 ms on a slow loop, a click every 5 s, a zoom every 20 s (auto and
    /// manual alternating), a loupe every 2 minutes and the webcam on.
    static func longProject() -> Project {
        var events: [MouseEvent] = []
        events.reserveCapacity(Int(durationMs / 8) + 1000)
        var t = 0.0
        while t <= durationMs {
            let a = t / 3000
            events.append(MouseEvent(kind: .move, timeMs: t, position: Vec2(960 + 600 * cos(a), 540 + 300 * sin(a * 1.3))))
            t += 8
        }
        var clickAt = 2500.0
        while clickAt < durationMs {
            let a = clickAt / 3000
            let p = Vec2(960 + 600 * cos(a), 540 + 300 * sin(a * 1.3))
            events.append(MouseEvent(kind: .down, timeMs: clickAt, position: p))
            events.append(MouseEvent(kind: .up, timeMs: clickAt + 90, position: p))
            clickAt += 5000
        }
        events.sort { $0.timeMs < $1.timeMs }
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: durationMs, fps: 60, cameraFileName: "camera.mov", cameraSize: Size2(width: 1280, height: 720)), mouseEvents: events)
        var zooms: [ZoomRange] = []
        var z = 4000.0
        var i = 0
        while z + 6000 < durationMs {
            zooms.append(ZoomRange(startMs: z, endMs: z + 6000, scale: i % 2 == 0 ? 2 : 1.6, mode: i % 2 == 0 ? .auto : .manual, manualTarget: Vec2(0.3, 0.6)))
            if i % 6 == 5 { zooms.append(ZoomRange(startMs: z + 10_000, endMs: z + 14_000, presentation: .loupe)) }
            z += 20_000
            i += 1
        }
        p.zooms = zooms
        return p
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func ms(_ body: () -> Void) -> Double {
        let start = DispatchTime.now().uptimeNanoseconds
        body()
        return Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6
    }

    @Test func thirtyMinuteProject() {
        var project = Self.longProject()
        // Plans the cursor once (shared by every rebuild, as in the editor).
        var warm: CameraTrack? = CameraTrack(project: project)
        _ = warm?.frame(at: 1000)
        warm = nil

        // An edit: one zoom gets deeper, so the cursor plan is reused and the rest rebuilt.
        project.zooms[10].scale = 2.5
        let before = Self.footprintBytes()
        var track: CameraTrack?
        let rebuild = Self.ms { track = CameraTrack(project: project) }
        let firstFrame = Self.ms { _ = track!.frame(at: 15 * 60 * 1000) }
        let grown = Self.footprintBytes()
        print("BENCH rebuild after edit: \(String(format: "%.1f", rebuild)) ms, first frame: \(String(format: "%.2f", firstFrame)) ms, memory: \(String(format: "%.1f", Double(Int64(grown) - Int64(before)) / 1_048_576)) MB")

        let track1 = track!
        // Playback: 10 s at 60 fps from the middle.
        var playback: [Double] = []
        for k in 0..<600 {
            let t = 15 * 60 * 1000 + Double(k) * 1000 / 60
            playback.append(Self.ms { _ = track1.frame(at: t) })
        }
        // Seeks: 200 random times.
        var generator = SystemRandomNumberGenerator()
        var seeks: [Double] = []
        for _ in 0..<200 {
            let t = Double.random(in: 0..<Self.durationMs, using: &generator)
            seeks.append(Self.ms { _ = track1.frame(at: t) })
        }
        func describe(_ v: [Double]) -> String {
            let s = v.sorted()
            let mean = v.reduce(0, +) / Double(v.count)
            return String(format: "mean %.3f ms, p50 %.3f, p95 %.3f, max %.3f", mean, s[s.count / 2], s[s.count * 95 / 100], s.last!)
        }
        print("BENCH playback frame: \(describe(playback))")
        print("BENCH seek frame: \(describe(seeks))")
        // The same seeks again on a new track, the cursor plan's chunks already made.
        let times = (0..<200).map { _ in Double.random(in: 0..<Self.durationMs, using: &generator) }
        for t in times { _ = track1.frame(at: t) }
        let again = CameraTrack(project: project)
        print("BENCH seek frame, cursor planned: \(describe(times.map { t in Self.ms { _ = again.frame(at: t) } }))")
        print("BENCH frame size: \(MemoryLayout<CameraFrame>.stride) bytes")
        // An edit the animation does not read.
        project.captions.sizeRatio = 0.08
        let kept = Self.ms { _ = CameraTrack(project: project, reusing: track1) }
        print("BENCH rebuild after caption edit: \(String(format: "%.1f", kept)) ms")
        // Export: every frame of the first minute in order on a fresh track.
        let export = CameraTrack(project: project)
        let exportMs = Self.ms { for k in 0..<3600 { _ = export.frame(at: Double(k) * 1000 / 60) } }
        print("BENCH export first minute: \(String(format: "%.1f", exportMs)) ms (\(String(format: "%.3f", exportMs / 3600)) ms per frame)")
    }
}
