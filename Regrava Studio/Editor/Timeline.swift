import AppKit
import Combine
import RegravaCore
import SwiftUI

/// Track colours.
enum TrackColors {
    static let clip = Color(hex: 0x93610C)
    static let zoom = Theme.Colors.primary
    static let mask = Color(hex: 0x82345A)
    static let layout = Color(hex: 0x65575E)
}

/// The pointer over the timeline, kept apart from the timeline so following it only redraws
/// the hover needle and the words near it, not every track.
@MainActor final class TimelineHover: ObservableObject {
    @Published var x: CGFloat?
}

/// Timeline: ruler, clip track, zoom track, playheads; scroll/zoom/scrub.
struct EditorTimeline: View {
    /// Redraws with the playhead (`EditorModel.clock`).
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var editor: EditorModel
    @ObservedObject var viewport: TimelineViewport
    @StateObject private var hover = TimelineHover()
    @State private var width: CGFloat = 1
    @State private var wheelMonitor: Any?
    @State private var isHovering = false
    @ObservedObject private var preferences = Preferences.shared
    @State private var scrollerStyle = NSScroller.preferredScrollerStyle

    /// Shown when asked for, or when macOS always shows scroll bars.
    private var showsScrollbar: Bool { preferences.alwaysShowTimelineScrollbar || scrollerStyle == .legacy }

    static let horizontalPadding: CGFloat = 20

    private var pxPerMs: CGFloat { max(width - 40, 1) / editor.visibleDurationMs }

    private func x(_ ms: Double) -> CGFloat { Self.horizontalPadding + (ms - editor.scrollOffsetMs) * pxPerMs }
    private func time(_ x: CGFloat) -> Double { editor.scrollOffsetMs + (x - Self.horizontalPadding) / pxPerMs }

    var body: some View {
        GeometryReader { geometry in
            let geo = TimelineGeometry(width: geometry.size.width, scrollOffsetMs: editor.scrollOffsetMs, pxPerMs: max(geometry.size.width - 40, 1) / editor.visibleDurationMs, resolver: editor.project.resolver)
            ZStack(alignment: .topLeading) {
                GridLines(geometry: geo, duration: editor.durationMs).padding(.top, 32)
                VStack(alignment: .leading, spacing: 11.3) {
                    Ruler(geometry: geo, duration: editor.durationMs).frame(height: 20)
                    VStack(alignment: .leading, spacing: 12) {
                        ClipTrack(editor: editor, waveforms: editor.waveforms, geometry: geo, hover: hover)
                            .modifier(SplitWiggle(active: editor.isSplitToolActive))
                        ZoomTrack(editor: editor, geometry: geo, hoverTimeMs: { [hover] in hover.x.map { geo.sourceTime($0) } })
                            .modifier(SplitWiggle(active: editor.isSplitToolActive))
                        // Camera layouts track, only once a layout exists.
                        if !editor.project.cameraLayouts.isEmpty {
                            LayoutTrack(editor: editor, geometry: geo, hoverTimeMs: { [hover] in hover.x.map { geo.sourceTime($0) } })
                            .modifier(SplitWiggle(active: editor.isSplitToolActive))
                        }
                        // Masks track, only once a mask exists.
                        if !editor.project.masks.isEmpty {
                            MaskTrack(editor: editor, geometry: geo, hoverTimeMs: { [hover] in hover.x.map { geo.sourceTime($0) } })
                            .modifier(SplitWiggle(active: editor.isSplitToolActive))
                        }
                        // Shortcuts track, last, while the Keyboard Shortcuts panel is open.
                        if editor.showsShortcutsTrack {
                            ShortcutsTrack(editor: editor, geometry: geo)
                        }
                    }
                }
                .padding(.top, 25 - 20)
                .padding(.bottom, 15)

                // Hover playhead over the tracks, under the playhead; it drops down to 18 px as it nears
                // the playhead (`hideNear`).
                HoverNeedle(editor: editor, hover: hover, geometry: geo, height: geometry.size.height)
                Playhead(color: Theme.Colors.primary, height: geometry.size.height)
                    .offset(x: x(editor.currentTimeMs))
                    .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    if editor.isSplitToolActive { SplitCursor.cursor.set() }
                    isHovering = true
                    hover.x = location.x
                    editor.scrub(to: time(location.x))
                case .ended:
                    isHovering = false
                    hover.x = nil
                    editor.endScrub()
                }
            }
            // A click anywhere, items included, also moves the playhead there.
            .simultaneousGesture(SpatialTapGesture().onEnded { value in
                guard !editor.isSplitToolActive else { return }
                editor.seek(to: time(value.location.x))
            })
            .onChange(of: editor.isSplitToolActive) { _, active in
                if isHovering { (active ? SplitCursor.cursor : NSCursor.arrow).set() }
            }
            .onAppear { width = geometry.size.width; installWheelMonitor() }
            .onChange(of: geometry.size.width) { _, newWidth in width = newWidth }
            .onDisappear { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
        }
        .frame(height: 25 + 20 + 11.3 + 48 + 12 + trackHeight("zooms") + 15
            + (editor.project.cameraLayouts.isEmpty ? 0 : 12 + trackHeight("camera-mode"))
            + (editor.project.masks.isEmpty ? 0 : 12 + trackHeight("masks"))
            + (editor.showsShortcutsTrack ? 12 + trackHeight("shortcuts") : 0))
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if showsScrollbar { TimelineScrollbar(editor: editor, viewport: viewport) }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            scrollerStyle = NSScroller.preferredScrollerStyle
        }
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: editor.focusedTrack)
    }

    /// Focused tracks are 48 px, the others collapse to 16 px.
    private func trackHeight(_ track: String) -> CGFloat {
        editor.focusedTrack == track ? 48 : 16
    }

    /// Plain wheel pans (dominant axis), ⌘+wheel zooms ±15%, pinch zooms around the pointer.
    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard isHovering else { return event }
            // Scrolling during playback stops following the playhead.
            if editor.isPlaying { editor.followSuspended = true }
            let anchor = hover.x.map { time($0) }
            if event.type == .magnify {
                editor.setVisibleDuration(editor.visibleDurationMs * (1 - event.magnification), anchorMs: anchor)
            } else if event.modifierFlags.contains(.command) {
                let direction: Double = event.scrollingDeltaY > 0 ? 0.85 : 1.15
                editor.setVisibleDuration(editor.visibleDurationMs * direction, anchorMs: anchor)
            } else {
                let delta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) ? event.scrollingDeltaX : event.scrollingDeltaY
                let points = event.hasPreciseScrollingDeltas ? delta : delta * 10
                editor.scrollOffsetMs -= Double(points) / pxPerMs
                editor.clampScroll()
            }
            return nil
        }
    }
}

/// While the split tool is on, each track bobs ±1 px, 0.7 s ease-in-out, repeating.
private struct SplitWiggle: ViewModifier {
    var active: Bool

    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([-1.0, 1.0]) { view, y in view.offset(y: y) } animation: { _ in .easeInOut(duration: 0.35) }
        } else {
            content
        }
    }
}

