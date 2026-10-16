import AppKit
import SwiftUI

/// Floating recording controls.
struct RecordingWidgetView: View {
    @ObservedObject var coordinator: RecordingCoordinator

    var body: some View {
        ZStack {
            HStack(spacing: Theme.gap(0)) {
                StopTimerButton(elapsed: coordinator.elapsed) { coordinator.requestFinish() }
                PanelDivider(verticalMargin: 8, opacity: 0.15)
                HStack(spacing: Theme.gap(1)) {
                    if coordinator.phase == .paused {
                        RSIconButton(icon: "play.circle") { coordinator.resume() }
                    } else {
                        RSIconButton(icon: "pause.circle") { coordinator.pause() }
                    }
                    RSIconButton(icon: "arrow.counterclockwise") { coordinator.requestRestart() }
                    RSIconButton(icon: "trash") { coordinator.requestCancel() }
                }
            }
            .disabled(coordinator.isWorking)
            .opacity(coordinator.showsWorking ? 0.05 : 1)
            .padding(.horizontal, 5)

            if coordinator.showsWorking {
                HStack(spacing: Theme.gap(1)) {
                    ProgressView().controlSize(.small)
                    Text("Working...").font(Theme.Typo.copy).opacity(Theme.secondaryOpacity)
                }
            }
            if coordinator.flagFlash {
                HStack(spacing: Theme.gap(1)) {
                    Image(systemName: "flag")
                    Text("Flag added")
                }
                .font(Theme.Typo.copy)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.Colors.background.opacity(0.9))
                .transition(.opacity)
            }
        }
        .frame(height: 48)
        .foregroundStyle(Theme.Colors.text)
        .animation(.easeOut(duration: 0.15), value: coordinator.flagFlash)
        .contextMenu {
            Button {
                coordinator.preferences.showRecordingWidget.toggle()
            } label: {
                if coordinator.preferences.showRecordingWidget {
                    Label("Show recording widget", systemImage: "checkmark")
                } else {
                    Text("Show recording widget")
                }
            }
        }
    }
}

/// `stop.circle` + timer in #ff3f3f, control box (38 tall, radius 6), grows to fill the row.
private struct StopTimerButton: View {
    var elapsed: TimeInterval
    var action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Theme.gap(1)) {
                Image(systemName: "stop.circle").font(.system(size: 16))
                ZStack(alignment: .leading) {
                    // Invisible placeholder keeps the width stable.
                    Text(Self.placeholder(for: elapsed)).hidden()
                    Text(Self.format(elapsed))
                }
                .font(Theme.Typo.controlCopy.monospacedDigit())
                Spacer(minLength: 0)
            }
            .foregroundStyle(Theme.Colors.widgetRed)
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(hovered ? Theme.Colors.hover : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }

    /// m:ss, or h:mm:ss from one hour.
    static func format(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 3600 { return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    static func placeholder(for seconds: TimeInterval) -> String {
        let s = Int(seconds)
        if s >= 36000 { return "00:00:00" }
        if s >= 3600 { return "0:00:00" }
        if s >= 600 { return "00:00" }
        return "0:00"
    }
}
