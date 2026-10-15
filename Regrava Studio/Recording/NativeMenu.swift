import AppKit
import SwiftUI

/// Builds native menus from an item model: commands with icon/badge/checked/destructive, section
/// headers, submenus, and custom rows for toggles, segmented controls and audio levels. Groups are
/// separated by dividers. Custom rows use standard AppKit controls.
@MainActor
final class MenuBuilder {
    let menu = NSMenu()
    private var currentGroup: String?

    init() {
        menu.autoenablesItems = false
    }

    /// Starts a group; a separator is inserted when the group changes.
    func group(_ name: String) {
        if let currentGroup, currentGroup != name, !menu.items.isEmpty { menu.addItem(.separator()) }
        currentGroup = name
    }

    func header(_ title: String) {
        menu.addItem(NSMenuItem.sectionHeader(title: title))
    }

    @discardableResult
    func item(
        _ title: String,
        icon: String? = nil,
        image: NSImage? = nil,
        badge: String? = nil,
        checked: Bool = false,
        enabled: Bool = true,
        destructive: Bool = false,
        shortcut: KeyShortcut? = nil,
        action: (() -> Void)? = nil
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, action: action)
        if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        if let image {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        if let badge { item.badge = NSMenuItemBadge(string: badge) }
        item.state = checked ? .on : .off
        item.isEnabled = enabled && action != nil
        if destructive {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed])
        }
        if let shortcut { item.apply(shortcut) }
        menu.addItem(item)
        return item
    }

    func disabled(_ title: String) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    func submenu(_ title: String, icon: String? = nil, build: (MenuBuilder) -> Void) {
        let child = MenuBuilder()
        build(child)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let icon { item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil) }
        item.submenu = child.menu
        menu.addItem(item)
    }

    /// Switch row (`type: "toggle"`).
    func toggle(_ title: String, icon: String? = nil, isOn: Bool, enabled: Bool = true, onChange: @escaping (Bool) -> Void) {
        hosted(MenuToggleRow(title: title, icon: icon, isOn: isOn, onChange: onChange).disabled(!enabled))
    }

    /// Inline segmented control (`type: "segmented"`).
    func segmented(_ title: String, options: [String], selected: Int, onSelect: @escaping (Int) -> Void) {
        hosted(MenuSegmentedRow(title: title, options: options, selected: selected, onSelect: onSelect))
    }

    /// Audio level meter row (`type: "level"`).
    func level(_ monitor: MicrophoneLevelMonitor) {
        hosted(MenuLevelRow(monitor: monitor))
    }

    private func hosted<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view.environment(\.colorScheme, .dark))
        host.frame.size = host.fittingSize
        host.frame.size.width = max(host.frame.width, 260)
        let item = NSMenuItem()
        item.view = host
        menu.addItem(item)
    }

    /// Shows the menu under a view (anchored) or at the mouse location.
    func popUp(below view: NSView?) {
        if let view {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: view.bounds.height + 4), in: view)
        } else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let handler: (() -> Void)?

    init(title: String, action: (() -> Void)?) {
        handler = action
        super.init(title: title, action: action == nil ? nil : #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler?() }
}

extension NSMenuItem {
    func apply(_ shortcut: KeyShortcut) {
        keyEquivalent = shortcut.menuKeyEquivalent
        var mask: NSEvent.ModifierFlags = []
        if shortcut.command { mask.insert(.command) }
        if shortcut.control { mask.insert(.control) }
        if shortcut.option { mask.insert(.option) }
        if shortcut.shift { mask.insert(.shift) }
        keyEquivalentModifierMask = mask
    }
}

extension KeyShortcut {
    /// Key equivalent string for NSMenuItem.
    var menuKeyEquivalent: String {
        switch keyCode {
        case 36: return "\r"
        case 51: return "\u{8}"
        case 53: return "\u{1b}"
        default: return key.lowercased()
        }
    }
}

// MARK: - Custom rows

private struct MenuToggleRow: View {
    var title: String
    var icon: String?
    @State var isOn: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let icon { Image(systemName: icon).frame(width: 16) }
            Text(title).font(.system(size: 13))
            Spacer(minLength: 16)
            Toggle("", isOn: Binding(get: { isOn }, set: { isOn = $0; onChange($0) }))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct MenuSegmentedRow: View {
    var title: String
    var options: [String]
    @State var selected: Int
    var onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.system(size: 13))
            Spacer(minLength: 16)
            Picker("", selection: Binding(get: { selected }, set: { selected = $0; onSelect($0) })) {
                ForEach(options.indices, id: \.self) { Text(options[$0]).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
    }
}

private struct MenuLevelRow: View {
    @ObservedObject var monitor: MicrophoneLevelMonitor

    var body: some View {
        LevelBar(level: monitor.level, peak: monitor.peak)
            .frame(height: 3)
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
    }
}

/// 3px track (radius 10, text@0.05) with peak (text@0.1) and level (tertiary) fills,
/// width mapped from 2.3% to 100%.
struct LevelBar: View {
    var level: Double
    var peak: Double

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.05))
                Capsule().fill(Color.white.opacity(0.1)).frame(width: width * (0.023 + 0.977 * peak))
                Capsule().fill(Theme.Colors.tertiary).frame(width: width * (0.023 + 0.977 * level))
            }
        }
    }
}
