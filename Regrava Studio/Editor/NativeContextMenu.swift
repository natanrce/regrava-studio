import AppKit
import SwiftUI

// The timeline context menus are AppKit menus with rich rows: commands with an SF Symbol, a
// shortcut, a checkmark, red destructive titles and ⌥ alternates; submenus; sliders and
// palettes that keep the menu open. Rows that can't apply are left out, separators go between
// groups, and destructive rows are gathered in one last group.

enum MenuRow {
    struct Command {
        var title: String
        var icon: String?
        /// Key names ("c", "Meta+d", "Backspace").
        var shortcut: MenuShortcut?
        var isChecked = false
        var isDestructive = false
        /// Shown instead while ⌥ is held.
        var alternate: (title: String, action: () -> Void)?
        var action: () -> Void
    }

    struct PaletteOption {
        var title: String
        var icon: String
        var isSelected: Bool
        /// Pointing at the option previews it; nil = no preview.
        var preview: ((Bool) -> Void)? = nil
        var action: () -> Void
    }

    case command(Command)
    case submenu(title: String, icon: String?, groups: [[MenuRow]])
    /// "Microphone volume" … "100%"; the value snaps to steps of 0.1.
    case slider(title: String, value: Double, range: ClosedRange<Double>, valueLabel: (Double) -> String, onChange: (Double) -> Void)
    case palette([PaletteOption])
}

struct MenuShortcut {
    var key: String
    var modifiers: NSEvent.ModifierFlags = []

    static func plain(_ key: String) -> MenuShortcut { MenuShortcut(key: key) }
    static func command(_ key: String) -> MenuShortcut { MenuShortcut(key: key, modifiers: .command) }
    static let delete = MenuShortcut(key: "\u{8}")
}

enum NativeContextMenu {
    /// Groups in order; empty groups are skipped, destructive commands move to a last group.
    static func build(_ groups: [[MenuRow]], onClose: (() -> Void)? = nil) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        if let onClose {
            let delegate = MenuCloseDelegate(onClose)
            menu.delegate = delegate
            objc_setAssociatedObject(menu, &MenuCloseDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN)
        }
        var regular: [[MenuRow]] = []
        var destructive: [MenuRow] = []
        for group in groups {
            var kept: [MenuRow] = []
            for row in group {
                if case .command(let c) = row, c.isDestructive { destructive.append(row) } else { kept.append(row) }
            }
            if !kept.isEmpty { regular.append(kept) }
        }
        if !destructive.isEmpty { regular.append(destructive) }
        for (index, group) in regular.enumerated() {
            if index > 0 { menu.addItem(.separator()) }
            for row in group { add(row, to: menu) }
        }
        return menu
    }

    private static func add(_ row: MenuRow, to menu: NSMenu) {
        switch row {
        case .command(let command):
            menu.addItem(item(command.title, icon: command.icon, shortcut: command.shortcut, checked: command.isChecked, destructive: command.isDestructive, action: command.action))
            if let alternate = command.alternate {
                let alt = item(alternate.title, icon: command.icon, shortcut: command.shortcut, checked: false, destructive: command.isDestructive, action: alternate.action)
                alt.keyEquivalentModifierMask.insert(.option)
                alt.isAlternate = true
                menu.addItem(alt)
            }
        case .submenu(let title, let icon, let groups):
            let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            parent.image = icon.flatMap(symbol)
            let sub = NSMenu()
            sub.autoenablesItems = false
            for (index, group) in groups.enumerated() where !group.isEmpty {
                if index > 0 && !sub.items.isEmpty { sub.addItem(.separator()) }
                for row in group { add(row, to: sub) }
            }
            parent.submenu = sub
            menu.addItem(parent)
        case .slider(let title, let value, let range, let label, let onChange):
            let item = NSMenuItem()
            item.view = SliderRowView(title: title, value: value, range: range, valueLabel: label, onChange: onChange)
            menu.addItem(item)
        case .palette(let options):
            guard options.count > 1 else { return }
            let item = NSMenuItem()
            item.view = PaletteRowView(options: options)
            menu.addItem(item)
        }
    }

    private static func symbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private static func item(_ title: String, icon: String?, shortcut: MenuShortcut?, checked: Bool, destructive: Bool, action: @escaping () -> Void) -> NSMenuItem {
        let item = NativeMenuCommandItem(title: title, action: action)
        item.image = icon.flatMap(symbol)
        if let shortcut {
            item.keyEquivalent = shortcut.key
            item.keyEquivalentModifierMask = shortcut.modifiers
        }
        item.state = checked ? .on : .off
        if destructive {
            item.attributedTitle = NSAttributedString(string: title, attributes: [.foregroundColor: NSColor.systemRed, .font: NSFont.menuFont(ofSize: 0)])
            if let image = item.image {
                item.image = image.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.systemRed]))
            }
        }
        return item
    }

    /// Opens `menu` at the pointer in `view`.
    static func popUp(_ menu: NSMenu, event: NSEvent, in view: NSView) {
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }
}

private final class MenuCloseDelegate: NSObject, NSMenuDelegate {
    nonisolated(unsafe) static var key = 0
    let onClose: () -> Void
    init(_ onClose: @escaping () -> Void) { self.onClose = onClose }
    func menuDidClose(_ menu: NSMenu) { onClose() }
}

private final class NativeMenuCommandItem: NSMenuItem {
    private let handler: () -> Void

    init(title: String, action: @escaping () -> Void) {
        handler = action
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func run() { handler() }
}

/// "A label, the value, and a slider under them, like the Sound menu's volume."
private final class SliderRowView: NSView {
    private let valueField = NSTextField(labelWithString: "")
    private let slider: NSSlider
    private let valueLabel: (Double) -> String
    private let onChange: (Double) -> Void

