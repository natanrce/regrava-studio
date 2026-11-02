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

/// Command menu: full-window overlay at 0.9, a 640 px card (#1e1e1eee, 1 px
/// #ffffff2e, radius 16), 64 px input "Type to find a command".
struct CommandMenuOverlay: View {
    @ObservedObject var menu: CommandMenuController
    let session: CommandMenuController.Session
    @State private var query = ""
    @State private var selection = 0
    @FocusState private var focused: Bool

    /// Matching actions, grouped (in definition order) and sorted by name within each group.
    private var sections: [(group: String, actions: [EditorAction])] {
        let words = query.lowercased().split(separator: " ")
        // Actions that cannot apply right now are not listed.
        let matching = session.actions.filter { action in
            guard action.canApply else { return false }
            let text = (action.name + " " + (action.group ?? "")).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
        var order: [String] = []
        for action in matching where !order.contains(action.group ?? "") { order.append(action.group ?? "") }
        return order.map { group in
            (group, matching.filter { ($0.group ?? "") == group }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending })
        }
    }

    private var results: [EditorAction] { sections.flatMap(\.actions) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .top) {
                Theme.Colors.background.opacity(0.9)
                    .onTapGesture { close() }
                VStack(spacing: 0) {
                    TextField("Type to find a command", text: $query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 18))
                        .foregroundStyle(Color(red: 228 / 255, green: 229 / 255, blue: 233 / 255))
                        .tint(Theme.Colors.primary)
                        .padding(20)
                        .frame(height: 64)
                        .focused($focused)
                        .onSubmit(run)
                        .onKeyPress(.downArrow) { move(1); return .handled }
                        .onKeyPress(.upArrow) { move(-1); return .handled }
                        .onKeyPress(.escape) { close(); return .handled }
                        .onChange(of: query) { selection = 0 }
                    Rectangle().fill(Color.white.opacity(0x2E / 255)).frame(height: 1)
                    ScrollViewReader { proxy in
                        ScrollView {
                            VStack(alignment: .leading, spacing: 0) {
                                let sections = self.sections
                                // Each row's place in the flat result list (the first one with its id).
                                let indices = sections.flatMap(\.actions).enumerated().reduce(into: [String: Int]()) { indices, entry in
                                    if indices[entry.element.id] == nil { indices[entry.element.id] = entry.offset }
                                }
                                ForEach(sections, id: \.group) { section in
                                    Text(section.group)
                                        .font(Theme.Typo.copy)
                                        .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                                        .padding(.horizontal, 20)
                                        .padding(.top, 12)
                                        .padding(.bottom, 6)
                                    ForEach(section.actions) { action in
                                        let index = indices[action.id] ?? 0
                                        row(action, isSelected: index == selection)
                                            .id(index)
                                            .onTapGesture {
                                                selection = index
                                                run()
                                            }
                                    }
                                }
                            }
                            .padding(.bottom, 8)
                        }
                        .frame(maxHeight: 360)
                        .onChange(of: selection) { proxy.scrollTo(selection) }
                    }
                }
                .frame(maxWidth: 640)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(Color(hex: 0x1E1E1E).opacity(0xEE / 255))
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                )
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.white.opacity(0x2E / 255)))
                .padding(.horizontal, 80)
                .padding(.top, max(geometry.size.height / 2 - 210, 80))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .onAppear { focused = true }
    }

    private func row(_ action: EditorAction, isSelected: Bool) -> some View {
        HStack(spacing: 0) {
            Image(systemName: action.icon ?? "arrow.right")
                .font(.system(size: 15))
                .frame(width: 22)
                .padding(.trailing, 14)
            Text(action.name).font(.system(size: 14))
            Spacer()
            if let shortcut = action.shortcutLabel {
                ShortcutBadge(keys: shortcut)
            }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(RoundedRectangle(cornerRadius: 8).fill(isSelected ? Color.white.opacity(0.06) : .clear))
        .padding(.horizontal, 8)
        .opacity(action.canApply ? 1 : Theme.disabledOpacity)
        .contentShape(Rectangle())
    }

    private func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    private func run() {
        guard results.indices.contains(selection) else { return }
        menu.choose(results[selection])
    }

    private func close() {
        menu.close()
    }
}

/// Key badge: the shortcut's keys in a small bordered box.
struct ShortcutBadge: View {
    var keys: String

    var body: some View {
        Text(keys)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(0.03)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.white.opacity(0x2E / 255)))
    }
}
