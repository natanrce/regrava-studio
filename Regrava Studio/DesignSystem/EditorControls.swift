import AppKit
import RegravaCore
import SwiftUI

// MARK: - Section

/// Optional tertiary title, children 32 px apart, 1 px divider (32 px margins) after
/// every section except the last.
struct SidebarSection<Content: View>: View {
    var title: String?
    var showsDivider = true
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.gap(1)) {
                if let title {
                    Text(title).font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary)
                }
                VStack(alignment: .leading, spacing: Theme.gap(3)) { content() }
            }
            if showsDivider {
                Rectangle().fill(Color.white.opacity(0.04)).frame(height: 1).padding(.vertical, 32)
            }
        }
    }
}

/// Nested panel: backgroundAccent.hover, padding 20, radius 20, gap ≈22.6.
struct NestedPanel<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(2.5)) { content() }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 20).fill(Theme.Colors.backgroundAccentHover))
    }
}

// MARK: - Slider

/// 3 px track (5 px on hover), 20 px knob, value preview under the knob on hover,
/// optional Reset button and suggested values.
struct RSSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.001
    var preview: ((Double) -> String)?
    var resetValue: Double?
    var suggestedValues: [Double] = []
    var inverted = false
    /// `primary` (default) or `secondary` (#888) colours.
    var isSecondary = false
    var onEditingChanged: (Bool) -> Void = { _ in }

    @State private var hovered = false
    @State private var dragging = false

    private func fraction(_ v: Double) -> Double {
        let f = (v - range.lowerBound) / max(range.upperBound - range.lowerBound, .ulpOfOne)
        return inverted ? 1 - f : f
    }

    private func value(at fraction: Double) -> Double {
        let f = inverted ? 1 - fraction : fraction
        let raw = range.lowerBound + clamp(f, 0, 1) * (range.upperBound - range.lowerBound)
        return clamp((raw / step).rounded() * step, range.lowerBound, range.upperBound)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(1)) {
            HStack(spacing: Theme.gap(1)) {
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let f = fraction(value)
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.white.opacity(0.1)).frame(height: hovered || dragging ? 5 : 3)
                        // Range in primary, thumb in primary.activeText (kind primary).
                        Capsule().fill(isSecondary ? Color(hex: 0x888888) : Theme.Colors.primary).frame(width: max(width * f, 0), height: hovered || dragging ? 5 : 3)
                        Circle()
                            // activeText of #888 is lightness −20 → #555.
                            .fill(isSecondary ? Color(hex: 0x555555) : Theme.Colors.primaryActiveText)
                            .shadow(color: .black.opacity(0.3), radius: 2, y: 1)
                            .frame(width: 20, height: 20)
                            .offset(x: (width - 20) * f)
                    }
                    .frame(height: 20)
                    .overlay(alignment: .topLeading) {
                        if let preview, hovered || dragging {
                            Text(preview(value))
                                .font(Theme.Typo.label.monospacedDigit())
                                .padding(.horizontal, 4)
                                .padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Colors.background))
                                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0x11 / 255)))
                                .fixedSize()
                                .position(x: (width - 20) * f + 10, y: 36)
                                .allowsHitTesting(false)
                        }
                    }
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { gesture in
                                if !dragging { dragging = true; onEditingChanged(true) }
                                value = self.value(at: (gesture.location.x - 10) / max(width - 20, 1))
                            }
                            .onEnded { _ in dragging = false; onEditingChanged(false) }
                    )
                }
                .frame(minWidth: 40)
                .frame(height: 20)
                .onHover { hovered = $0 }
                if let resetValue {
                    Button("Reset") { value = resetValue }
                        .buttonStyle(RSButtonStyle(kind: .secondary, size: .small))
                        .disabled(abs(value - resetValue) < .ulpOfOne)
                }
            }
            if !suggestedValues.isEmpty {
                HStack(spacing: Theme.gap(0)) {
                    ForEach(suggestedValues, id: \.self) { suggestion in
                        Button(preview?(suggestion) ?? String(format: "%g", suggestion)) { value = suggestion }
                            .buttonStyle(RSButtonStyle(kind: abs(value - suggestion) < .ulpOfOne ? .subtle : .secondaryInline, size: .small))
                    }
                }
            }
        }
    }
}

