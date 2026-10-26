import Foundation

// Glass loupe zooms: the screen doesn't zoom; a lens springs over it. (12884).

/// The lens at one instant. Centre in whole-recording 0…1 units, radius in recording-width units.
public struct LoupeFrame: Hashable, Sendable {
    public var center: Vec2
    public var radius: Double
    /// Magnification inside the lens.
    public var zoom: Double
    public var bevelRatio: Double
    public var chromaticAberration: Double
    public var shadowAlpha: Double
    /// 1 while a loupe is on, 0 when it has condensed away.
    public var presence: Double

    /// Shadow falloff in recording widths.
    public static let shadowSize = 0.9

    /// No lens, at the stage centre.
    public static let none = LoupeFrame(center: .center01, radius: 0, zoom: 1, bevelRatio: 0, chromaticAberration: 0, shadowAlpha: 0, presence: 0)

    /// Whether the lens changes anything (k = 1 for the shader).
    public func isVisible(recordingWidth w: Double, k: Double = 1) -> Bool {
        let r = max(0, radius) * w
        guard r > 0.5 * k else { return false }
        return r * clamp(bevelRatio, 0, 1) > 0.05 * k || abs(max(zoom, 0.05) - 1) > 0.001 * k || clamp(shadowAlpha, 0, 1) > 0.001 * k
    }

    func lerp(to other: LoupeFrame, _ f: Double) -> LoupeFrame {
        func m(_ a: Double, _ b: Double) -> Double { a + (b - a) * f }
        return LoupeFrame(center: center.lerp(to: other.center, f), radius: m(radius, other.radius), zoom: m(zoom, other.zoom),
                          bevelRatio: m(bevelRatio, other.bevelRatio), chromaticAberration: m(chromaticAberration, other.chromaticAberration),
                          shadowAlpha: m(shadowAlpha, other.shadowAlpha), presence: m(presence, other.presence))
    }
}

/// Every field sprung on its own.
struct LoupeSpring {
    var cx, cy, radius, zoom, bevel, chroma, shadow, presence: SpringValue

    init(_ f: LoupeFrame) {
        cx = SpringValue(f.center.x); cy = SpringValue(f.center.y); radius = SpringValue(f.radius); zoom = SpringValue(f.zoom)
        bevel = SpringValue(f.bevelRatio); chroma = SpringValue(f.chromaticAberration); shadow = SpringValue(f.shadowAlpha); presence = SpringValue(f.presence)
    }

    mutating func advance(toward f: LoupeFrame, config: SpringConfig, milliseconds ms: Double) {
        cx.advance(toward: f.center.x, config: config, milliseconds: ms)
        cy.advance(toward: f.center.y, config: config, milliseconds: ms)
        radius.advance(toward: f.radius, config: config, milliseconds: ms)
        zoom.advance(toward: f.zoom, config: config, milliseconds: ms)
        bevel.advance(toward: f.bevelRatio, config: config, milliseconds: ms)
        chroma.advance(toward: f.chromaticAberration, config: config, milliseconds: ms)
        shadow.advance(toward: f.shadowAlpha, config: config, milliseconds: ms)
        presence.advance(toward: f.presence, config: config, milliseconds: ms)
    }

    var frame: LoupeFrame {
        LoupeFrame(center: Vec2(cx.value, cy.value), radius: max(radius.value, 0), zoom: zoom.value, bevelRatio: bevel.value,
                   chromaticAberration: chroma.value, shadowAlpha: shadow.value, presence: presence.value)
    }
}

extension CameraPlanner {
    /// The screen spring at 1.5× stiffness, instant in an instant zoom's window (loupes included).
    func loupeSpring(at t: Double) -> SpringConfig {
        if project.zooms.contains(where: { !$0.isDisabled && $0.isInstant && t >= $0.startMs && t <= $0.endMs + 50 }) { return .instant }
        var spring = project.animation.screenSpring
        guard spring.stiffness > 0, !spring.isInstant else { return spring }
        spring.stiffness *= 1.5
        return spring
    }

    /// The loupe shown at `t`: the active one, or the next within its lead-in when no zoom is on.
    func loupeRange(at t: Double) -> ZoomRange? {
        if let active = loupes.last(where: { $0.contains(t) }) { return active }
        let lead = project.animation.leadInMs
        guard lead > 0, !project.zooms.contains(where: { !$0.isDisabled && $0.contains(t) }),
              let next = loupes.first(where: { $0.startMs > t }), !next.isInstant, t >= next.startMs - lead else { return nil }
        return next
    }