    init(title: String, value: Double, range: ClosedRange<Double>, valueLabel: @escaping (Double) -> String, onChange: @escaping (Double) -> Void) {
        self.valueLabel = valueLabel
        self.onChange = onChange
        slider = NSSlider(value: value, minValue: range.lowerBound, maxValue: range.upperBound, target: nil, action: nil)
        super.init(frame: NSRect(x: 0, y: 0, width: 280, height: 52))
        let titleField = NSTextField(labelWithString: title)
        titleField.font = .menuFont(ofSize: 0)
        valueField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        valueField.textColor = .secondaryLabelColor
        valueField.alignment = .right
        valueField.stringValue = valueLabel(value)
        slider.isContinuous = true
        slider.target = self
        slider.action = #selector(changed)
        for view in [titleField, valueField, slider] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 22),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            valueField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueField.firstBaselineAnchor.constraint(equalTo: titleField.firstBaselineAnchor),
            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 6),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Snaps to steps of 0.1 and applies on every move.
    @objc private func changed() {
        let value = (slider.doubleValue * 10).rounded() / 10
        valueField.stringValue = valueLabel(value)
        onChange(value)
    }
}

/// "Choices side by side, each a symbol over its name, the chosen one marked. Choosing one
/// leaves the menu open."
private final class PaletteRowView: NSView {
    private var options: [MenuRow.PaletteOption]
    private var buttons: [NSButton] = []

    init(options: [MenuRow.PaletteOption]) {
        self.options = options
        let width = max(280, CGFloat(options.count) * 72 + 28)
        super.init(frame: NSRect(x: 0, y: 0, width: width, height: 64))
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.distribution = .fillEqually
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -4),
        ])
        for (index, option) in options.enumerated() {
            let button = PaletteButton(title: option.title, icon: option.icon)
            button.onHover = { [weak self] inside in self?.options[index].preview?(inside) }
            button.tag = index
            button.target = self
            button.action = #selector(choose(_:))
            buttons.append(button)
            stack.addArrangedSubview(button)
        }
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func choose(_ sender: NSButton) {
        options[sender.tag].preview?(false)
        options[sender.tag].action()
        for i in options.indices { options[i].isSelected = i == sender.tag }
        refresh()
    }

    private func refresh() {
        for (button, option) in zip(buttons, options) {
            (button as? PaletteButton)?.isChosen = option.isSelected
        }
    }
}

private final class PaletteButton: NSButton {
    var isChosen = false { didSet { updateLook() } }
    var onHover: ((Bool) -> Void)?
    private var isHovered = false { didSet { updateLook() } }
    private let symbolName: String

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with event: NSEvent) {
        isHovered = true
        onHover?(true)
    }

    override func mouseExited(with event: NSEvent) {
        isHovered = false
        onHover?(false)
    }

    init(title: String, icon: String) {
        symbolName = icon
        super.init(frame: .zero)
        self.title = title
        image = NSImage(systemSymbolName: icon, accessibilityDescription: title)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 17, weight: .regular))
        imagePosition = .imageAbove
        isBordered = false
        bezelStyle = .regularSquare
        font = .menuFont(ofSize: 0)
        wantsLayer = true
        layer?.cornerRadius = 8
        updateLook()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func updateLook() {
        contentTintColor = isChosen ? .controlAccentColor : .labelColor
        attributedTitle = NSAttributedString(string: title, attributes: [
            .foregroundColor: isChosen ? NSColor.controlAccentColor : NSColor.labelColor,
            .font: NSFont.menuFont(ofSize: 0),
        ])
        layer?.backgroundColor = isChosen ? NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            : isHovered ? NSColor.labelColor.withAlphaComponent(0.08).cgColor : NSColor.clear.cgColor
    }
}

// MARK: - SwiftUI hook

extension View {
    /// Shows the native menu built by `rows` on right click (and ⌃-click).
    func nativeContextMenu(onClose: (() -> Void)? = nil, _ rows: @escaping () -> [[MenuRow]]) -> some View {
        overlay(NativeContextMenuTrigger(rows: rows, onClose: onClose))
    }
}

private struct NativeContextMenuTrigger: NSViewRepresentable {
    var rows: () -> [[MenuRow]]
    var onClose: (() -> Void)?

    func makeNSView(context: Context) -> TriggerView { TriggerView() }

    func updateNSView(_ view: TriggerView, context: Context) {
        view.rows = rows
        view.onClose = onClose
    }

    final class TriggerView: NSView {
        var rows: (() -> [[MenuRow]])?
        var onClose: (() -> Void)?

        /// Only right clicks land here; everything else goes to the SwiftUI content below.
        override func hitTest(_ point: NSPoint) -> NSView? {
            guard let event = NSApp.currentEvent else { return nil }
            let isContextClick = event.type == .rightMouseDown || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
            guard isContextClick, let superview, frame.contains(point) || superview.convert(frame, to: superview).contains(point) else { return nil }
            return super.hitTest(point)
        }

        override func rightMouseDown(with event: NSEvent) { show(event) }

        override func mouseDown(with event: NSEvent) {
            if event.modifierFlags.contains(.control) { show(event) } else { super.mouseDown(with: event) }
        }

        private func show(_ event: NSEvent) {
            guard let rows else { return }
            let menu = NativeContextMenu.build(rows(), onClose: onClose)
            guard !menu.items.isEmpty else { return }
            NativeContextMenu.popUp(menu, event: event, in: self)
        }
    }
}
