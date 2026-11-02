import AppKit
import Combine
import RegravaCore
import SwiftUI

/// The command menu's sessions: ⌘K opens the root list over a dimmed window; an action with
/// sub-actions replaces it with a nested list (no dimming), and Backspace in an empty search
/// goes back to the parent.
@MainActor
final class CommandMenuController: ObservableObject {
    final class Session {
        let actions: [EditorAction]
        let trigger: EditorAction?
        let parent: Session?
        /// The root list dims what is behind it.
        let overlayLayer: Bool
        var keyword = ""

        init(actions: [EditorAction], trigger: EditorAction?, parent: Session?, overlayLayer: Bool) {
            self.actions = actions
            self.trigger = trigger
            self.parent = parent
            self.overlayLayer = overlayLayer
        }

        /// The actions that led here, from the root.
        var breadcrumb: [EditorAction] {
            var chain: [EditorAction] = []
            var session: Session? = self
            while let current = session {
                if let trigger = current.trigger { chain.insert(trigger, at: 0) }
                session = current.parent
            }
            return chain
        }
    }

    @Published private(set) var session: Session?
    /// Every action, for the targets when the menu opens.
    var rootActions: () -> [EditorAction] = { [] }

    func open() {
        session = Session(actions: rootActions(), trigger: nil, parent: nil, overlayLayer: true)
    }

    func toggle() {
        if session == nil { open() } else { close() }
    }

    func close() { session = nil }

    /// Runs an action (from a shortcut or the menu): its sub-actions open as a nested list.
    func execute(_ action: EditorAction) {
        guard action.canApply else { return }
        if let perform = action.perform {
            perform()
        } else if let subActions = action.subActions {
            session = Session(actions: subActions(), trigger: action, parent: session, overlayLayer: false)
        }
    }

    /// Chosen in the menu: the menu closes unless the action opened a nested list.
    func choose(_ action: EditorAction) {
        let current = session
        execute(action)
        if let current, session === current { close() }
    }

    func back() {
        guard let parent = session?.parent else { return }
        session = parent
    }
}

/// Shows the command menu while a session is open.
struct CommandMenuHost: View {
    @ObservedObject var menu: CommandMenuController

    var body: some View {
        if let session = menu.session {
            CommandMenuOverlay(menu: menu, session: session)
                .id(ObjectIdentifier(session))
        }
    }
}

/// Command menu: a 640 px card over the window (dimmed at 0.9 for the root list), the search
/// input, the breadcrumb of a nested list, then the actions grouped by group and visible group.
struct CommandMenuOverlay: View {
    @ObservedObject var menu: CommandMenuController
    let session: CommandMenuController.Session
    @State private var query = ""
    @State private var selection = 0
    @State private var lastKeyboardMove = Date.distantPast
    @FocusState private var focused: Bool

    struct Section {
        var group: String?
        var visibleGroups: [[EditorAction]]
    }

    /// Applicable actions, ranked by the search, those with a group first, then grouped (in
    /// order of appearance) by group and visible group, by priority within a visible group.
    static func sections(_ actions: [EditorAction], query: String) -> [Section] {
        let applicable = actions.filter(\.canApply)
        let ranked = CommandSearch.filter(applicable, query: query) { action in
            [action.name, action.supplementaryLabel ?? "", action.visibleGroup ?? "", action.group ?? ""]
        }
        let ordered = ranked.enumerated().sorted { a, b in
            let aLast = a.element.group == nil, bLast = b.element.group == nil
            return aLast != bLast ? !aLast : a.offset < b.offset
        }.map(\.element)
        var sections: [Section] = []
        var visibleKeys: [[String?]] = []
        for action in ordered {
            let index: Int
            if let found = sections.firstIndex(where: { $0.group == action.group }) {
                index = found
            } else {
                sections.append(Section(group: action.group, visibleGroups: []))
                visibleKeys.append([])
                index = sections.count - 1
            }
            if let visible = visibleKeys[index].firstIndex(where: { $0 == action.visibleGroup }) {
                sections[index].visibleGroups[visible].append(action)
            } else {
                visibleKeys[index].append(action.visibleGroup)
                sections[index].visibleGroups.append([action])
            }
        }
        for s in sections.indices {
            for v in sections[s].visibleGroups.indices {
                sections[s].visibleGroups[v] = sections[s].visibleGroups[v].enumerated()
                    .sorted { $0.element.priority != $1.element.priority ? $0.element.priority > $1.element.priority : $0.offset < $1.offset }
                    .map(\.element)
            }
        }
        return sections
    }

