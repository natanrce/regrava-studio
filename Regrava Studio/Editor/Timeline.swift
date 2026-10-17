import AppKit
import RegravaCore
import SwiftUI

/// Track colours.
enum TrackColors {
    static let clip = Color(hex: 0x93610C)
    static let zoom = Theme.Colors.primary
    static let mask = Color(hex: 0x82345A)
}

/// Timeline: ruler, clip track, zoom track, playheads; scroll/zoom/scrub.
struct EditorTimeline: View {
    @ObservedObject var editor: EditorModel
    @State private var hoverX: CGFloat?
    @State private var width: CGFloat = 1
    @State private var wheelMonitor: Any?
    @State private var isHovering = false

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
                        ClipTrack(editor: editor, geometry: geo, hoverPlaybackMs: hoverX.map { time($0) })
                        ZoomTrack(editor: editor, geometry: geo, hoverTimeMs: hoverX.map { geo.sourceTime($0) })
                        // Masks track, only once a mask exists.
                        if !editor.project.masks.isEmpty {
                            MaskTrack(editor: editor, geometry: geo, hoverTimeMs: hoverX.map { geo.sourceTime($0) })
                        }
                    }
                }
                .padding(.top, 25 - 20)
                .padding(.bottom, 15)

                if let hoverX, !editor.isPlaying, !editor.isSplitToolActive {
                    Playhead(color: Color.white.opacity(0x24 / 255 * 2), height: geometry.size.height)
                        .offset(x: hoverX)
                        .opacity(abs(hoverX - x(editor.currentTimeMs)) < 18 ? Double(abs(hoverX - x(editor.currentTimeMs)) / 18) : 1)
                        .allowsHitTesting(false)
                }
                if editor.isSplitToolActive, let hoverX {
                    SplitBeam(height: geometry.size.height).offset(x: hoverX).allowsHitTesting(false)
                }
                Playhead(color: Theme.Colors.primary, height: geometry.size.height)
                    .offset(x: x(editor.currentTimeMs))
                    .allowsHitTesting(false)
            }
            .clipped()
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    isHovering = true
                    hoverX = location.x
                    editor.scrub(to: time(location.x))
                case .ended:
                    isHovering = false
                    hoverX = nil
                    editor.endScrub()
                }
            }
            .onTapGesture { location in
                guard !editor.isSplitToolActive else { return }
                editor.seek(to: time(location.x))
            }
            .onAppear { width = geometry.size.width; installWheelMonitor() }
            .onChange(of: geometry.size.width) { _, newWidth in width = newWidth }
            .onDisappear { if let wheelMonitor { NSEvent.removeMonitor(wheelMonitor) } }
        }
        .frame(height: 25 + 20 + 11.3 + 48 + 12 + 48 + 15 + (editor.project.masks.isEmpty ? 0 : 12 + 48))
    }

    /// Plain wheel pans (dominant axis), ⌘+wheel zooms ±15%, pinch zooms around the pointer.
    private func installWheelMonitor() {
        guard wheelMonitor == nil else { return }
        wheelMonitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) { event in
            guard isHovering else { return event }
            let anchor = hoverX.map { time($0) }
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

/// 1 px line fading toward the bottom, with a teardrop head (12×12, radius 10/10/10/0, −45°).
private struct Playhead: View {
    var color: Color
    var height: CGFloat

    var body: some View {
        ZStack(alignment: .top) {
            Rectangle()
                .fill(LinearGradient(colors: [color, color.opacity(0)], startPoint: .top, endPoint: .bottom))
                .frame(width: 1, height: height)
            UnevenRoundedRectangle(topLeadingRadius: 10, bottomLeadingRadius: 10, bottomTrailingRadius: 0, topTrailingRadius: 10)
                .fill(color)
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(-45))
                .offset(y: 2)
        }
        .frame(width: 12)
        .offset(x: -6)
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
            .fill(LinearGradient(colors: [color, color.mix(with: .white, by: 0.15)], startPoint: .top, endPoint: .bottom))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isActive ? Color.white : color.mix(with: .white, by: isPlayed ? 0.15 : 0.4), lineWidth: 1)
            )
            .shadow(color: color.opacity(isPlayed ? 0.5 : 0), radius: 6)
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
        VStack(alignment: .leading, spacing: 1) {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .allowsHitTesting(false)
    }
}