/// The timeline's scroll bar: 14 px, a grey 6 px thumb (107 → 140 on hover → 160 while
/// dragged) that pans the view.
private struct TimelineScrollbar: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var viewport: TimelineViewport
    @State private var hovered = false
    @State private var dragStart: Double?

    var body: some View {
        GeometryReader { geometry in
            let total = max(editor.durationMs, 1)
            let width = geometry.size.width
            let thumbWidth = max(width * min(viewport.visibleDurationMs / total, 1), 20)
            let x = (width - thumbWidth) * min(max(viewport.scrollOffsetMs / max(total - viewport.visibleDurationMs, 1), 0), 1)
            let grey = dragStart != nil ? 160.0 : hovered ? 140 : 107
            Capsule()
                .fill(Color(red: grey / 255, green: grey / 255, blue: grey / 255))
                .frame(width: thumbWidth, height: 6)
                .offset(x: x, y: 4)
                .onHover { hovered = $0 }
                .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                    if dragStart == nil { dragStart = viewport.scrollOffsetMs }
                    let msPerPx = (total - viewport.visibleDurationMs) / max(width - thumbWidth, 1)
                    editor.scrollOffsetMs = (dragStart ?? 0) + Double(value.translation.width) * msPerPx
                    editor.clampScroll()
                }.onEnded { _ in dragStart = nil })
        }
        .frame(height: 14)
        .padding(.horizontal, EditorTimeline.horizontalPadding)
    }
}

/// The timeline is laid out in playback time (`playbackTimeToPxPosition`); items stored in
/// source time are placed through the resolver.
struct TimelineGeometry {
    var width: CGFloat
    var scrollOffsetMs: Double
    var pxPerMs: CGFloat
    var resolver: TimeResolver

    func x(_ ms: Double) -> CGFloat { EditorTimeline.horizontalPadding + (ms - scrollOffsetMs) * pxPerMs }
    func time(_ x: CGFloat) -> Double { scrollOffsetMs + (x - EditorTimeline.horizontalPadding) / pxPerMs }

    /// Position of a source time.
    func sx(_ sourceMs: Double) -> CGFloat { x(resolver.sourceToPlayback(sourceMs)) }
    /// Source time under a position.
    func sourceTime(_ x: CGFloat) -> Double { resolver.playbackToSource(time(x)) }
    /// Source time after moving `fromSource` by `dx` points along the timeline.
    func sourceTime(from sourceMs: Double, movedBy dx: CGFloat) -> Double {
        resolver.playbackToSource(resolver.sourceToPlayback(sourceMs) + dx / pxPerMs)
    }

    /// Marks 100–200 px apart, snapped to the intervals.
    var marksIntervalMs: Double {
        let candidates: [Double] = [500, 1000, 2500, 5000, 10_000, 30_000, 60_000, 120_000, 300_000, 600_000, 900_000, 1_800_000, 3_600_000]
        let ideal = 150 / pxPerMs
        return candidates.min { abs($0 - ideal) < abs($1 - ideal) } ?? 1000
    }
}

// MARK: - Ruler & grid

private struct Ruler: View {
    var geometry: TimelineGeometry
    var duration: Double

    var body: some View {
        let interval = geometry.marksIntervalMs
        let first = (geometry.scrollOffsetMs / interval).rounded(.down) * interval
        let marks = Array(stride(from: max(first, 0), through: min(geometry.time(geometry.width), duration + 5000), by: interval))
        ZStack(alignment: .topLeading) {
            ForEach(marks, id: \.self) { mark in
                VStack(spacing: 3) {
                    if mark.truncatingRemainder(dividingBy: 1000) == 0 {
                        Text(Self.label(mark)).font(Theme.Typo.label.weight(.semibold).monospacedDigit())
                    } else {
                        Text(" ").font(Theme.Typo.label)
                    }
                    Circle().frame(width: 4, height: 4)
                }
                .frame(width: 60)
                .offset(x: geometry.x(mark) - 30)
            }
        }
        .opacity(0.3)
        .allowsHitTesting(false)
    }

    static func label(_ ms: Double) -> String {
        let s = Int(ms / 1000)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

private struct GridLines: View {
    var geometry: TimelineGeometry
    var duration: Double

    var body: some View {
        let interval = geometry.marksIntervalMs
        let first = (geometry.scrollOffsetMs / interval).rounded(.down) * interval
        Canvas { context, size in
            var t = max(first, 0)
            while t <= min(geometry.time(size.width), duration + 5000) {
                let x = geometry.x(t)
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(Color.white.opacity(0x06 / 255)))
                t += interval
            }
        }
        .allowsHitTesting(false)
    }
}

/// 1 px line fading toward the bottom, with a teardrop head pointing down (12×12, radius 10/10/10/0, −45°),
/// both from the top of the timeline and shifted down 1 px.
private struct Playhead: View {
    var color: Color
    var height: CGFloat
    var isPrimary = true

    /// `backgroundAccent.active`, opaque so the line doesn't show through the head (shade approximated).
    static let secondaryColor = Color(hex: 0x4A4C53)

    /// `hideNear`: `mapRange(|hover − playhead|, [0, visible/75], [18, 0], easeInOutSine)`.
    static func drop(distanceMs: Double, visibleDurationMs: Double) -> CGFloat {
        let range = visibleDurationMs / 75
        guard range > 0 else { return 0 }
        let p = min(max(distanceMs / range, 0), 1)
        let eased = -(cos(Double.pi * p) - 1) / 2
        return CGFloat(18 * (1 - eased))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: height)
            // CSS radius `10 10 10 0` on 12 px scales to 6: a circle with the bottom-left corner
            // sharp, so −45° points it down and its top sits on the line's top.
            UnevenRoundedRectangle(topLeadingRadius: 6, bottomLeadingRadius: 0, bottomTrailingRadius: 6, topTrailingRadius: 6)
                .fill(color)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(-45))
        }
        .frame(width: 12)
        .offset(x: -5.5, y: 1)
    }
}

/// Split tool beam: 1 px, #FF453A fading at both ends.
private struct SplitBeam: View {
    var height: CGFloat

    var body: some View {
        Rectangle()
            .fill(LinearGradient(colors: [Theme.Colors.danger.opacity(0), Theme.Colors.danger, Theme.Colors.danger.opacity(0)], startPoint: .top, endPoint: .bottom))
            .frame(width: 1, height: height)
    }
}

// MARK: - Item body

/// Track item: vertical gradient, 1 px ring, radius 10; "played"/"active" variants.
struct TrackItemBody: View {
    var color: Color
    var isPlayed: Bool
    var isActive: Bool
    var isSelected: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(LinearGradient(colors: [color, color.lightness(15)], startPoint: .top, endPoint: .bottom))
            // Inner glow `inset 0 0 15px 3px`: C.darken(0.2)·0.8, C·0.5 under the playhead,
            // C.darken(0.2)·0.5 when active (Kh).
            .overlay(
                // Solid from 10 px outside to 3 px inside (the spread), blurred by σ 7.5, kept inside.
                RoundedRectangle(cornerRadius: 13)
                    .strokeBorder(isPlayed ? color.opacity(0.5) : color.darken(0.2).opacity(isActive ? 0.5 : 0.8), lineWidth: 13)
                    .padding(-10)
                    .blur(radius: 7.5)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isActive ? Color.white : color.lightness(isPlayed ? 15 : 40), lineWidth: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(isSelected ? color.mix(with: .white, by: 0.5).opacity(0.8) : .clear, lineWidth: 1)
                    .padding(-2)
            )
    }
}

