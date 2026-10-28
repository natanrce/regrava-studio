import SwiftUI

/// Design tokens (dark-only theme).
enum Theme {
    // MARK: Spacing — gap(n) = 4 · 2^n px

    static func gap(_ n: Double = 1) -> CGFloat {
        CGFloat((4 * pow(2, n) * 10).rounded() / 10)
    }

    // MARK: Colors

    enum Colors {
        static let text = Color.white
        static let tertiary = Color.white.opacity(0.4)
        static let background = Color(hex: 0x08090D)
        static let backgroundAccent = Color(hex: 0x13151B)
        static let systemBorder = Color.white.opacity(0x2E / 255)
        static let primary = Color(hex: 0x4D2FF5)
        /// `primary.activeText`: lightness +20.
        static let primaryActiveText = Color(hex: 0xA090FA)
        static let warning = Color(hex: 0xFF9800)
        static let danger = Color(hex: 0xFF453A)
        /// `danger.activeText` (lightness + 20), derived: the transcript's cut preview.
        static let dangerActiveText = Color(hex: 0xFFA6A0)
        static let success = Color(hex: 0x057C31)
        static let lighterBg = Color.white.opacity(0x05 / 255)
        /// "transparent" interactive background: value / hover / active.
        static let hover = Color.white.opacity(0x14 / 255)
        static let active = Color.white.opacity(0x24 / 255)
        static let recordingRed = Color(hex: 0xDF2220)
        static let widgetRed = Color(hex: 0xFF3F3F)
        static let sourceHighlight = Color(hex: 0x4C6AFF)
        /// `common.systemPopover` background.
        static let popover = Color(hex: 0x1E1E1E).opacity(0xCC / 255)
        /// Separators (`lighterBg.active`) — derived shade is an approximation.
        static let separator = Color.white.opacity(0.07)
        /// `backgroundAccent.hover` — derived shade is an approximation.
        static let backgroundAccentHover = Color(hex: 0x1A1D25)
    }

    /// `common.secondary` / `common.tertiary` / `common.disabled` opacities.
    static let secondaryOpacity = 0.55
    static let tertiaryOpacity = 0.3
    static let disabledOpacity = 0.3

    // MARK: Typography. Weights 449 → regular, 650 → semibold.

    enum Typo {
        static let label = Font.system(size: 12, weight: .regular)
        static let copy = Font.system(size: 13, weight: .regular)
        static let controlCopy = Font.system(size: 13, weight: .regular)
        static let largeCopy = Font.system(size: 16, weight: .regular)
        static let subtitle = Font.system(size: 16, weight: .regular)
        static let title = Font.system(size: 20, weight: .semibold)
        static let titleMedium = Font.system(size: 20, weight: .medium)
        static let hero = Font.system(size: 32, weight: .semibold)
        static let controlIconSize: CGFloat = 16
    }

    // MARK: Box presets

    struct Box {
        var height: CGFloat?
        var width: CGFloat?
        var radius: CGFloat
        var paddingX: CGFloat
    }

    enum Boxes {
        static let smallControl = Box(height: 32, radius: 6, paddingX: 12)
        static let control = Box(height: 38, radius: 6, paddingX: 12)
        static let largeControl = Box(height: 40, radius: 6, paddingX: 14)
        static let heroControl = Box(height: 48, radius: 6, paddingX: 20)
        static let squareControl = Box(height: 38, width: 38, radius: 5, paddingX: 14)
        static let smallSquareControl = Box(height: 28, width: 28, radius: 6, paddingX: 8)
        static let toolbar = Box(height: 38, width: 46, radius: 6, paddingX: 12)
        static let badge = Box(height: 22, radius: 50, paddingX: 8)
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
