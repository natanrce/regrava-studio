import Foundation
import SwiftUI

/// A short message over the editor. One shows at a time; a new one replaces it.
struct EditorToast: Identifiable, Equatable {
    enum Kind { case info, error, warning, success }

    static let defaultDurationMs: Double = 5000

    let id = UUID()
    var kind: Kind = .info
    var title: String?
    var message: String
    var durationMs: Double = defaultDurationMs
}

/// Bottom-centred toast, 20 px from the window edges; a click dismisses it.
struct ToastHost: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        ZStack(alignment: .bottom) {
            if let toast = editor.toast {
                ToastLabel(toast: toast)
                    .onTapGesture { editor.dismissToast(toast.id) }
                    .id(toast.id)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .offset(y: 5)),
                        removal: .opacity.combined(with: .offset(y: 5))
                    ))
                    .task(id: toast.id) {
                        try? await Task.sleep(nanoseconds: UInt64(toast.durationMs * 1_000_000))
                        guard !Task.isCancelled else { return }
                        editor.dismissToast(toast.id)
                    }
            }
        }
        .animation(.easeInOut(duration: 0.25), value: editor.toast?.id)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(20)
    }
}

/// Control copy on the system popover, 6 × 12 padding, radius 5; errors, warnings and
/// successes tint the border. A title goes above in weight 600, the message then secondary.
private struct ToastLabel: View {
    let toast: EditorToast

    private var borderColor: Color {
        switch toast.kind {
        case .info: return Theme.Colors.systemBorder
        case .error: return Theme.Colors.danger.opacity(Theme.tertiaryOpacity)
        case .warning: return Theme.Colors.warning.opacity(Theme.tertiaryOpacity)
        case .success: return Theme.Colors.success.opacity(Theme.secondaryOpacity)
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 5)
        VStack(alignment: .leading, spacing: Theme.gap(-1)) {
            if let title = toast.title {
                Text(title).font(Theme.Typo.controlCopy.weight(.semibold))
            }
            Text(toast.message)
                .font(Theme.Typo.controlCopy)
                .opacity(toast.title == nil ? 1 : Theme.secondaryOpacity)
        }
        .frame(minWidth: toast.title == nil ? nil : 240, alignment: .leading)
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(shape.fill(Theme.Colors.popover))
        .background(.ultraThinMaterial, in: shape)
        .overlay(shape.strokeBorder(borderColor))
        .overlay(shape.inset(by: -1).stroke(Color.black.opacity(0x88 / 255), lineWidth: 1))
        .shadow(color: .black.opacity(0x66 / 255), radius: 15)
        .contentShape(shape)
    }
}