    var body: some View {
        let sections = Self.sections(session.actions, query: query)
        let results = sections.flatMap { $0.visibleGroups.flatMap { $0 } }
        GeometryReader { geometry in
            let top = max(geometry.size.height / 2 - 210, 0)
            let available = max(geometry.size.height - top - 80, 0)
            ZStack(alignment: .top) {
                (session.overlayLayer ? Theme.Colors.background.opacity(0.9) : Color.white.opacity(0.001))
                    .onTapGesture { menu.close() }
                card(sections: sections, results: results)
                    .frame(maxWidth: 640)
                    .frame(maxHeight: session.overlayLayer ? min(420, available) : available, alignment: .top)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 80)
                    .padding(.top, top)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear {
            query = session.keyword
            focused = true
        }
        .onChange(of: query) {
            session.keyword = query
            selection = 0
        }
        .onChange(of: results.count) { selection = 0 }
    }

    private func card(sections: [Section], results: [EditorAction]) -> some View {
        let radius: CGFloat = session.overlayLayer ? 8 : 16
        return VStack(alignment: .leading, spacing: 0) {
            TextField(session.trigger?.inputPlaceholder ?? "Type to find a command", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 18))
                .foregroundStyle(Color(red: 228 / 255, green: 229 / 255, blue: 233 / 255))
                .tint(Theme.Colors.primaryActiveText)
                .padding(20)
                .frame(height: 64)
                .focused($focused)
                .onSubmit { run(results) }
                .onKeyPress(.downArrow) { move(1, count: results.count); return .handled }
                .onKeyPress(.upArrow) { move(-1, count: results.count); return .handled }
                .onKeyPress(.escape) { menu.close(); return .handled }
                .onKeyPress(.delete) {
                    guard query.isEmpty, session.parent != nil else { return .ignored }
                    menu.back()
                    return .handled
                }
            let breadcrumb = session.breadcrumb
            if !breadcrumb.isEmpty {
                HStack(spacing: Theme.gap(1)) {
                    ForEach(Array(breadcrumb.enumerated()), id: \.offset) { index, action in
                        HStack(spacing: Theme.gap(0)) {
                            if let icon = action.icon { Image(systemName: icon) }
                            Text(action.name)
                            if index < breadcrumb.count - 1 {
                                Image(systemName: "chevron.forward").opacity(Theme.tertiaryOpacity / Theme.secondaryOpacity)
                            }
                        }
                    }
                }
                .font(Theme.Typo.label)
                .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                .padding(.horizontal, 20)
            }
            list(sections: sections, results: results)
        }
        .background(
            RoundedRectangle(cornerRadius: radius)
                .fill(Color(hex: 0x1E1E1E).opacity(session.overlayLayer ? 0xCC / 255 : 0xEE / 255))
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius))
        )
        .clipShape(RoundedRectangle(cornerRadius: radius))
        .overlay(
            RoundedRectangle(cornerRadius: radius)
                .strokeBorder(session.overlayLayer ? Color.black.opacity(0x88 / 255) : Color.white.opacity(0x2E / 255))
        )
        .shadow(color: session.overlayLayer ? Color.black.opacity(0x44 / 255) : .clear, radius: 10, x: 3, y: 3)
    }

    private func list(sections: [Section], results: [EditorAction]) -> some View {
        let indices = Dictionary(results.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sections.enumerated()), id: \.offset) { sectionIndex, section in
                        let total = section.visibleGroups.reduce(0) { $0 + $1.count }
                        VStack(alignment: .leading, spacing: 0) {
                            if sectionIndex > 0 {
                                Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.bottom, 12)
                            }
                            if let group = section.group {
                                Text(group)
                                    .font(Theme.Typo.label)
                                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                                    .padding(.horizontal, 20)
                                    .padding(.vertical, 4)
                            }
                            ForEach(Array(section.visibleGroups.enumerated()), id: \.offset) { visibleIndex, actions in
                                VStack(alignment: .leading, spacing: 0) {
                                    // More than 7 actions: lines between the visible groups.
                                    if total > 7 && visibleIndex > 0 {
                                        Rectangle().fill(Color.white.opacity(0.1)).frame(height: 1).padding(.bottom, 8)
                                    }
                                    ForEach(actions) { action in
                                        let index = indices[action.id] ?? 0
                                        row(action, isSelected: index == selection)
                                            .id(index)
                                            .onContinuousHover { phase in
                                                // Hovering selects, except right after a keyboard move.
                                                if case .active = phase, index != selection, Date().timeIntervalSince(lastKeyboardMove) >= 0.1 { selection = index }
                                            }
                                            .onTapGesture { menu.choose(action) }
                                    }
                                }
                                .padding(.top, total > 7 && visibleIndex > 0 ? 8 : 0)
                                .padding(.bottom, 4)
                            }
                        }
                        .padding(.top, sectionIndex > 0 ? 12 : 0)
                    }
                }
                .padding(.top, results.isEmpty ? 0 : 4)
            }
            .overlay(alignment: .top) {
                if !results.isEmpty { Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1) }
            }
            .padding(.bottom, 4)
            .onChange(of: selection) { proxy.scrollTo(selection) }
        }
    }

    private func row(_ action: EditorAction, isSelected: Bool) -> some View {
        HStack(spacing: Theme.gap(2)) {
            Image(systemName: action.icon ?? "arrow.right")
                .font(.system(size: 14))
                .frame(width: 14, height: 14)
            HStack(spacing: Theme.gap()) {
                Text(action.name)
                if let label = action.supplementaryLabel {
                    Text(label).opacity(0.3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if action.isActive {
                Image(systemName: "checkmark")
            }
            if let shortcut = action.shortcutLabel {
                ShortcutBadge(keys: shortcut)
            }
        }
        .font(Theme.Typo.copy)
        .lineLimit(1)
        .padding(.horizontal, 16)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 6).fill(isSelected ? Color.white.opacity(0.05) : .clear))
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }

    /// ↑ / ↓ stop at the ends.
    private func move(_ delta: Int, count: Int) {
        guard count > 0 else { return }
        lastKeyboardMove = Date()
        selection = min(max(selection + delta, 0), count - 1)
    }

    private func run(_ results: [EditorAction]) {
        guard results.indices.contains(selection) else { return }
        menu.choose(results[selection])
    }
}

/// Key badge: the shortcut's keys in a small bordered box.
struct ShortcutBadge: View {
    var keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 12, weight: .medium))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.white.opacity(0x2E / 255)))
    }
}