// MARK: - Clip track

private struct ClipTrack: View {
    @ObservedObject var editor: EditorModel
    var geometry: TimelineGeometry
    var hoverPlaybackMs: Double?

    var body: some View {
        let slices = editor.project.slices
        ZStack(alignment: .topLeading) {
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                SliceItem(editor: editor, slice: slice, index: index, geometry: geometry, hoverPlaybackMs: hoverPlaybackMs)
            }
            // Marks above the track: cut and trim pins, typing suggestions, recording flags.
            ForEach(Array(slices.enumerated()), id: \.element.id) { index, slice in
                CutPins(editor: editor, slices: slices, index: index, geometry: geometry)
            }
            ForEach(editor.project.pendingTypingSuggestions, id: \.startMs) { range in
                TypingSuggestionChip(editor: editor, range: range, geometry: geometry)
            }
            ForEach(editor.project.markersMs.filter { geometry.resolver.isSourceTimePresent($0) }, id: \.self) { marker in
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TrackColors.clip.mix(with: .white, by: 0.4))
                    .offset(x: geometry.sx(marker) - 3, y: -14)
                    .help("Recording flag")
            }
        }
        .frame(height: 48)
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

/// One clip: duration, speed and cursor chips; click opens the slice editor; edges trim.
private struct SliceItem: View {
    @ObservedObject var editor: EditorModel
    var slice: Slice
    var index: Int
    var geometry: TimelineGeometry
    var hoverPlaybackMs: Double?
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
        .overlay { TrackItemLabels(kind: "Clip", chips: chips, width: width) }
        .overlay(alignment: .leading) { if handle >= 16 { trimHandle(.start, width: handle) } }
        .overlay(alignment: .trailing) { if handle >= 16 { trimHandle(.end, width: handle) } }
        .frame(width: width, height: 48)
        .opacity(editor.openSliceID != nil && !isOpen ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .onHover { hovered = $0 }
        .onTapGesture {
            if editor.isSplitToolActive, let hoverPlaybackMs {
                editor.splitSlice(atPlayback: hoverPlaybackMs)
            } else {
                editor.openSlice(slice.id)
            }
        }
        .contextMenu { SliceMenu(editor: editor, slice: slice, index: index) }
        .offset(x: start + 1)
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
                DragGesture(minimumDistance: 1)
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

/// Clip context menu.
private struct SliceMenu: View {
    @ObservedObject var editor: EditorModel
    var slice: Slice
    var index: Int

    var body: some View {
        let slices = editor.project.slices
        Button("Split at current time") { editor.splitSlice(atPlayback: editor.currentTimeMs) }
            .keyboardShortcut("c", modifiers: [])
        if index > 0 { Button("Merge slice with previous") { editor.mergeSlice(slice.id, with: .previous) } }
        if index + 1 < slices.count { Button("Merge slice with next") { editor.mergeSlice(slice.id, with: .next) } }
        if editor.project.sliceHasStartTrim(index) || editor.project.sliceHasEndTrim(index) {
            Button("Reset slice trim") { editor.removeSliceTrim(slice.id) }
        }
        Divider()
        Menu("Set slice speed") {
            ForEach(Slice.speedOptions, id: \.self) { speed in
                Button(ClipTrack.speed(speed)) { editor.setSliceSpeed(slice.id, speed) }
            }
        }
        Button("Apply speed to all slices") { editor.applySpeedToAllSlices(from: slice.id) }
            .disabled(!editor.canApplySpeedToAll(from: slice.id))
        Divider()
        Toggle("Hide mouse cursor", isOn: Binding(
            get: { slice.hideCursor },
            set: { v in editor.updateSlice(slice.id) { $0.hideCursor = v } }
        ))
        Toggle("Disable smooth mouse movement", isOn: Binding(
            get: { slice.disableSmoothMouseMovement },
            set: { v in editor.updateSlice(slice.id) { $0.disableSmoothMouseMovement = v } }
        ))
        if slices.count > 1 {
            Divider()
            Button("Remove slice", role: .destructive) { editor.removeSlice(slice.id) }
                .keyboardShortcut(.delete, modifiers: [])
        }
        Divider()
        Button("Reset trims and cuts for all slices", role: .destructive) { editor.resetAllSlices() }
    }
}

/// Cut and trim pins: a 24 px teardrop with scissors and the cut length; "Undo trim"
/// restores the trimmed time, "Join clips" merges two clips split without a gap.
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
        .help(gap > 1 ? "Undo trim" : "Join clips")
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

    var body: some View {
        let start = geometry.sx(range.startMs)
        let width = max(geometry.sx(range.endMs) - start, 22)
        Button { isOpen = true } label: {
            RoundedRectangle(cornerRadius: 6)
                .fill(TrackColors.clip.mix(with: .black, by: 0.3))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(TrackColors.clip.mix(with: .white, by: 0.3), lineWidth: 1))
                .overlay(Image(systemName: "keyboard").font(.system(size: 10)).foregroundStyle(.white.opacity(0.9)))
                .frame(width: width, height: 16)
        }
        .buttonStyle(.plain)
        .help("Speed up typing")
        .offset(x: start, y: -22)
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
                        RSButton(title: "Apply all suggestions", kind: .subtle, isWide: true) {
                            editor.applyAllTypingSuggestions()
                            isOpen = false
                        }
                        .keyboardShortcut(.return, modifiers: .command)
                        RSButton(title: "Apply suggestion", kind: .primary, isWide: true) {
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
        }
    }
}