/// Head label + chips; shown according to the item width.
struct TrackItemLabels: View {
    var kind: String
    var chips: [(icon: String, text: String)]
    var width: CGFloat

    var body: some View {
        VStack(alignment: .center, spacing: 1) {
            if width - 32 > 30 {
                Text(kind).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            }
            if width - 32 > 120 {
                HStack(spacing: 8) {
                    ForEach(chips.indices, id: \.self) { i in
                        HStack(spacing: 2) {
                            Image(systemName: chips[i].icon).scaleEffect(0.8)
                            Text(chips[i].text)
                        }
                    }
                }
                .font(Theme.Typo.copy)
            }
        }
        .lineLimit(1)
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .allowsHitTesting(false)
    }
}

/// The second playhead under the pointer while paused; it drops down to 18 px as it nears the
/// playhead (`hideNear`). The split tool shows its beam there instead.
private struct HoverNeedle: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var hover: TimelineHover
    @EnvironmentObject private var clock: PlaybackClock
    var geometry: TimelineGeometry
    var height: CGFloat

    var body: some View {
        if let x = hover.x {
            if editor.isSplitToolActive {
                SplitBeam(height: height).offset(x: geometry.x(editor.beamPlaybackMs(geometry.time(x)))).allowsHitTesting(false)
            } else if !editor.isPlaying {
                Playhead(color: Playhead.secondaryColor, height: height, isPrimary: false)
                    .offset(x: x, y: Playhead.drop(distanceMs: abs(geometry.time(x) - clock.currentTimeMs), visibleDurationMs: editor.visibleDurationMs))
                    .allowsHitTesting(false)
            }
        }
    }
}

/// Transcript words near the hover position, while paused: 4 px above the clip track,
/// over the marks there, each x sprung on its own.
private struct HoverWords: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var hover: TimelineHover
    var geometry: TimelineGeometry

    var body: some View {
        if !editor.isPlaying, let x = hover.x, editor.transcript != nil {
            let hoverPlaybackMs = geometry.time(x)
            let labels = TimelineWords.labels(editor.clientTranscript, resolver: geometry.resolver, previewMs: hoverPlaybackMs, pxPerMs: geometry.pxPerMs)
            ZStack {
                ForEach(labels, id: \.id) { label in
                    TimelineWordLabel(text: label.text, x: x + label.offset, opacity: label.opacity)
                        .zIndex(label.opacity * 100)
                }
            }
            .allowsHitTesting(false)
        }
    }
}

// MARK: - Clip track

private struct ClipTrack: View {
    @ObservedObject var editor: EditorModel
    @ObservedObject var waveforms: TimelineWaveforms
    @ObservedObject private var preferences = Preferences.shared
    var geometry: TimelineGeometry
    var hover: TimelineHover

    var body: some View {
        let slices = editor.project.slices
        ZStack(alignment: .topLeading) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                SliceItem(editor: editor, slice: slice, index: index, geometry: geometry, waveforms: preferences.hideAudioWaveform ? [] : waveforms.layers, isSmoothWaveform: preferences.enableSmoothWaveform, hoverPlaybackMs: { [hover] in hover.x.map { geometry.time($0) } })
            }
            // Marks above the track: cut and trim pins, typing suggestions, recording flags.
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                CutPins(editor: editor, slices: slices, index: index, geometry: geometry)
            }
            ForEach(editor.project.pendingTypingSuggestions, id: \.startMs) { range in
                TypingSuggestionChip(editor: editor, range: range, geometry: geometry)
            }
            // Resume points: where each session after a pause starts, under the flags.
            ForEach(editor.project.recording.sessionStartsMs.filter { geometry.resolver.isSourceTimePresent($0) }, id: \.self) { start in
                Image(systemName: "pause.circle")
                    .font(.system(size: 10))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0x88 / 255), radius: 2)
                    .offset(x: geometry.sx(start) - 5, y: -14)
                    .allowsHitTesting(false)
            }
            ForEach(editor.project.markersMs.filter { geometry.resolver.isSourceTimePresent($0) }, id: \.self) { marker in
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TrackColors.clip.mix(with: .white, by: 0.4))
                    .offset(x: geometry.sx(marker) - 3, y: -14)
                    .tooltip("Recording flag")
            }
        }
        .frame(height: 48)
        // Transcript words near the hover position, while paused: 4 px above the clip track,
        // over the marks there, each x sprung on its own.
        .overlay(alignment: .topLeading) { HoverWords(editor: editor, hover: hover, geometry: geometry) }
        .zIndex(1)
    }

    /// "12s", "1m 5s", "2min".
    static func duration(_ ms: Double) -> String {
        let s = Int((ms / 1000).rounded())
        if s < 60 { return "\(s)s" }
        if s % 60 == 0 { return "\(s / 60)min" }
        return "\(s / 60)m \(s % 60)s"
    }

    /// Speed chip: "1.5×"; below 1× with two decimals.
    static func speed(_ speed: Double) -> String {
        let text = speed >= 1 ? String(format: "%g", (speed * 10).rounded() / 10) : String(format: "%g", (speed * 100).rounded() / 100)
        return text + "×"
    }
}

/// A transcript word over the timeline: centred on `x`, bottom 4 px above the clip track,
/// its x sprung with `{stiffness 500, damping 32, mass 1.6}`.
private struct TimelineWordLabel: View {
    var text: String
    var x: CGFloat
    var opacity: Double

    var body: some View {
        Text(text)
            .font(Theme.Typo.label)
            .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            .shadow(color: .black.opacity(0.8), radius: 2)
            .lineLimit(1)
            .fixedSize()
            // Bottom-centre on (x, −4) of the clip track.
            .frame(width: 0, height: 0, alignment: .bottom)
            .position(x: x, y: -4)
            .opacity(opacity)
            .animation(.interpolatingSpring(mass: 1.6, stiffness: 500, damping: 32), value: x)
    }
}

/// One clip: duration, speed and cursor chips; click opens the slice editor; edges trim.
private struct SliceItem: View {
    /// Redraws with the playhead (`EditorModel.clock`).
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var editor: EditorModel
    var slice: Slice
    var index: Int
    var geometry: TimelineGeometry
    var waveforms: [TimelineWaveforms.Layer]
    var isSmoothWaveform: Bool
    var hoverPlaybackMs: () -> Double?
    @Environment(\.displayScale) private var displayScale
    @State private var hovered = false
    @State private var dragOrigin: Slice?

    private var isOpen: Bool { editor.openSliceID == slice.id }

