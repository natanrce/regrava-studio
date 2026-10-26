import Foundation
import Testing
@testable import RegravaCore

/// Binary searches over sorted timelines return what a scan of every element returns.
@Suite struct SearchEquivalenceTests {
    /// Events with repeated timestamps, bursts and long gaps.
    static let events: [MouseEvent] = {
        var out: [MouseEvent] = []
        var t = 100.0
        for i in 0..<400 {
            t += [0.0, 16, 16, 3, 900, 0, 40, 2500][i % 8]
            let x = Double((i * 73) % 1900), y = Double((i * 151) % 1000)
            out.append(MouseEvent(kind: i % 11 == 0 ? .down : .move, timeMs: t, position: Vec2(x, y), cursorID: ["arrow", "pointinghand", "ibeam", nil][i % 4]))
        }
        return out
    }()

    /// Probe times: before the first, after the last, on every timestamp and next to it.
    static func probes(_ times: [Double]) -> [Double] {
        var out = [-1000.0, 0, (times.last ?? 0) + 1, (times.last ?? 0) + 100_000]
        for t in times { out += [t - 350, t - 0.5, t, t + 0.5] }
        return out
    }

    @Test func cursorBoundsMatchesAFullScan() {
        func scan(_ events: [MouseEvent], _ start: Double, _ end: Double) -> Rect2? {
            let floor = MouseProcessing.lastIndex(atOrBefore: start, in: events)
            let inRange = events.indices.filter { events[$0].timeMs >= start && events[$0].timeMs <= end }
            guard let first = floor ?? inRange.first, let last = inRange.last ?? floor else { return nil }
            var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
            for i in first...last {
                let p = events[i].position
                minX = min(minX, p.x); maxX = max(maxX, p.x); minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return Rect2(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        }
        let events = Self.events
        for list in [events, [], Array(events.prefix(1))] {
            for t in Self.probes(list.map(\.timeMs)) {
                for span in [0.0, 350] {
                    #expect(CameraPlanner.cursorBounds(list, from: t, to: t + span) == scan(list, t, t + span))
                }
            }
        }
    }

    @Test func focusGroupLookupMatchesAFullScan() {
        let groups = FocusGrouping.build(events: Self.events, maxExtent: Size2(width: 300, height: 300), endMs: 1_000_000)
        #expect(groups.count > 20)
        for list in [groups, [], Array(groups.prefix(1))] {
            for t in Self.probes(list.map(\.startMs)) {
                let expected = list.last(where: { $0.startMs <= t }) ?? list.first
                #expect(FocusGrouping.group(at: t, in: list) == expected)
            }
        }
    }

    @Test func silenceLookupMatchesAFullScan() {
        // Chunks with a long one, short ones, and one ending where the next window starts.
        let chunks = [
            SilenceChunk(startMs: 0, endMs: 600), SilenceChunk(startMs: 650, endMs: 9000),
            SilenceChunk(startMs: 9050, endMs: 9600), SilenceChunk(startMs: 12_000, endMs: 30_000),
        ]
        func scan(_ chunks: [SilenceChunk], _ t: Double, _ hide: Double) -> Bool {
            guard let chunk = chunks.first(where: { $0.startMs <= t && t <= $0.endMs }),
                  chunk.endMs - chunk.startMs >= hide else { return false }
            return t - chunk.startMs >= SilenceDetection.edgeMs && chunk.endMs - t >= SilenceDetection.edgeMs
        }
        let edges = chunks.flatMap { [$0.startMs, $0.endMs, $0.startMs + SilenceDetection.edgeMs, $0.endMs - SilenceDetection.edgeMs] }
        for list in [chunks, [], [chunks[1]]] {
            for t in Self.probes(edges) + stride(from: -100.0, through: 31_000, by: 37).map({ $0 }) {
                for hide in [100.0, 5000] {
                    #expect(SilenceDetection.isSilent(list, at: t, hideDuringSilenceMs: hide) == scan(list, t, hide))
                }
            }
        }
    }

    @Test func resolvedCursorNamesMatchTheLookup() {
        let types = Self.events
        let names = CursorTypes.assetNames(of: types)
        for always in [false, true] {
            var config = CursorConfig()
            config.alwaysUseDefault = always
            #expect(CursorTypes.imageChangeTimes(types, names: names, config: config) == CursorTypes.imageChangeTimes(types, config: config))
            for list in [types, []] {
                let listNames = CursorTypes.assetNames(of: list)
                for t in Self.probes(list.map(\.timeMs)) {
                    #expect(CursorTypes.assetName(at: t, typeEvents: list, names: listNames, config: config) == CursorTypes.assetName(at: t, typeEvents: list, config: config))
                }
            }
        }
    }

    @Test func neighbourZoomLookupMatchesAFullScan() {
        // Unordered zooms, shared edges, equal starts and ends, and a disabled one.
        let zooms = [
            ZoomRange(startMs: 5000, endMs: 7000, scale: 2),
            ZoomRange(startMs: 1000, endMs: 3000, scale: 2, presentation: .loupe),
            ZoomRange(startMs: 3000, endMs: 5000, scale: 1.5),
            ZoomRange(startMs: 1000, endMs: 3000, scale: 3),
            ZoomRange(startMs: 8000, endMs: 9000, scale: 2, isDisabled: true),
            ZoomRange(startMs: 9500, endMs: 9600, scale: 2, presentation: .loupe),
            ZoomRange(startMs: 9200, endMs: 9600, scale: 2.5),
        ]
        for list in [zooms, [], [zooms[1]], [zooms[4]]] {
            var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 1, durationMs: 12_000, fps: 60), mouseEvents: [MouseEvent(kind: .move, timeMs: 0, position: Vec2(960, 540))])
            p.zooms = list
            let planner = CameraPlanner(project: p, timeline: LayoutTimeline(project: p), cleaned: p.mouseEvents, sparse: p.mouseEvents)
            let enabled = list.filter { !$0.isDisabled }
            for t in Self.probes(list.flatMap { [$0.startMs, $0.endMs] }) {
                #expect(planner.previousEnabledZoom(endingAtOrBefore: t) == enabled.filter { $0.endMs <= t }.max { $0.endMs < $1.endMs })
                #expect(planner.nextEnabledZoom(startingAfter: t) == enabled.filter { $0.startMs > t }.min { $0.startMs < $1.startMs })
            }
        }
    }