// MARK: - Zoom track

private struct ZoomTrack: View {
    @ObservedObject var editor: EditorModel
    var geometry: TimelineGeometry
    var hoverTimeMs: Double?
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
                .contextMenu { trackMenu }

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
        .help(isFocused ? "" : "Click to edit")
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

    @ViewBuilder
    private var trackMenu: some View {
        Button("Enable all zoom ranges") { editor.setAllZooms(disabled: false) }
        Button("Disable all zoom ranges") { editor.setAllZooms(disabled: true) }
        Button("Restore default zoom ranges") { editor.restoreDefaultZooms() }
        Divider()
        Button("Remove all zoom ranges", role: .destructive) { editor.removeZooms(Set(editor.project.zooms.map(\.id))) }
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
    @ObservedObject var editor: EditorModel
    var zoom: ZoomRange
    var geometry: TimelineGeometry
    var height: CGFloat
    var isFocused: Bool
    var hoverTimeMs: Double?
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
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .gesture(moveGesture)
        .simultaneousGesture(TapGesture().onEnded { tap() })
        .contextMenu { itemMenu }
        .offset(x: geometry.sx(zoom.startMs) + 1)
    }

    private func tap() {
        if editor.isSplitToolActive, let hoverTimeMs {
            editor.splitZoom(zoom.id, at: hoverTimeMs)
            return
        }
        if NSEvent.modifierFlags.contains(.command) {
            if editor.selectedZoomIDs.contains(zoom.id) { editor.selectedZoomIDs.remove(zoom.id) } else { editor.selectedZoomIDs.insert(zoom.id) }
        } else {
            editor.openZoom(zoom.id)
        }
    }