    var body: some View {
        let start = geometry.sx(slice.sourceStartMs)
        let width = max(geometry.sx(slice.sourceEndMs) - start - 1, 2)
        let handle = floor(min(16, width / 3))
        var chips: [(icon: String, text: String)] = [
            ("clock", ClipTrack.duration(slice.sourceDurationMs)),
            ("gauge.with.dots.needle.67percent", ClipTrack.speed(slice.speed)),
        ]
        if slice.hideCursor {
            chips.append(("cursorarrow", "Hide"))
        } else if slice.disableSmoothMouseMovement {
            chips.append(("cursorarrow.motionlines", ""))
        }
        return TrackItemBody(
            color: TrackColors.clip,
            isPlayed: slice.contains(sourceTime: editor.currentSourceTimeMs),
            isActive: isOpen,
            isSelected: isOpen
        )
        .overlay(alignment: .bottomLeading) { waveform(start: start, width: width) }
        .overlay { timeLines(start: start, width: width) }
        .overlay { TrackItemLabels(kind: "Clip", chips: chips, width: width) }
        .overlay(alignment: .leading) { if handle >= 16 { trimHandle(.start, width: handle) } }
        .overlay(alignment: .trailing) { if handle >= 16 { trimHandle(.end, width: handle) } }
        .frame(width: width, height: 48)
        .opacity(editor.openSliceID != nil && !isOpen ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { inside in
            hovered = inside
            // The hovered clip is a shortcut target.
            if inside { editor.hoveredSliceID = slice.id } else if editor.hoveredSliceID == slice.id { editor.hoveredSliceID = nil }
        }
        .onTapGesture {
            if editor.isSplitToolActive, let hoverPlaybackMs = hoverPlaybackMs() {
                if let source = editor.beamSplitSource(startMs: slice.sourceStartMs, endMs: slice.sourceEndMs, minimumMs: Slice.minimumDurationMs, hoverPlaybackMs: hoverPlaybackMs) {
                    editor.splitSlice(atPlayback: editor.project.resolver.sourceToPlayback(source))
                }
            } else {
                editor.openSlice(slice.id)
            }
        }
        .nativeContextMenu { editor.sliceMenu(slice) }
        .offset(x: start + 1)
    }

    /// The waveforms under the lines, only over the part on screen.
    @ViewBuilder
    private func waveform(start: CGFloat, width: CGFloat) -> some View {
        let lower = max(0, -start - 1), upper = min(width, geometry.width - start - 1)
        if !waveforms.isEmpty, upper > lower {
            SliceWaveform(layers: waveforms, slice: slice, geometry: geometry, originX: start + 1, visible: lower...upper, isSmooth: isSmoothWaveform, scale: displayScale)
                .equatable()
                .frame(width: width, height: AudioWaveform.heightPx, alignment: .leading)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
                .allowsHitTesting(false)
        }
    }

    /// Vertical lines every `marksInterval` inside the clip, at 68/255 (slice-waveform `lines`).
    private func timeLines(start: CGFloat, width: CGFloat) -> some View {
        Canvas { context, size in
            let interval = geometry.marksIntervalMs
            let playbackStart = geometry.resolver.sourceToPlayback(slice.sourceStartMs)
            let playbackEnd = geometry.resolver.sourceToPlayback(slice.sourceEndMs)
            var t = (playbackStart / interval).rounded(.up) * interval
            while t < playbackEnd {
                let x = geometry.x(t) - start - 1
                if x > 0 && x < size.width {
                    context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(TrackColors.clip.mix(with: .white, by: 0.4).opacity(68.0 / 255)))
                }
                t += interval
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .allowsHitTesting(false)
    }

    /// Dragging an edge trims the clip; source time moves at the clip's speed.
    private func trimHandle(_ edge: Project.SliceEdge, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: width)
            .overlay {
                Capsule().fill(Color.white).frame(width: 3).padding(.vertical, 9).opacity(hovered ? 1 : 0)
            }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? slice
                        if dragOrigin == nil { dragOrigin = slice }
                        let delta = Double(value.translation.width / geometry.pxPerMs) * origin.speed
                        let edgeMs = edge == .start ? origin.sourceStartMs : origin.sourceEndMs
                        editor.trimSlice(slice.id, edge: edge, toSource: edgeMs + delta)
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}

/// Clip context menu. Cut and trim pins: a 24 px teardrop with scissors and the cut length;
/// "Undo trim" restores the trimmed time, "Join clips" merges two clips split without a gap.
private struct CutPins: View {
    @ObservedObject var editor: EditorModel
    var slices: [Slice]
    var index: Int
    var geometry: TimelineGeometry

    var body: some View {
        let slice = slices[index]
        let startGap: Double? = index == 0 && slice.sourceStartMs > 0 ? slice.sourceStartMs : nil
        let endGap: Double? = index + 1 < slices.count
            ? max(0, slices[index + 1].sourceStartMs - slice.sourceEndMs)
            : (slice.sourceEndMs < editor.project.recording.durationMs ? editor.project.recording.durationMs - slice.sourceEndMs : nil)
        ZStack(alignment: .topLeading) {
            if let startGap {
                pin(gap: startGap, showsLabel: startGap > 0, at: slice.sourceStartMs) {
                    startGap > 1 ? editor.removeSliceTrim(slice.id, edge: .start) : editor.mergeSlice(slice.id, with: .previous)
                }
            }
            if let endGap {
                pin(gap: endGap, showsLabel: endGap > 1, at: slice.sourceEndMs) {
                    endGap > 1 ? editor.removeSliceTrim(slice.id, edge: .end) : editor.mergeSlice(slice.id, with: .next)
                }
            }
        }
    }

    private func pin(gap: Double, showsLabel: Bool, at sourceMs: Double, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            ZStack {
                UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 1.5, topTrailingRadius: 12)
                    .fill(TrackColors.clip)
                    .overlay(
                        UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 1.5, topTrailingRadius: 12)
                            .strokeBorder(Theme.Colors.background, lineWidth: 1)
                    )
                    .rotationEffect(.degrees(45))
                VStack(spacing: 1) {
                    if showsLabel {
                        Text(Self.gapLabel(gap)).font(.system(size: 7, weight: .heavy)).padding(.top, 5)
                    }
                    Image(systemName: "scissors").font(.system(size: gap > 1 ? 8 : 9))
                }
                .foregroundStyle(.white)
            }
            .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .tooltip(gap > 1 ? "Undo trim" : "Join clips")
        .offset(x: geometry.sx(sourceMs) - 12, y: -30)
    }

    /// "0.4s", "12s", "3m", "1h".
    static func gapLabel(_ ms: Double) -> String {
        let s = ms / 1000
        if s < 1 { return String(format: "%.1fs", s) }
        if s < 60 { return String(format: "%.0fs", s) }
        let m = Int(s / 60)
        return m < 60 ? "\(m)m" : "\(m / 60)h"
    }
}

/// Keyboard chip over a fast-typing range with the "Speed up typing" popover.
private struct TypingSuggestionChip: View {
    @ObservedObject var editor: EditorModel
    var range: TimeRange
    var geometry: TimelineGeometry
    @State private var isOpen = false
    /// Padding 4/6/3 around a 12 px line.
    static let height: CGFloat = 4 + 12 + 3

