import SwiftUI

// MARK: - Buttons

enum RSButtonKind {
    case primary, secondary, secondaryInline, subtle, subtleBg, transparent, danger, dangerSubtle, success, translucent

    /// Background for idle / hovered. Shades for kinds other than primary, secondary and
    /// transparent are approximations.
    func background(hovered: Bool, pressed: Bool) -> Color {
        let boost = pressed ? 0.16 : hovered ? 0.08 : 0
        switch self {
        case .primary: return Theme.Colors.primary.opacity(pressed ? 0.85 : 1)
        case .secondary: return Color.white.opacity(0x05 / 255 + boost)
        case .secondaryInline: return Color.white.opacity(0.06 + boost)
        case .subtle, .subtleBg: return Color.white.opacity(0.1 + boost)
        case .transparent: return pressed ? Theme.Colors.active : hovered ? Theme.Colors.hover : .clear
        case .danger: return Theme.Colors.danger.opacity(pressed ? 0.85 : 1)
        case .dangerSubtle: return Theme.Colors.danger.opacity(0.14 + boost)
        case .success: return Theme.Colors.success.opacity(pressed ? 0.85 : 1)
        case .translucent: return Color.white.opacity(0.12 + boost)
        }
    }

    var foreground: Color {
        switch self {
        case .dangerSubtle: return Theme.Colors.danger
        default: return Theme.Colors.text
        }
    }

    var hasBorder: Bool { self == .secondary }
}

enum RSButtonSize {
    case small, regular, big, hero

    var box: Theme.Box {
        switch self {
        case .small: return Theme.Boxes.smallControl
        case .regular: return Theme.Boxes.control
        case .big: return Theme.Boxes.largeControl
        case .hero: return Theme.Boxes.heroControl
        }
    }

    var iconSize: CGFloat {
        switch self {
        case .small: return 13
        case .hero: return 18
        default: return 16
        }
    }
}

struct RSButtonStyle: ButtonStyle {
    var kind: RSButtonKind = .secondary
    var size: RSButtonSize = .regular
    var isWide = false
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let box = size.box
        configuration.label
            .font(Theme.Typo.controlCopy)
            .foregroundStyle(kind.foreground)
            .padding(.horizontal, box.paddingX)
            .frame(height: box.height)
            .frame(maxWidth: isWide ? .infinity : nil)
            .background(
                RoundedRectangle(cornerRadius: box.radius)
                    .fill(kind.background(hovered: hovered && isEnabled, pressed: configuration.isPressed))
            )
            .overlay(
                RoundedRectangle(cornerRadius: box.radius)
                    .strokeBorder(kind.hasBorder ? Theme.Colors.systemBorder : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: box.radius))
            .opacity(isEnabled ? 1 : Theme.disabledOpacity)
            .onHover { hovered = $0 }
            .animation(.easeOut(duration: hovered ? 0.075 : 0.3), value: hovered)
    }
}

/// Text button with an optional SF Symbol.
struct RSButton: View {
    var title: String
    var icon: String?
    var kind: RSButtonKind = .secondary
    var size: RSButtonSize = .regular
    var isWide = false
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.gap(1)) {
                if let icon { Image(systemName: icon).font(.system(size: size.iconSize)) }
                Text(title).lineLimit(1)
            }
        }
        .buttonStyle(RSButtonStyle(kind: kind, size: size, isWide: isWide))
    }
}

/// Square icon button (`IconButton`): small 28, regular 38, large 40 (r9), hero 54 (r9).
struct RSIconButton: View {
    enum Size { case small, regular, large, hero, toolbar }

    var icon: String
    var kind: RSButtonKind = .transparent
    var size: Size = .regular
    var tooltip: String?
    var action: () -> Void
    @State private var hovered = false

    private var metrics: (side: CGFloat, width: CGFloat, radius: CGFloat, icon: CGFloat) {
        switch size {
        case .small: return (28, 28, 6, 13)
        case .regular: return (38, 38, 5, 16)
        case .large: return (40, 40, 9, 16)
        case .hero: return (54, 54, 9, 22)
        case .toolbar: return (38, 46, 6, 16)
        }
    }

    var body: some View {
        let m = metrics
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: m.icon))
                .frame(width: m.width, height: m.side)
                .background(RoundedRectangle(cornerRadius: m.radius).fill(kind.background(hovered: hovered, pressed: false)))
                .contentShape(RoundedRectangle(cornerRadius: m.radius))
        }
        .buttonStyle(.plain)
        .foregroundStyle(kind.foreground)
        .onHover { hovered = $0 }
        .help(tooltip ?? "")
    }
}

// MARK: - Switch & toggle row

/// 43.75×25 switch with a white thumb (`0 2px 2px #00000044`). On/off track colors are
/// Approximation: primary when on, white 15% when off.
struct RSSwitch: View {
    @Binding var isOn: Bool
    var isWide = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        let height: CGFloat = 25
        let width = height * 1.75 * (isWide ? 1.15 : 1)
        ZStack(alignment: isOn ? .trailing : .leading) {
            Capsule().fill(isOn ? Theme.Colors.primary : Color.white.opacity(0.15))
            Circle()
                .fill(Color.white)
                .shadow(color: .black.opacity(0x44 / 255), radius: 1, x: 0, y: 2)
                .padding(2)
        }
        .frame(width: width, height: height)
        .contentShape(Capsule())
        .onTapGesture { withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) { isOn.toggle() } }
        .opacity(isEnabled ? 1 : Theme.disabledOpacity)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "On" : "Off")
    }
}