    private var moveGesture: some Gesture {
        DragGesture(minimumDistance: 3)
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
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let origin = dragOrigin ?? zoom
                        if dragOrigin == nil { dragOrigin = zoom }
                        let edge = leading ? origin.startMs : origin.endMs
                        editor.resizeZoom(zoom.id, leading: leading, to: geometry.sourceTime(from: edge, movedBy: value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
    }

    @ViewBuilder
    private var itemMenu: some View {
        Button { editor.updateZoom(zoom.id) { $0.presentation = .screen } } label: {
            Label("Classic zoom", systemImage: "arrow.up.left.and.down.right.magnifyingglass")
        }
        Button {} label: { Label("Loupe zoom", systemImage: "sparkle.magnifyingglass") }.disabled(true)
        Divider()
        Menu("Change zoom level") {
            ForEach(Array(EditorShortcuts.zoomLevels.enumerated()), id: \.offset) { index, level in
                Button(String(format: "%g×", level)) { editor.updateZoom(zoom.id) { $0.scale = level } }
                    .keyboardShortcut(KeyEquivalent(Character(String((index + 1) % 10))), modifiers: [])
            }
        }
        Button("Apply zoom level to all other zooms") { editor.applyZoomLevelToAll(from: zoom.id) }
        Divider()
        Button("Split zoom at current time") { editor.splitZoom(zoom.id, at: editor.currentSourceTimeMs) }
            .keyboardShortcut("c", modifiers: [])
        Button("Duplicate zoom") { editor.duplicateZoom(zoom.id) }
            .keyboardShortcut("d", modifiers: .command)
        Button(zoom.isDisabled ? "Enable zoom" : "Disable zoom") { editor.updateZoom(zoom.id) { $0.isDisabled.toggle() } }
            .keyboardShortcut("d", modifiers: [])
        Divider()
        Button("Remove zoom", role: .destructive) { editor.removeZooms([zoom.id]) }
            .keyboardShortcut(.delete, modifiers: [])
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
    var hoverTimeMs: Double?
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
                .contextMenu {
                    Button("Disable all masks") { editor.setAllMasks(disabled: true) }
                        .disabled(!editor.project.masks.contains { !$0.isDisabled })
                    Button("Remove all masks", role: .destructive) { editor.removeMasks(Set(editor.project.masks.map(\.id))) }
                }
            if isFocused, let range = creation ?? ghostRange {
                let width = max(geometry.sx(range.end) - geometry.sx(range.start) - 1, 1)
                TrackItemBody(color: TrackColors.mask, isPlayed: false, isActive: false, isSelected: false)
                    .opacity(0.5)
                    .overlay { if width > 20 { Image(systemName: "plus").foregroundStyle(.white) } }
                    .frame(width: width, height: 48)
                    .help("Click or drag to create a new mask")
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
    @ObservedObject var editor: EditorModel
    var mask: MaskRange
    var geometry: TimelineGeometry
    var height: CGFloat
    var isFocused: Bool
    var hoverTimeMs: Double?
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
                DragGesture(minimumDistance: 3)
                    .onChanged { value in
                        guard !editor.isSplitToolActive else { return }
                        let origin = dragOrigin ?? mask
                        if dragOrigin == nil { dragOrigin = mask }
                        editor.moveMask(mask.id, toStart: geometry.sourceTime(from: origin.startMs, movedBy: value.translation.width))
                    }
                    .onEnded { _ in dragOrigin = nil }
            )
            .simultaneousGesture(TapGesture().onEnded {
                if editor.isSplitToolActive, let hoverTimeMs {
                    editor.splitMask(mask.id, at: hoverTimeMs)
                } else {
                    editor.openMask(mask.id)
                }
            })
            .contextMenu { menu }
            .offset(x: geometry.sx(mask.startMs) + 1)
    }

    @ViewBuilder
    private var menu: some View {
        Button { editor.updateMask(mask.id) { $0.type = .highlight } } label: {
            Label("Highlight", systemImage: "circle.rectangle.filled.pattern.diagonalline")
        }
        Button { editor.updateMask(mask.id) { $0.type = .sensitiveData } } label: {
            Label("Sensitive data", systemImage: "circle.filled.pattern.diagonalline.rectangle")
        }
        Divider()
        Button("Split mask at current time") { editor.splitMask(mask.id, at: editor.currentSourceTimeMs) }
            .keyboardShortcut("c", modifiers: [])
        Button(mask.isDisabled ? "Enable mask" : "Disable mask") { editor.updateMask(mask.id) { $0.isDisabled.toggle() } }
            .keyboardShortcut("d", modifiers: [])
        Divider()
        Button("Remove mask", role: .destructive) { editor.removeMasks([mask.id]) }
            .keyboardShortcut(.delete, modifiers: [])
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
                DragGesture(minimumDistance: 1)
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
