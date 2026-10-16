import AppKit
import RegravaCore
import SwiftUI

/// Track colours.
enum TrackColors {
    static let clip = Color(hex: 0x93610C)
    static let zoom = Theme.Colors.primary
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
            let geo = TimelineGeometry(width: geometry.size.width, scrollOffsetMs: editor.scrollOffsetMs, pxPerMs: max(geometry.size.width - 40, 1) / editor.visibleDurationMs)
            ZStack(alignment: .topLeading) {
                GridLines(geometry: geo, duration: editor.durationMs).padding(.top, 32)
                VStack(alignment: .leading, spacing: 11.3) {
                    Ruler(geometry: geo, duration: editor.durationMs).frame(height: 20)
                    VStack(alignment: .leading, spacing: 12) {
                        ClipTrack(editor: editor, geometry: geo)
                        ZoomTrack(editor: editor, geometry: geo, hoverTimeMs: hoverX.map { time($0) })
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
        .frame(height: 25 + 20 + 11.3 + 48 + 12 + 48 + 15)
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

struct TimelineGeometry {
    var width: CGFloat
    var scrollOffsetMs: Double
    var pxPerMs: CGFloat

    func x(_ ms: Double) -> CGFloat { EditorTimeline.horizontalPadding + (ms - scrollOffsetMs) * pxPerMs }
    func time(_ x: CGFloat) -> Double { scrollOffsetMs + (x - EditorTimeline.horizontalPadding) / pxPerMs }

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

    var body: some View {
        let start = geometry.x(0)
        let width = max(editor.durationMs * geometry.pxPerMs - 1, 2)
        ZStack(alignment: .topLeading) {
            TrackItemBody(color: TrackColors.clip, isPlayed: true, isActive: false, isSelected: false)
                .frame(width: width, height: 48)
                .overlay(
                    TrackItemLabels(kind: "Clip", chips: [("clock", Self.duration(editor.durationMs)), ("gauge.with.dots.needle.67percent", "1×")], width: width)
                )
                .offset(x: start + 1)
            // Recording flags above the track.
            ForEach(editor.project.markersMs, id: \.self) { marker in
                Image(systemName: "flag.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(TrackColors.clip.mix(with: .white, by: 0.4))
                    .offset(x: geometry.x(marker) - 3, y: -14)
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
                    if case .active(let location) = phase, isFocused { ghostTimeMs = geometry.time(location.x) } else { ghostTimeMs = nil }
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
            let width = max((range.end - range.start) * geometry.pxPerMs - 1, 1)
            TrackItemBody(color: TrackColors.zoom, isPlayed: false, isActive: false, isSelected: false)
                .opacity(0.5)
                .overlay { if width > 20 { Image(systemName: "plus").foregroundStyle(.white) } }
                .frame(width: width, height: 48)
                .overlay(alignment: .top) {
                    if !UserDefaults.standard.bool(forKey: "onboarding.creating-zoom") {
                        BobbingHint(text: "Click or drag to create zoom").offset(y: -38).fixedSize()
                    }
                }
                .offset(x: geometry.x(range.start) + 1)
                .allowsHitTesting(false)
        }
    }

    private var ghostRange: (start: Double, end: Double)? {
        guard let ghostTimeMs, ghostTimeMs >= 0, ghostTimeMs <= editor.durationMs,
              let gap = editor.freeRange(around: ghostTimeMs) else { return nil }
        let start = clamp(ghostTimeMs, gap.start, gap.end)
        let end = min(start + ZoomRange.initialDurationMs, gap.end)
        return end - start >= ZoomRange.minimumDurationMs ? (start, end) : nil
    }

    private var createGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard isFocused else { return }
                let a = geometry.time(value.startLocation.x)
                let b = geometry.time(value.location.x)
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
                    .frame(width: lead * geometry.pxPerMs, height: 48)
                    .offset(x: geometry.x(zoom.startMs - lead))
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
        let width = max(zoom.durationMs * geometry.pxPerMs - 1, 1)
        let handle = floor(min(16, width / 3))
        TrackItemBody(
            color: TrackColors.zoom,
            isPlayed: zoom.contains(editor.currentTimeMs),
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
        .offset(x: geometry.x(zoom.startMs) + 1)
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
                editor.moveZoom(zoom.id, toStart: origin.startMs + value.translation.width / geometry.pxPerMs)
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
                        editor.resizeZoom(zoom.id, leading: leading, to: edge + value.translation.width / geometry.pxPerMs)
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
        Button("Split zoom at current time") { editor.splitZoom(zoom.id, at: editor.currentTimeMs) }
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
