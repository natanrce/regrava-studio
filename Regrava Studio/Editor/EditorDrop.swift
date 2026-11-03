import AppKit
import Foundation
import RegravaCore
import SwiftUI
import UniformTypeIdentifiers

/// Files dropped anywhere on the editor window: audio becomes the background audio, a
/// project opens. While matching files are dragged over the window a black cover names
/// what the drop will do.
struct EditorDropModifier: ViewModifier {
    let editor: EditorModel
    @State private var label: String?

    func body(content: Content) -> some View {
        content
            .onDrop(of: [.fileURL], delegate: EditorDropDelegate(editor: editor, label: $label))
            .overlay {
                if let label {
                    HStack(spacing: Theme.gap(1)) {
                        Image(systemName: "arrow.down.document.fill").font(.system(size: Theme.Typo.controlIconSize))
                        Text(label).font(Theme.Typo.copy)
                    }
                    .foregroundStyle(Theme.Colors.text)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .allowsHitTesting(false)
                    .transition(.opacity.animation(.easeInOut(duration: 0.125)))
                }
            }
    }
}

extension View {
    func editorFileDrops(_ editor: EditorModel) -> some View {
        modifier(EditorDropModifier(editor: editor))
    }
}

private struct EditorDropDelegate: DropDelegate {
    /// What a drop of only these kinds of files does.
    enum Kind: CaseIterable {
        case backgroundAudio, project

        var extensions: [String] {
            switch self {
            case .backgroundAudio: return ["mp3", "m4a", "wav"]
            case .project: return [ProjectStore.fileExtension]
            }
        }

        var label: String {
            switch self {
            case .backgroundAudio: return "Drop to add background audio"
            case .project: return "Drop to open project"
            }
        }
    }

    let editor: EditorModel
    @Binding var label: String?

    /// The kind every dragged file belongs to, from its name or its content type.
    private func kind(of info: DropInfo) -> Kind? {
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return nil }
        return Kind.allCases.first { kind in
            providers.allSatisfy { provider in
                if let name = provider.suggestedName, kind.extensions.contains((name as NSString).pathExtension) { return true }
                return provider.registeredTypeIdentifiers.compactMap { UTType($0)?.preferredFilenameExtension }
                    .contains { kind.extensions.contains($0) }
            }
        }
    }

    func dropEntered(info: DropInfo) {
        label = kind(of: info)?.label
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        label = kind(of: info)?.label
        return DropProposal(operation: .copy)
    }

    func dropExited(info: DropInfo) {
        label = nil
    }

    func performDrop(info: DropInfo) -> Bool {
        label = nil
        let providers = info.itemProviders(for: [.fileURL])
        guard !providers.isEmpty else { return false }
        let editor = editor
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await Self.fileURL(provider) { urls.append(url) }
            }
            // Every file must be of one kind; each then does its part.
            guard let kind = Kind.allCases.first(where: { kind in urls.allSatisfy { kind.extensions.contains($0.pathExtension) } }) else { return }
            for url in urls {
                switch kind {
                case .backgroundAudio:
                    guard let name = BackgroundAudioLibrary.copy(url, intoProject: editor.bundleURL) else { continue }
                    editor.change { $0.audio.backgroundAudioFileName = name }
                    editor.openSidebar(.audio)
                    editor.showToast("Background audio file added")
                case .project:
                    AppController.shared.openProject(at: url)
                }
            }
        }
        return true
    }

    private static func fileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in continuation.resume(returning: url) }
        }
    }
}