/// Named slider row used across the sidebar.
struct SliderField: View {
    var name: String
    var icon: String?
    var description: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 0.001
    var preview: ((Double) -> String)?
    var resetValue: Double?
    var suggestedValues: [Double] = []
    var badge: (icon: String, tooltip: String)?

    var body: some View {
        NamedField(name: name, icon: icon, description: description, badge: badge) {
            RSSlider(value: $value, range: range, step: step, preview: preview, resetValue: resetValue, suggestedValues: suggestedValues)
        }
    }
}

// MARK: - Color well

/// Swatch (radius 6) + 7.5ch hex field; Enter commits, Escape reverts.
struct ColorWellField: View {
    @Binding var color: RGBA
    @State private var hex = ""

    var body: some View {
        HStack(spacing: Theme.gap(1)) {
            ColorPicker("", selection: Binding(
                get: { Color(.sRGB, red: color.r, green: color.g, blue: color.b, opacity: 1) },
                set: { newValue in
                    if let c = NSColor(newValue).usingColorSpace(.sRGB) {
                        color = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                    }
                }
            ), supportsOpacity: false)
            .labelsHidden()
            .frame(width: 32, height: 26)
            TextField("", text: $hex)
                .textFieldStyle(.plain)
                .font(Theme.Typo.controlCopy.monospaced())
                .frame(width: 70)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
                .onSubmit { if let parsed = RGBA(hexString: hex) { color = parsed } else { hex = color.hexString } }
                .onExitCommand { hex = color.hexString }
        }
        .onAppear { hex = color.hexString }
        .onChange(of: color) { _, newValue in hex = newValue.hexString }
    }
}

// MARK: - 2-D dot picker

/// Draggable 24 px dot over a preview; snaps to 0.5 within 0.015 unless ⌘ is held.
struct DotPicker<Background: View>: View {
    @Binding var point: Vec2
    var aspectRatio: Double
    @ViewBuilder var background: () -> Background
    @State private var dragging = false

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack(alignment: .topLeading) {
                background()
                    .frame(width: size.width, height: size.height)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Circle()
                    .fill(Theme.Colors.primary)
                    .overlay(Circle().strokeBorder(Color.white, lineWidth: 2))
                    .frame(width: 24, height: 24)
                    .shadow(color: .black.opacity(0.4), radius: 3)
                    .offset(x: point.x * size.width - 12, y: point.y * size.height - 12)
                if dragging {
                    Text("Left: \(Int((point.x * 100).rounded()))% — Top: \(Int((point.y * 100).rounded()))%")
                        .font(Theme.Typo.label)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Colors.background.opacity(0.9)))
                        .offset(x: 8, y: 8)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        dragging = true
                        var x = clamp(value.location.x / size.width, 0, 1)
                        var y = clamp(value.location.y / size.height, 0, 1)
                        if !NSEvent.modifierFlags.contains(.command) {
                            if abs(x - 0.5) < 0.015 { x = 0.5 }
                            if abs(y - 0.5) < 0.015 { y = 0.5 }
                        }
                        point = Vec2(x, y)
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .aspectRatio(aspectRatio, contentMode: .fit)
    }
}

// MARK: - Callout

struct Callout: View {
    enum Kind { case warning, secondary }
    var kind: Kind = .warning
    var icon: String? = "exclamationmark.triangle.fill"
    var title: String?
    var message: String

    var body: some View {
        HStack(alignment: .top, spacing: Theme.gap(1)) {
            if let icon { Image(systemName: icon).foregroundStyle(kind == .warning ? Theme.Colors.warning : Theme.Colors.tertiary) }
            VStack(alignment: .leading, spacing: 2) {
                if let title { Text(title).font(Theme.Typo.copy.weight(.semibold)) }
                Text(message).font(Theme.Typo.label).foregroundStyle(Theme.Colors.text.opacity(0.7)).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill((kind == .warning ? Theme.Colors.warning : Color.white).opacity(0.06)))
    }
}