/// Icon + title, tertiary description underneath, switch on the right.
struct ToggleRow: View {
    var icon: String?
    var title: String
    var description: String?
    @Binding var isOn: Bool

    var body: some View {
        HStack(alignment: .center, spacing: Theme.gap(3)) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: Theme.gap(1)) {
                    if let icon { Image(systemName: icon).font(.system(size: 14)) }
                    Text(title).font(Theme.Typo.copy)
                }
                if let description {
                    Text(description)
                        .font(Theme.Typo.label)
                        .foregroundStyle(Theme.Colors.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { isOn.toggle() }
            RSSwitch(isOn: $isOn)
        }
    }
}

// MARK: - Segmented picker

/// Row of options (radius 10). The active option's description shows below; all
/// descriptions share one grid cell so the height never jumps.
struct SegmentedPicker<Value: Hashable>: View {
    var options: [Value]
    var label: (Value) -> String
    var icon: ((Value) -> String?)? = nil
    var description: ((Value) -> String?)? = nil
    var isDisabled: (Value) -> Bool = { _ in false }
    var size: RSButtonSize = .regular
    var descriptionMinLines: Int = 1
    @Binding var selection: Value

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(1)) {
            HStack(spacing: Theme.gap(0)) {
                ForEach(options, id: \.self) { option in
                    SegmentOption(
                        title: label(option),
                        icon: icon?(option) ?? nil,
                        isSelected: option == selection,
                        isDisabled: isDisabled(option),
                        height: size.box.height ?? 38
                    ) { selection = option }
                }
            }
            if let description {
                ZStack(alignment: .topLeading) {
                    ForEach(options, id: \.self) { option in
                        Text(description(option) ?? "")
                            .font(Theme.Typo.label)
                            .foregroundStyle(Theme.Colors.tertiary)
                            .lineLimit(nil)
                            .fixedSize(horizontal: false, vertical: true)
                            .opacity(option == selection ? 1 : 0)
                    }
                    Text(String(repeating: "\n", count: max(descriptionMinLines - 1, 0)))
                        .font(Theme.Typo.label)
                        .hidden()
                }
            }
        }
    }
}

private struct SegmentOption: View {
    var title: String
    var icon: String?
    var isSelected: Bool
    var isDisabled: Bool
    var height: CGFloat
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.gap(1)) {
                if let icon { Image(systemName: icon).font(.system(size: 14)) }
                Text(title).font(Theme.Typo.controlCopy).lineLimit(1)
            }
            .padding(.horizontal, 12)
            .frame(height: height)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(isSelected ? Theme.Colors.active : hovered ? Theme.Colors.hover : Theme.Colors.lighterBg)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(isSelected ? Color.white.opacity(0.25) : .clear, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .foregroundStyle(Theme.Colors.text.opacity(isSelected ? 1 : Theme.secondaryOpacity))
        .disabled(isDisabled)
        .opacity(isDisabled ? Theme.disabledOpacity : 1)
        .onHover { hovered = $0 }
    }
}

// MARK: - Named field

struct NamedField<Content: View>: View {
    var name: String
    var icon: String?
    var description: String?
    var horizontal = false
    var togglable = false
    @State private var isOpen: Bool
    @ViewBuilder var content: () -> Content

    init(
        name: String,
        icon: String? = nil,
        description: String? = nil,
        horizontal: Bool = false,
        togglable: Bool = false,
        defaultOpen: Bool = false,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.name = name
        self.icon = icon
        self.description = description
        self.horizontal = horizontal
        self.togglable = togglable
        _isOpen = State(initialValue: defaultOpen)
        self.content = content
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: Theme.gap(1)) {
                if let icon { Image(systemName: icon).font(.system(size: 14)) }
                Text(name).font(Theme.Typo.copy)
                if togglable {
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.system(size: 11, weight: .semibold))
                        .rotationEffect(.degrees(isOpen ? 180 : 0))
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(0.06)))
                }
            }
            if let description {
                Text(description)
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Colors.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if togglable { withAnimation(.easeOut(duration: 0.2)) { isOpen.toggle() } } }
    }

    var body: some View {
        if horizontal {
            HStack(alignment: .center, spacing: Theme.gap(3)) {
                header.frame(maxWidth: .infinity, alignment: .leading)
                content()
            }
        } else {
            VStack(alignment: .leading, spacing: Theme.gap(1)) {
                header
                if !togglable {
                    content()
                } else if isOpen {
                    VStack(alignment: .leading, spacing: Theme.gap(2.5)) { content() }
                        .padding(20)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 20).fill(Theme.Colors.backgroundAccentHover))
                }
            }
        }
    }
}

// MARK: - Misc

struct RSSeparator: View {
    var body: some View {
        Rectangle().fill(Theme.Colors.separator).frame(height: 1)
    }
}

/// Text field styled (control box, lighterBg + border).
struct RSTextField: View {
    var placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .font(Theme.Typo.controlCopy)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
    }
}
