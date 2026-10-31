import Foundation
import Testing
@testable import RegravaCore

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 1e-9) -> Bool { abs(a - b) <= tolerance }

/// 101 moves 16 ms apart: right at 1.2 px/ms, then left at 0.4 px/ms, drifting down.
private let sweep: [MouseEvent] = (0...100).map { i in
    let t = Double(i) * 16
    return MouseEvent(kind: .move, timeMs: t, position: Vec2(100 + t * (i < 50 ? 1.2 : -0.4), 300 + Double(i) * 5))
}
private let probes: [Double] = [0, 400, 600, 800, 1200, 1600, 2400]

@Suite struct CursorRotationTests {
    @Test func tiltIsOnByDefault() throws {
        let config = try JSONDecoder().decode(CursorConfig.self, from: Data("{}".utf8))
        #expect(config.rotationMode == .velocity)
        #expect(config.rotateOnXMovementRatio == 0.5)
        let follow = try JSONDecoder().decode(CursorConfig.self, from: Data(#"{"rotationMode":"directional","rotateOnXMovementRatio":1.5}"#.utf8))
        #expect(follow.rotationMode == .directional)
        #expect(follow.rotateOnXMovementRatio == 1.5)
    }
}