    var body: some View {
        let start = geometry.sx(range.startMs)
        let width = max(geometry.sx(range.endMs) - start, 22)
        Button { isOpen = true } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(TrackColors.clip.mix(with: .black, by: 0.3))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TrackColors.clip.mix(with: .white, by: 0.3), lineWidth: 1))
                .overlay(Image(systemName: "keyboard").font(.system(size: 10)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: width, height: Self.height)
        }
        .buttonStyle(.plain)
        .tooltip("Speed up typing")
        // Sits on top of the clip track with 1 px between (bottom 100%, padding-bottom 1).
        .alignmentGuide(.leading) { _ in -start }
        .alignmentGuide(.top) { _ in Self.height + 1 }
        .popover(isPresented: $isOpen, arrowEdge: .top) {
            VStack(alignment: .leading, spacing: Theme.gap(2)) {
                SliderField(
                    name: "Speed up typing",
                    icon: "keyboard",
                    description: "You are typing during this part of the recording. Speed it up using options below.",
                    value: Binding(get: { editor.preferredTypingSpeed }, set: { editor.preferredTypingSpeed = $0 }),
                    range: 1.5...8,
                    preview: { String(format: "%.1f×", $0) },
                    resetValue: 3
                )
                VStack(spacing: Theme.gap(1)) {
                    HStack(spacing: Theme.gap(1)) {
                        RSButton(title: "Apply all suggestions", kind: .subtle, isWide: true, shortcut: "⌘↩") {
                            editor.applyAllTypingSuggestions()
                            isOpen = false
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        RSButton(title: "Apply suggestion", kind: .primary, isWide: true, shortcut: "↩") {
                            editor.applyTypingSuggestion(range)
                            isOpen = false
                        }
                        .keyboardShortcut(.return, modifiers: [])
                    }
                    RSButton(title: "Remove suggestion", kind: .secondary, isWide: true) {
                        editor.removeTypingSuggestion(range)
                        isOpen = false
                    }
                }
            }
            .padding(Theme.gap(2))
            .frame(maxWidth: 360)
            .environment(\.colorScheme, .dark)
            // systemPopover: #1e1e1ecc.
            .presentationBackground(Color(hex: 0x1E1E1E).opacity(0xCC / 255))
        }
    }
}

// MARK: - Zoom track

private struct ZoomTrack: View {
    @ObservedObject var editor: EditorModel
    var geometry: TimelineGeometry
    var hoverTimeMs: () -> Double?
    @State private var hoveringTrack = false
    @State private var focusTask: Task<Void, Never>?
    @State private var ghostTimeMs: Double?
    @State private var creation: (start: Double, end: Double)?

    private var isFocused: Bool { editor.focusedTrack == "zooms" }

    var body: some View {
        let height: CGFloat = isFocused ? 48 : 16
        ZStack(alignment: .topLeading) {
            // Empty area: ghost / create by click or drag, track context menu.
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(height: height)
                .onContinuousHover { phase in
                    if case .active(let location) = phase, isFocused { ghostTimeMs = geometry.sourceTime(location.x) } else { ghostTimeMs = nil }
                }
                .gesture(createGesture)
                .nativeContextMenu { editor.zoomTrackMenu() }

            if isFocused {
                leadInBands
                if editor.project.zooms.isEmpty && ghostTimeMs == nil {
                    Text("Click or drag to add zoom on cursor")
                        .font(Theme.Typo.copy)
                        .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(RoundedRectangle(cornerRadius: 10).fill(TrackColors.zoom.opacity(0.1)))
                        .padding(.horizontal, EditorTimeline.horizontalPadding)
                        .allowsHitTesting(false)
                }
                ghost
            }

            ForEach(editor.project.zooms) { zoom in
                ZoomItem(editor: editor, zoom: zoom, geometry: geometry, height: height, isFocused: isFocused, hoverTimeMs: hoverTimeMs)
            }

            if !isFocused {
                Text("Zoom")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                    .padding(.leading, 20)
                    .padding(.trailing, 120)
                    .frame(height: 16)
                    .background(LinearGradient(colors: [Theme.Colors.background, Theme.Colors.background.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .tooltip(isFocused ? "" : "Click to edit")
        .onHover { inside in
            hoveringTrack = inside
            focusTask?.cancel()
            if inside && !isFocused {
                // Hovering an unfocused track for 30 ms focuses it.
                focusTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if !Task.isCancelled && hoveringTrack { editor.focusedTrack = "zooms" }
                }
            }
        }
    }

    /// Ghost item at the mouse, constrained to the free gap; shows `plus` when wider than 20 px.
    @ViewBuilder
    private var ghost: some View {
        if let range = creation ?? ghostRange {
            let width = max(geometry.sx(range.end) - geometry.sx(range.start) - 1, 1)
            TrackItemBody(color: TrackColors.zoom, isPlayed: false, isActive: false, isSelected: false)
                .opacity(0.5)
                .overlay { if width > 20 { Image(systemName: "plus").foregroundStyle(.white) } }
                .frame(width: width, height: 48)
                .overlay(alignment: .top) {
                    if !UserDefaults.standard.bool(forKey: "onboarding.creating-zoom") {
                        BobbingHint(text: "Click or drag to create zoom").offset(y: -38).fixedSize()
                    }
                }
                .offset(x: geometry.sx(range.start) + 1)
                .allowsHitTesting(false)
        }
    }

    private var ghostRange: (start: Double, end: Double)? {
        guard let ghostTimeMs, ghostTimeMs >= 0, ghostTimeMs <= editor.project.recording.durationMs,
              let gap = editor.freeRange(around: ghostTimeMs) else { return nil }
        let start = clamp(ghostTimeMs, gap.start, gap.end)
        let end = min(start + ZoomRange.initialDurationMs, gap.end)
        return end - start >= ZoomRange.minimumDurationMs ? (start, end) : nil
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isFocused else { return }
                let a = geometry.sourceTime(value.startLocation.x)
                let b = geometry.sourceTime(value.location.x)
                if abs(value.translation.width) > 3, let gap = editor.freeRange(around: a) {
                    creation = (clamp(min(a, b), gap.start, gap.end), clamp(max(a, b), gap.start, gap.end))
                }
            }
            .onEnded { value in
                guard isFocused else {
                    editor.focusedTrack = "zooms"
                    return
                }
                if let creation, creation.end - creation.start >= ZoomRange.minimumDurationMs {
                    editor.addZoom(startMs: creation.start, durationMs: creation.end - creation.start)
                } else if let range = ghostRange {
                    editor.addZoom(startMs: range.start, durationMs: range.end - range.start)
                }
                creation = nil
            }
    }

    /// Lead-in bands before each zoom when "Start animation early" is on.
    @ViewBuilder
    private var leadInBands: some View {
        let lead = editor.project.animation.leadInMs
        if lead > 0 {
            ForEach(editor.project.zooms.filter { !$0.isDisabled && !$0.isInstant }) { zoom in
                UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 0)
                    .fill(LinearGradient(colors: [TrackColors.zoom.opacity(0), TrackColors.zoom.opacity(0.45)], startPoint: .leading, endPoint: .trailing))
                    .frame(width: max(geometry.sx(zoom.startMs) - geometry.sx(zoom.startMs - lead), 0), height: 48)
                    .offset(x: geometry.sx(zoom.startMs - lead))
                    .allowsHitTesting(false)
            }
        }
    }

}

/// Floating hint that bobs (2 s): blurred background at 0.8, padding 6×12, radius 5, weight 500.
private struct BobbingHint: View {
    var text: String

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2) / 2
            Text(text)
                .font(Theme.Typo.label.weight(.medium))
                .padding(.vertical, 6)
                .padding(.horizontal, 12)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.Colors.background.opacity(0.8)))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.Colors.systemBorder))
                .offset(y: CGFloat(sin(t * .pi * 2)) * 3)
        }
    }
}

