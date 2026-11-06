import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import Testing
@testable import RegravaCore
@testable import RegravaRender

struct CameraMattingTests {
    @Test func runsJoinAdjacentChunksUpToTwoPerLane() {
        #expect(CameraMatting.runsOfAdjacentChunks([4, 5, 6, 3, 7, 8], laneCount: 3, chunksPerLane: 2) == [[4, 5], [6, 7], [3]])
        #expect(CameraMatting.runsOfAdjacentChunks([4, 5, 3], laneCount: 3, chunksPerLane: 2) == [[4], [5], [3]])
        #expect(CameraMatting.runsOfAdjacentChunks([4, 3, 9, 10], laneCount: 2, chunksPerLane: 2) == [[3, 4], [9, 10]])
    }

    @Test func memoryForgetsTheLeastRecentlyUsed() {
        let memory = MatteMemory(capacity: 2)
        memory.set(1, [1])
        memory.set(2, [2])
        _ = memory.get(1)
        memory.set(3, [3])
        #expect(memory.get(2) == nil)
        #expect(memory.get(1) == [1])
        #expect(memory.get(3) == [3])
    }
}

struct PersonWindowTests {
    func close(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) < 1e-12 && abs(a.minY - b.minY) < 1e-12 && abs(a.width - b.width) < 1e-12 && abs(a.height - b.height) < 1e-12
    }

    @Test func growsByAFifthAndSnapsOutToTheGrid() {
        let grown = PersonWindow.expand(CGRect(x: 0.3, y: 0.2, width: 0.4, height: 0.5), by: 0.2)
        #expect(close(grown, CGRect(x: 0.21999999999999997, y: 0.1, width: 0.56, height: 0.7)))
        #expect(close(PersonWindow.quantize(grown), CGRect(x: 0.2, y: 0.1, width: 0.6000000000000001, height: 0.7000000000000001)))
        let edge = PersonWindow.expand(CGRect(x: 0.05, y: 0.1, width: 0.3, height: 0.3), by: 0.2)
        #expect(close(PersonWindow.quantize(edge), CGRect(x: 0, y: 0, width: 0.45, height: 0.5)))
    }

    @Test func personBoxCoversValuesFromHalfUp() {
        var matte = [UInt8](repeating: 127, count: FrameMatter.width * FrameMatter.height)
        for y in 100..<200 { for x in 256..<512 { matte[y * FrameMatter.width + x] = 128 } }
        let box = PersonWindow.personBox(matte)
        #expect(box == CGRect(x: 0.25, y: 100.0 / 576, width: 0.25, height: 100.0 / 576))
        #expect(PersonWindow.personBox([UInt8](repeating: 0, count: FrameMatter.width * FrameMatter.height)) == nil)
    }

    @Test func guideTapsRoundSourcePixelsPerMattePixel() {
        #expect(FrameMatter.taps(1920.0 / 1024) == 2)
        #expect(FrameMatter.taps(1.4) == 1)
        #expect(FrameMatter.taps(1.5) == 2)
        #expect(FrameMatter.taps(9) == 4)
        #expect(FrameMatter.taps(0.3) == 1)
    }
}

struct MatteImageTests {
    /// A 2048×1152 BGRA frame: the top half white, the bottom black; the left of the bottom red.
    func frame() -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, 2048, 1152, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer)
        CVPixelBufferLockBaseAddress(buffer!, [])
        let base = CVPixelBufferGetBaseAddress(buffer!)!.assumingMemoryBound(to: UInt8.self)
        let rowBytes = CVPixelBufferGetBytesPerRow(buffer!)
        for y in 0..<1152 {
            for x in 0..<2048 {
                let p = base + y * rowBytes + x * 4
                let top = y < 576, left = x < 1024
                p[0] = top ? 255 : 0; p[1] = top ? 255 : 0; p[2] = top || left ? 255 : 0; p[3] = 255
            }
        }
        CVPixelBufferUnlockBaseAddress(buffer!, [])
        return buffer!
    }

    @Test func guideIsTheWindowAtMatteSizeInPlanesFromTheTop() {
        let w = FrameMatter.width, h = FrameMatter.height, n = w * h
        let guide = FrameMatter.guide(frame(), window: PersonWindow.wholeFrame)
        #expect(guide.count == n * 3)
        // Top: white in every plane. Bottom left: red only. Bottom right: black.
        #expect([guide[100 * w + 200], guide[n + 100 * w + 200], guide[2 * n + 100 * w + 200]] == [255, 255, 255])
        #expect([guide[500 * w + 200], guide[n + 500 * w + 200], guide[2 * n + 500 * w + 200]] == [255, 0, 0])
        #expect([guide[500 * w + 900], guide[n + 500 * w + 900], guide[2 * n + 500 * w + 900]] == [0, 0, 0])
        // The window's bottom-right quarter only: black, with a red left half.
        let quarter = FrameMatter.guide(frame(), window: CGRect(x: 0.25, y: 0.5, width: 0.75, height: 0.5))
        #expect(quarter[300 * w + 100] == 255)
        #expect(quarter[300 * w + 900] == 0)
    }
}