    /// The lens of `zoom` at `t`, with a slow drift (1.25% over 12 s and 18 s).
    func loupeOptions(_ zoom: ZoomRange, at t: Double) -> LoupeFrame {
        let video = project.recording.videoSize
        let p = focus(for: zoom, at: t)
        let drift = Vec2(sin(t / 12_000 * 2 * .pi) * 0.0125, cos((t + 7500) / 18_000 * 2 * .pi) * 0.0125)
        let o = zoom.loupeOptions
        return LoupeFrame(
            center: Vec2(clamp(p.x, 0, 1) + drift.x, clamp(p.y, 0, 1) + drift.y),
            radius: o.radius01 * max(video.width, video.height) / max(video.width, 1),
            zoom: zoom.scale,
            bevelRatio: o.hasGlassOptics ? o.bevelRatio : 0,
            chromaticAberration: o.hasGlassOptics ? o.chromaticAberration : 0,
            shadowAlpha: 0.35,
            presence: 1
        )
    }

    /// The lens target; `isActive` when a loupe range applies.
    func loupeTarget(at t: Double) -> (frame: LoupeFrame, isActive: Bool) {
        if let range = loupeRange(at: t) { return (loupeOptions(range, at: t), true) }
        // Inactive stand-in: the nearer of the previous and next zoom of any kind; a loupe
        // keeps its place and size while its optics fade, anything else collapses the lens.
        let previous = previousEnabledZoom(endingAtOrBefore: t)
        let next = nextEnabledZoom(startingAfter: t)
        var nearest: (zoom: ZoomRange, at: Double)?
        switch (previous, next) {
        case let (p?, n?): nearest = t - p.endMs <= n.startMs - t ? (p, p.endMs) : (n, n.startMs)
        case let (p?, nil): nearest = (p, p.endMs)
        case let (nil, n?): nearest = (n, n.startMs)
        default: nearest = nil
        }
        guard let nearest, nearest.zoom.presentation == .loupe else { return (.none, false) }
        var frame = loupeOptions(nearest.zoom, at: nearest.at)
        frame.bevelRatio = 0
        frame.zoom = 1
        frame.chromaticAberration = 0
        frame.shadowAlpha = 0
        frame.presence = 0
        return (frame, false)
    }

    /// `isCoveredByLoupe`: the active lens covers at least half of the camera, sampled on a 32
    /// × 32 grid. Rects in stage units. `target` is `loupeTarget(at:)` of the instant.
    func isCameraCoveredByLoupe(camera: Rect2, screen: Rect2, target: (frame: LoupeFrame, isActive: Bool)) -> Bool {
        guard camera.width > 0, camera.height > 0 else { return false }
        guard target.isActive else { return false }
        let center = Vec2(screen.x + target.frame.center.x * screen.width, screen.y + target.frame.center.y * screen.height)
        let r = target.frame.radius * screen.width
        var inside = 0
        for i in 0..<32 {
            for j in 0..<32 {
                let x = camera.x + (Double(i) + 0.5) / 32 * camera.width
                let y = camera.y + (Double(j) + 0.5) / 32 * camera.height
                if hypot(x - center.x, y - center.y) <= r { inside += 1 }
            }
        }
        return Double(inside) / 1024 >= 0.5
    }

    /// The enabled zoom with the latest end at or before `t`; the first in project order among
    /// equal ends.
    func previousEnabledZoom(endingAtOrBefore t: Double) -> ZoomRange? {
        let byEnd = enabledZoomsByEnd
        guard var i = lastSearch(count: byEnd.count, while: { byEnd[$0].endMs <= t }) else { return nil }
        while i > 0 && byEnd[i - 1].endMs == byEnd[i].endMs { i -= 1 }
        return byEnd[i]
    }

    /// The enabled zoom with the earliest start after `t`; the first in project order among
    /// equal starts.
    func nextEnabledZoom(startingAfter t: Double) -> ZoomRange? {
        let byStart = enabledZoomsByStart
        let i = (lastSearch(count: byStart.count, while: { byStart[$0].startMs <= t }) ?? -1) + 1
        return i < byStart.count ? byStart[i] : nil
    }
}