private struct ZoomItem: View {
    /// Redraws with the playhead (`EditorModel.clock`).
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var editor: EditorModel
    var zoom: ZoomRange
    var geometry: TimelineGeometry
    var height: CGFloat
    var isFocused: Bool
    var hoverTimeMs: () -> Double?
    @State private var hovered = false
    @State private var dragOrigin: ZoomRange?

    private var isOpen: Bool { editor.openZoomID == zoom.id }
    private var isSelected: Bool { editor.selectedZoomIDs.contains(zoom.id) || isOpen }
    private var isDimmed: Bool { editor.openZoomID != nil && !isOpen }

    var body: some View {
        let width = max(geometry.sx(zoom.endMs) - geometry.sx(zoom.startMs) - 1, 1)
        let handle = floor(min(16, width / 3))
        TrackItemBody(
            color: TrackColors.zoom,
            isPlayed: zoom.contains(editor.currentSourceTimeMs),
            isActive: isOpen,
            isSelected: isSelected
        )
        .overlay {
            if isFocused {
                TrackItemLabels(
                    kind: zoom.presentation == .loupe ? "Glass Loupe zoom" : "Zoom",
                    chips: [("magnifyingglass", String(format: "%g×", (zoom.scale * 10).rounded() / 10)), ("computermouse.fill", zoom.mode == .manual ? "Manual" : "Auto")],
                    width: width
                )
            }
        }
        .overlay(alignment: .leading) { if handle >= 16 && isFocused { resizeHandle(leading: true, width: handle) } }
        .overlay(alignment: .trailing) { if handle >= 16 && isFocused { resizeHandle(leading: false, width: handle) } }
        .frame(width: width, height: height)
        .opacity(zoom.hasNoVisualEffect ? 0.5 : isDimmed ? 0.3 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { inside in
            hovered = inside
            if inside && !editor.isSplitToolActive { NSCursor.openHand.push() } else if !inside { NSCursor.pop() }
        }
        .gesture(moveGesture)
        .simultaneousGesture(TapGesture().onEnded { tap() })
        .nativeContextMenu(onClose: { editor.menuPreview = nil }) { editor.zoomMenu(zoom) }
        .offset(x: geometry.sx(zoom.startMs) + 1)
    }

    private func tap() {
        if editor.isSplitToolActive, let hoverTimeMs = hoverTimeMs() {
            if let source = editor.beamSplitSource(startMs: zoom.startMs, endMs: zoom.endMs, minimumMs: ZoomRange.minimumDurationMs, hoverPlaybackMs: editor.project.resolver.sourceToPlayback(hoverTimeMs)) { editor.splitZoom(zoom.id, at: source) }
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            if editor.selectedZoomIDs.contains(zoom.id) { editor.selectedZoomIDs.remove(zoom.id) } else { editor.selectedZoomIDs.insert(zoom.id) }
        } else {
            editor.openZoom(zoom.id)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { value in
                guard !editor.isSplitToolActive else { return }
                let origin = dragOrigin ?? zoom
                if dragOrigin == nil { dragOrigin = zoom }
                editor.moveZoom(zoom.id, toStart: geometry.sourceTime(from: origin.startMs, movedBy: value.translation.width))
            }
            .onEnded { _ in dragOrigin = nil }
    }

    /// 3 px white bar, padding 9px 0, visible on item hover; cursor ew-resize.
    private func resizeHandle(leading: Bool, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: width)
            .overlay {
                Capsule().fill(Color.white).frame(width: 3).padding(.vertical, 9).opacity(hovered ? 1 : 0)
            }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? zoom
                        if dragOrigin == nil { dragOrigin = zoom }
                        let edge = leading ? origin.startMs : origin.endMs
                        editor.resizeZoom(zoom.id, leading: leading, to: geometry.sourceTime(from: edge, movedBy: value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }

}

/// Zoom levels for keys 1…9 (and 0 = default level).
enum EditorShortcuts {
    static let zoomLevels: [Double] = [1, 1.2, 1.4, 1.6, 1.8, 2, 2.2, 2.4, 2.6]
}

// MARK: - Masks track

private struct MaskTrack: View {
    @ObservedObject var editor: EditorModel
    var geometry: TimelineGeometry
    var hoverTimeMs: () -> Double?
    @State private var hoveringTrack = false
    @State private var focusTask: Task<Void, Never>?
    @State private var ghostTimeMs: Double?
    @State private var creation: (start: Double, end: Double)?

    private var isFocused: Bool { editor.focusedTrack == "masks" }

    var body: some View {
        let height: CGFloat = isFocused ? 48 : 16
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(height: height)
                .onContinuousHover { phase in
                    if case .active(let location) = phase, isFocused { ghostTimeMs = geometry.sourceTime(location.x) } else { ghostTimeMs = nil }
                }
                .gesture(createGesture)
.nativeContextMenu { editor.maskTrackMenu() }
            if isFocused, let range = creation ?? ghostRange {
                let width = max(geometry.sx(range.end) - geometry.sx(range.start) - 1, 1)
                TrackItemBody(color: TrackColors.mask, isPlayed: false, isActive: false, isSelected: false)
                    .opacity(0.5)
                    .overlay { if width > 20 { Image(systemName: "plus").foregroundStyle(.white) } }
                    .frame(width: width, height: 48)
                    .tooltip("Click or drag to create a new mask")
                    .offset(x: geometry.sx(range.start) + 1)
                    .allowsHitTesting(false)
            }
            ForEach(editor.project.masks) { mask in
                MaskItem(editor: editor, mask: mask, geometry: geometry, height: height, isFocused: isFocused, hoverTimeMs: hoverTimeMs)
            }
            if !isFocused {
                Text("Mask")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                    .padding(.leading, 20)
                    .padding(.trailing, 120)
                    .frame(height: 16)
                    .background(LinearGradient(colors: [Theme.Colors.background, Theme.Colors.background.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .onHover { inside in
            hoveringTrack = inside
            focusTask?.cancel()
            if inside && !isFocused {
                focusTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if !Task.isCancelled && hoveringTrack { editor.focusedTrack = "masks" }
                }
            }
        }
    }

    private var ghostRange: (start: Double, end: Double)? {
        guard let ghostTimeMs, ghostTimeMs >= 0, ghostTimeMs <= editor.project.recording.durationMs,
              let gap = editor.freeMaskRange(around: ghostTimeMs) else { return nil }
        let start = clamp(ghostTimeMs, gap.start, gap.end)
        let end = min(start + MaskRange.initialDurationMs, gap.end)
        return end - start >= MaskRange.minimumDurationMs ? (start, end) : nil
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isFocused else { return }
                let a = geometry.sourceTime(value.startLocation.x)
                let b = geometry.sourceTime(value.location.x)
                if abs(value.translation.width) > 3, let gap = editor.freeMaskRange(around: a) {
                    creation = (clamp(min(a, b), gap.start, gap.end), clamp(max(a, b), gap.start, gap.end))
                }
            }
            .onEnded { _ in
                guard isFocused else {
                    editor.focusedTrack = "masks"
                    return
                }
                if let creation, creation.end - creation.start >= MaskRange.minimumDurationMs {
                    editor.addMask(startMs: creation.start, endMs: creation.end)
                } else if let range = ghostRange {
                    editor.addMask(startMs: range.start, endMs: range.end)
                }
                creation = nil
            }
    }
}

private struct MaskItem: View {
    /// Redraws with the playhead (`EditorModel.clock`).
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var editor: EditorModel
    var mask: MaskRange
    var geometry: TimelineGeometry
    var height: CGFloat
    var isFocused: Bool
    var hoverTimeMs: () -> Double?
    @State private var hovered = false
    @State private var dragOrigin: MaskRange?

    private var isOpen: Bool { editor.openMaskID == mask.id }

    var body: some View {
        let width = max(geometry.sx(mask.endMs) - geometry.sx(mask.startMs) - 1, 1)
        let handle = floor(min(16, width / 3))
        let chip = mask.type == .sensitiveData ? "Sensitive data" : "Highlight \(Int((mask.highlightMaskOpacity * 100).rounded()))%"
        TrackItemBody(color: TrackColors.mask, isPlayed: mask.contains(editor.currentSourceTimeMs), isActive: isOpen, isSelected: isOpen)
            .overlay { if isFocused { TrackItemLabels(kind: "Mask", chips: [("rectangle.fill", chip)], width: width) } }
            .overlay(alignment: .leading) { if handle >= 16 && isFocused { resizeHandle(leading: true, width: handle) } }
            .overlay(alignment: .trailing) { if handle >= 16 && isFocused { resizeHandle(leading: false, width: handle) } }
            .frame(width: width, height: height)
            .opacity(mask.isDisabled ? 0.5 : editor.openMaskID != nil && !isOpen ? 0.3 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        guard !editor.isSplitToolActive else { return }
                        let origin = dragOrigin ?? mask
                        if dragOrigin == nil { dragOrigin = mask }
                        editor.moveMask(mask.id, toStart: geometry.sourceTime(from: origin.startMs, movedBy: value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .simultaneousGesture(TapGesture().onEnded {
                if editor.isSplitToolActive, let hoverTimeMs = hoverTimeMs() {
                    if let source = editor.beamSplitSource(startMs: mask.startMs, endMs: mask.endMs, minimumMs: MaskRange.minimumDurationMs, hoverPlaybackMs: editor.project.resolver.sourceToPlayback(hoverTimeMs)) { editor.splitMask(mask.id, at: source) }
                } else {
                    editor.openMask(mask.id)
                }
            })
            .nativeContextMenu(onClose: { editor.menuPreview = nil }) { editor.maskMenu(mask) }
            .offset(x: geometry.sx(mask.startMs) + 1)
    }


    private func resizeHandle(leading: Bool, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: width)
            .overlay {
                Capsule().fill(Color.white).frame(width: 3).padding(.vertical, 9).opacity(hovered ? 1 : 0)
            }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? mask
                        if dragOrigin == nil { dragOrigin = mask }
                        let edge = leading ? origin.startMs : origin.endMs
                        editor.resizeMask(mask.id, leading: leading, to: geometry.sourceTime(from: edge, movedBy: value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}

// MARK: - Camera layouts track

private struct LayoutTrack: View {
    @ObservedObject var editor: EditorModel
    var geometry: TimelineGeometry
    var hoverTimeMs: () -> Double?
    @State private var hoveringTrack = false
    @State private var focusTask: Task<Void, Never>?
    @State private var ghostTimeMs: Double?
    @State private var creation: (start: Double, end: Double)?

    private var isFocused: Bool { editor.focusedTrack == "camera-mode" }

    var body: some View {
        let height: CGFloat = isFocused ? 48 : 16
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Color.white.opacity(0.001))
                .frame(height: height)
                .onContinuousHover { phase in
                    if case .active(let location) = phase, isFocused { ghostTimeMs = geometry.sourceTime(location.x) } else { ghostTimeMs = nil }
                }
                .gesture(createGesture)
.nativeContextMenu { editor.layoutTrackMenu() }
            if isFocused, let range = creation ?? ghostRange {
                let width = max(geometry.sx(range.end) - geometry.sx(range.start) - 1, 1)
                TrackItemBody(color: TrackColors.layout, isPlayed: false, isActive: false, isSelected: false)
                    .opacity(0.5)
                    .overlay { if width > 20 { Image(systemName: "plus").foregroundStyle(.white) } }
                    .frame(width: width, height: 48)
                    .offset(x: geometry.sx(range.start) + 1)
                    .allowsHitTesting(false)
            }
            ForEach(editor.project.cameraLayouts) { layout in
                LayoutItem(editor: editor, layout: layout, geometry: geometry, height: height, isFocused: isFocused, hoverTimeMs: hoverTimeMs)
            }
            if !isFocused {
                Text("Layout")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                    .padding(.leading, 20)
                    .padding(.trailing, 120)
                    .frame(height: 16)
                    .background(LinearGradient(colors: [Theme.Colors.background, Theme.Colors.background.opacity(0)], startPoint: .leading, endPoint: .trailing))
                    .allowsHitTesting(false)
            }
        }
        .frame(height: height)
        .animation(.spring(response: 0.25, dampingFraction: 0.8), value: isFocused)
        .tooltip(isFocused ? "" : "Click to edit")
        .onHover { inside in
            hoveringTrack = inside
            focusTask?.cancel()
            if inside && !isFocused {
                focusTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if !Task.isCancelled && hoveringTrack { editor.focusedTrack = "camera-mode" }
                }
            }
        }
    }

    private var ghostRange: (start: Double, end: Double)? {
        guard let ghostTimeMs, ghostTimeMs >= 0, ghostTimeMs <= editor.project.recording.durationMs,
              let gap = editor.freeLayoutRange(around: ghostTimeMs) else { return nil }
        let start = clamp(ghostTimeMs, gap.start, gap.end)
        let end = min(start + CameraLayoutRange.initialDurationMs, gap.end)
        return end - start >= CameraLayoutRange.minimumDurationMs ? (start, end) : nil
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isFocused else { return }
                let a = geometry.sourceTime(value.startLocation.x)
                let b = geometry.sourceTime(value.location.x)
                if abs(value.translation.width) > 3, let gap = editor.freeLayoutRange(around: a) {
                    creation = (clamp(min(a, b), gap.start, gap.end), clamp(max(a, b), gap.start, gap.end))
                }
            }
            .onEnded { _ in
                guard isFocused else {
                    editor.focusedTrack = "camera-mode"
                    return
                }
                if let creation, creation.end - creation.start >= CameraLayoutRange.minimumDurationMs {
                    editor.addLayout(startMs: creation.start, endMs: creation.end)
                } else if let range = ghostRange {
                    editor.addLayout(startMs: range.start, endMs: range.end)
                }
                creation = nil
            }
    }
}

private struct LayoutItem: View {
    /// Redraws with the playhead (`EditorModel.clock`).
    @EnvironmentObject private var clock: PlaybackClock
    @ObservedObject var editor: EditorModel
    var layout: CameraLayoutRange
    var geometry: TimelineGeometry
    var height: CGFloat
    var isFocused: Bool
    var hoverTimeMs: () -> Double?
    @State private var hovered = false
    @State private var dragOrigin: CameraLayoutRange?

    private var isOpen: Bool { editor.openLayoutID == layout.id }

    /// Chip text per type.
    static func chip(_ type: CameraLayoutType) -> String {
        switch type {
        case .fullscreenCamera: "Fullscreen"
        case .splitScreen: "Split screen"
        case .screenOnly: "Screen only"
        case .cameraOverlay: "Camera overlay"
        case .cutoutCamera: "Camera cutout"
        }
    }

    var body: some View {
        let width = max(geometry.sx(layout.endMs) - geometry.sx(layout.startMs) - 1, 1)
        let handle = floor(min(16, width / 3))
        // Disabled look when disabled or when it changes nothing over the default layout.
        let looksDisabled = layout.isDisabled || editor.project.isEqualToDefaultLayout(layout)
        TrackItemBody(color: TrackColors.layout, isPlayed: layout.contains(editor.currentSourceTimeMs), isActive: isOpen, isSelected: isOpen)
            .overlay { if isFocused { TrackItemLabels(kind: "Layout", chips: [("warninglight", Self.chip(layout.type))], width: width) } }
            .overlay(alignment: .leading) { if handle >= 16 && isFocused { resizeHandle(leading: true, width: handle) } }
            .overlay(alignment: .trailing) { if handle >= 16 && isFocused { resizeHandle(leading: false, width: handle) } }
            .frame(width: width, height: height)
            .opacity(looksDisabled ? 0.5 : editor.openLayoutID != nil && !isOpen ? 0.3 : 1)
            .contentShape(RoundedRectangle(cornerRadius: 10))
            .onHover { hovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 3, coordinateSpace: .global)
                    .onChanged { value in
                        guard !editor.isSplitToolActive else { return }
                        let origin = dragOrigin ?? layout
                        if dragOrigin == nil { dragOrigin = layout }
                        editor.moveLayout(layout.id, toStart: geometry.sourceTime(from: origin.startMs, movedBy: value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .simultaneousGesture(TapGesture().onEnded {
                if editor.isSplitToolActive, let hoverTimeMs = hoverTimeMs() {
                    if let source = editor.beamSplitSource(startMs: layout.startMs, endMs: layout.endMs, minimumMs: CameraLayoutRange.minimumDurationMs, hoverPlaybackMs: editor.project.resolver.sourceToPlayback(hoverTimeMs)) { editor.splitLayout(layout.id, at: source) }
                } else {
                    editor.openLayout(layout.id)
                }
            })
            .nativeContextMenu(onClose: { editor.menuPreview = nil }) { editor.layoutMenu(layout) }
            .offset(x: geometry.sx(layout.startMs) + 1)
    }

    /// Palette [Overlay, Cutout, Fullscreen, Hide camera], split, remove.

    private func setType(_ type: CameraLayoutType) {
        editor.updateLayout(layout.id) { $0.type = type }
    }

    private func resizeHandle(leading: Bool, width: CGFloat) -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.001))
            .frame(width: width)
            .overlay {
                Capsule().fill(Color.white).frame(width: 3).padding(.vertical, 9).opacity(hovered ? 1 : 0)
            }
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let origin = dragOrigin ?? layout
                        if dragOrigin == nil { dragOrigin = layout }
                        let edge = leading ? origin.startMs : origin.endMs
                        editor.resizeLayout(layout.id, leading: leading, to: geometry.sourceTime(from: edge, movedBy: value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }
}

/// Split tool cursor: scissors with the hotspot at 16,16 of a 32 pt image. Drawn from the
/// `scissors` symbol.
enum SplitCursor {
    static let cursor: NSCursor = {
        let size = NSSize(width: 32, height: 32)
        let image = NSImage(size: size, flipped: false) { rect in
            let config = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
            guard let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return false }
            let s = symbol.size
            let frame = NSRect(x: rect.midX - s.width / 2, y: rect.midY - s.height / 2, width: s.width, height: s.height)
            // White outline under the black symbol so it reads on any background.
            for dx in [-1.0, 1.0] { for dy in [-1.0, 1.0] { tinted(symbol, .white).draw(in: frame.offsetBy(dx: dx, dy: dy)) } }
            tinted(symbol, .black).draw(in: frame)
            return true
        }
        return NSCursor(image: image, hotSpot: NSPoint(x: 16, y: 16))
    }()

    private static func tinted(_ image: NSImage, _ color: NSColor) -> NSImage {
        let copy = NSImage(size: image.size, flipped: false) { rect in
            image.draw(in: rect)
            color.set()
            rect.fill(using: .sourceAtop)
            return true
        }
        return copy
    }
}

extension Color {
    /// `color(c).darken(r)`: HSL lightness scaled by 1 − r.
    func darken(_ ratio: Double) -> Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let l = (max(c.redComponent, c.greenComponent, c.blueComponent) + min(c.redComponent, c.greenComponent, c.blueComponent)) / 2
        return lightness(-Double(l) * ratio * 100)
    }

    /// `color(c).lightness(l + n)`: HSL lightness raised by `n` percentage points.
    func lightness(_ n: Double) -> Color {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .black
        let r = Double(c.redComponent), g = Double(c.greenComponent), b = Double(c.blueComponent)
        let maxV = max(r, g, b), minV = min(r, g, b)
        var h = 0.0, sat = 0.0
        let l = (maxV + minV) / 2
        let d = maxV - minV
        if d > 0 {
            sat = d / (1 - abs(2 * l - 1))
            if maxV == r { h = ((g - b) / d).truncatingRemainder(dividingBy: 6) } else if maxV == g { h = (b - r) / d + 2 } else { h = (r - g) / d + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        let l2 = min(max(l + n / 100, 0), 1)
        let chroma = (1 - abs(2 * l2 - 1)) * sat
        let x = chroma * (1 - abs((h / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = l2 - chroma / 2
        let (r1, g1, b1): (Double, Double, Double) = switch h {
        case ..<60: (chroma, x, 0)
        case ..<120: (x, chroma, 0)
        case ..<180: (0, chroma, x)
        case ..<240: (0, x, chroma)
        case ..<300: (x, 0, chroma)
        default: (chroma, 0, x)
        }
        return Color(.sRGB, red: r1 + m, green: g1 + m, blue: b1 + m, opacity: Double(c.alphaComponent))
    }
}
