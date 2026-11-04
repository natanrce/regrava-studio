import AppKit
import SwiftUI

/// Finder icons of apps, fetched once per path.
@MainActor
enum FileIcons {
    private static var icons: [String: NSImage] = [:]

    static func icon(forFile path: String) -> NSImage {
        if let icon = icons[path] { return icon }
        let icon = NSWorkspace.shared.icon(forFile: path)
        icons[path] = icon
        return icon
    }
}

/// Builds native menus from an item model: commands with icon/badge/checked/destructive, section
/// headers, submenus, and custom rows for toggles, segmented controls and audio levels. Groups are
/// separated by dividers. Custom rows use standard AppKit controls.
@MainActor
final class MenuBuilder {
    let menu = NSMenu()
    private var currentGroup: String?
    private var hostedViews: [NSView] = []
    /// Rebuilds the items of the open menu (`contextMenu.update`).
    private var rebuild: ((MenuBuilder) -> Void)?

    init() {
        menu.autoenablesItems = false
    }

    /// SF Symbol images, made once per name (menus are rebuilt often).
    private static var symbols: [String: NSImage] = [:]

    static func symbol(_ name: String) -> NSImage? {
        if let image = symbols[name] { return image }
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        symbols[name] = image
        return image
    }

    /// A menu whose items are built again, in place and without closing, after every toggle
    /// and on `refresh()`.
    static func live(_ build: @escaping (MenuBuilder) -> Void) -> MenuBuilder {
        let builder = MenuBuilder()
        builder.rebuild = build
        build(builder)
        return builder
    }

    func refresh() {
        guard let rebuild else { return }
        menu.removeAllItems()
        hostedViews = []
        currentGroup = nil
        rebuild(self)
        alignHostedRows()
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
        if let icon { item.image = Self.symbol(icon) }
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

    func submenu(_ title: String, icon: String? = nil, image: NSImage? = nil, checked: Bool = false, build: (MenuBuilder) -> Void) {
        let child = MenuBuilder()
        build(child)
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        if let icon { item.image = Self.symbol(icon) }
        if let image {
            image.size = NSSize(width: 16, height: 16)
            item.image = image
        }
        item.state = checked ? .on : .off
        item.submenu = child.menu
        menu.addItem(item)
    }

    /// Switch row (`type: "toggle"`).
    func toggle(_ title: String, icon: String? = nil, image: NSImage? = nil, isOn: Bool, enabled: Bool = true, onChange: @escaping (Bool) -> Void) {
        let live = rebuild != nil
        hosted(MenuToggleRow(title: title, icon: icon, image: image, isOn: isOn, onChange: { [weak self] value in
            onChange(value)
            if live { DispatchQueue.main.async { self?.refresh() } }
        }).disabled(!enabled))
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
        hostedViews.append(host)
    }

    /// Gives every custom row the menu's full width so trailing controls line up.
    private func alignHostedRows() {
        let width = max(menu.size.width, hostedViews.map(\.frame.width).max() ?? 0)
        hostedViews.forEach { $0.frame.size.width = width }
    }

    /// Shows the menu under a view (anchored) or at the mouse location. Opens above the
    /// anchor view, left-aligned with it; below it when there is no room above. Without an
    /// anchor, opens at the mouse.
    func popUp(below view: NSView?) {
        alignHostedRows()
        guard let view, let window = view.window else {
            menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
            return
        }
        let gap: CGFloat = 6
        let menuHeight = menu.size.height
        let onScreen = window.convertToScreen(view.convert(view.bounds, to: nil))
        let roomAbove = (window.screen?.visibleFrame.maxY ?? .greatestFiniteMagnitude) - onScreen.maxY
        let above = roomAbove >= menuHeight + gap
        // `at` is the menu's top-left corner in the view's coordinate system.
        let y: CGFloat
        if view.isFlipped {
            y = above ? -(menuHeight + gap) : view.bounds.height + gap
        } else {
            y = above ? view.bounds.height + menuHeight + gap : -gap
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: y), in: view)
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

    /// With auto-enabling menus: whether the item can run now.
    var isAvailable: (() -> Bool)?
    /// Hidden, not greyed out, while unavailable.
    var hidesWhenUnavailable = false
}

extension ClosureMenuItem: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool { isAvailable?() ?? true }
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
    var image: NSImage?
    @State var isOn: Bool
    var onChange: (Bool) -> Void

    var body: some View {
        HStack(spacing: 8) {
            if let image { Image(nsImage: image).resizable().frame(width: 16, height: 16) }
            if let icon { Image(systemName: icon).frame(width: 16) }
            Text(title).font(.system(size: 13))
            Spacer(minLength: 24)
            Toggle("", isOn: Binding(get: { isOn }, set: { isOn = $0; onChange($0) }))
                .toggleStyle(.switch)
                .labelsHidden()
        }
        .padding(.horizontal, 14)
        .frame(height: 28)
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
            .labelsHidden()
            .fixedSize()
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
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

// MARK: - Right click

extension View {
    /// Opens the menu `build` makes at the mouse on right click (and ⌃-click); nil opens nothing.
    func rightClickMenu(_ build: @escaping () -> MenuBuilder?) -> some View {
        overlay(RightClickMenuTrigger(build: build))
    }

    /// Runs `action` on right click (and ⌃-click), in place of a menu.
    func onRightClick(_ action: @escaping () -> Void) -> some View {
        overlay(RightClickMenuTrigger(build: { action(); return nil }))
    }
}

private struct RightClickMenuTrigger: NSViewRepresentable {
    var build: () -> MenuBuilder?

    func makeNSView(context: Context) -> TriggerView { TriggerView() }

    func updateNSView(_ view: TriggerView, context: Context) {
        view.build = build
    }

    final class TriggerView: NSView {
        var build: (() -> MenuBuilder?)?

        /// Only right clicks land here; everything else goes to the SwiftUI content below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard isContextClick else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { show() }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show() } else { super.mouseDown(with: event) }
        }

        private func show() {
            guard let menu = build?(), !menu.menu.items.isEmpty else { return }
            menu.popUp(below: nil)
        }
    }
}
