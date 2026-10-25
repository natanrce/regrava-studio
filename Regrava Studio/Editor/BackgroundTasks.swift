import AppKit
import Combine
import SwiftUI

/// The editor's background tasks (`view.tasks`): each has a name and maybe a progress; one
/// registered with `showAfterMs` stays hidden until then, and longer when its progress says it
/// ends within a second.
@MainActor
final class BackgroundTasks: ObservableObject {
    struct Task: Identifiable {
        let key: Int
        let id: String
        var name: String
        var progress01: Double?
        var visible: Bool
        var identity: Int { key }
    }

    @Published private(set) var tasks: [Task] = []
    private var nextKey = 0
    private static let minShownMs = 1000.0

    var shown: [Task] { tasks.filter(\.visible) }
    var hasTasks: Bool { !shown.isEmpty }

    func isRunning(_ id: String) -> Bool { tasks.contains { $0.id == id } }

    /// `registerTask(promise, name, id, {showAfterMsHint})`.
    func register(_ id: String, name: String, showAfterMs: Double? = nil, progress01: Double? = nil) {
        guard !isRunning(id) else { return }
        let key = nextKey
        nextKey += 1
        tasks.append(Task(key: key, id: id, name: name, progress01: progress01, visible: showAfterMs == nil))
        guard let showAfterMs else { return }
        let startProgress = progress01 ?? 0
        let start = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + showAfterMs / 1000) { [weak self] in
            guard let self, let index = self.tasks.firstIndex(where: { $0.key == key }) else { return }
            // The time left at the current pace; under a second, wait one more second.
            var remaining: Double?
            if let p = self.tasks[index].progress01, p > startProgress {
                remaining = (1 - p) / (p - startProgress) * Date().timeIntervalSince(start) * 1000
            }
            if let remaining, remaining < Self.minShownMs {
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.minShownMs / 1000) { [weak self] in self?.show(key) }
            } else {
                self.show(key)
            }
        }
    }

    private func show(_ key: Int) {
        guard let index = tasks.firstIndex(where: { $0.key == key }) else { return }
        tasks[index].visible = true
    }

    func update(_ id: String, progress01: Double?) {
        guard let index = tasks.firstIndex(where: { $0.id == id }), tasks[index].progress01 != progress01 else { return }
        tasks[index].progress01 = progress01
    }

    func finish(_ id: String) {
        tasks.removeAll { $0.id == id }
    }
}

/// A divider and a spinner button, 300 ms after a task is shown, opening a 320 px list of the tasks.
struct BackgroundTasksIndicator: View {
    @ObservedObject var tasks: BackgroundTasks
    @State private var isShown = false
    @State private var isOpen = false

    var body: some View {
        Group {
            if tasks.hasTasks && isShown {
                HStack(spacing: Theme.gap(1)) {
                    Rectangle().fill(Theme.Colors.systemBorder.opacity(0.6)).frame(width: 1, height: 24)
                    Button { isOpen.toggle() } label: {
                        ProgressView().controlSize(.small)
                            .frame(width: 46, height: 38)
                            .background(RoundedRectangle(cornerRadius: 6).fill(RSButtonKind.subtle.background(hovered: false, pressed: false)).opacity(isOpen ? 1 : 0))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .tooltip(isOpen ? nil : "Background tasks")
                    .popover(isPresented: $isOpen, arrowEdge: .bottom) {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(tasks.shown, id: \.key) { BackgroundTaskRow(task: $0) }
                        }
                        .padding(.vertical, 6)
                        .frame(width: 320)
                        .environment(\.colorScheme, .dark)
                    }
                }
                .transition(.opacity)
            }
        }
        // Shown 300 ms after there are tasks, hidden at once.
        .task(id: tasks.hasTasks) {
            if tasks.hasTasks {
                try? await _Concurrency.Task.sleep(nanoseconds: 300_000_000)
                if tasks.hasTasks { isShown = true }
            } else {
                isShown = false
                isOpen = false
            }
        }
    }
}

/// One task: a spinner, the name, and its progress as a 56 px bar and a percentage.
private struct BackgroundTaskRow: View {
    var task: BackgroundTasks.Task

    var body: some View {
        HStack(spacing: Theme.gap(1) * 1.5) {
            ProgressView().controlSize(.mini)
                .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
            Text(task.name)
                .font(Theme.Typo.controlCopy)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let progress = task.progress01 {
                ProgressView(value: min(max(progress, 0), 1))
                    .progressViewStyle(.linear)
                    .frame(width: 56)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(Theme.Typo.label.monospacedDigit())
                    .foregroundStyle(Color.white.opacity(Theme.secondaryOpacity))
                    .frame(minWidth: 32, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .frame(minHeight: 32)
    }
}