    @Test func sliceLookupMatchesAFullScan() {
        func slice(_ start: Double, _ end: Double) -> Slice { Slice(sourceStartMs: start, sourceEndMs: end) }
        // Cuts, a shared edge, a zero-length slice on a shared edge, and an out-of-order list.
        let ordered = [slice(0, 1000), slice(1000, 2500), slice(3000, 3000), slice(3000, 4000), slice(6000, 9000)]
        let unordered = [slice(3000, 4000), slice(0, 1000), slice(500, 1500)]
        for list in [ordered, unordered, [], [ordered[0]]] {
            let lookup = SliceLookup(slices: list)
            for t in Self.probes(list.flatMap { [$0.sourceStartMs, $0.sourceEndMs] }) + stride(from: -50.0, through: 9100, by: 33).map({ $0 }) {
                #expect(lookup.slice(atSource: t) == list.first { $0.contains(sourceTime: t) })
            }
        }
    }

    @Test func previousFrameValuesMatchTheFrameOneStepEarlier() {
        var p = Project(recording: RecordingInfo(videoSize: Size2(width: 1920, height: 1080), pointPixelScale: 2, durationMs: 6000, fps: 30, cameraFileName: "camera.mov", cameraSize: Size2(width: 1280, height: 720)), mouseEvents: Array(Self.events.prefix(60)))
        p.zooms = [ZoomRange(startMs: 1000, endMs: 3000, scale: 2)]
        let track = CameraTrack(project: p)
        for t in stride(from: 0.0, through: 6500, by: 11.7) {
            let frame = track.frame(at: t)
            let before = track.frame(at: max(0, t - track.sampleIntervalMs))
            #expect(frame.previousScreenRect == before.screenRect)
            #expect(frame.previousCursor == before.cursor)
            #expect(frame.previousCursorScale == before.cursorScale)
            #expect(frame.previousCameraRect == before.cameraRect)
        }
    }
}
