import AppKit
import RegravaCore
import RegravaRender
import SwiftUI
import UniformTypeIdentifiers

// Captions sidebar section: transcript generation and export. Only the Local method (macOS
// speech recognition) exists here; cloud transcription is not available.

extension EditorModel {
    /// Words in source time with the onset estimate (`client.transcript`).
    var clientTranscript: [TranscriptWord] {
        guard let transcript else { return [] }
        return TranscriptTiming.clientTranscript([(0, transcript.transcript)])
    }

    /// `generate({type:"system", locale})`: replaces the transcript and every edit made to it.
    func generateTranscript(locale: String) {
        guard !isGeneratingTranscript, let track = project.recording.audioSources.firstIndex(of: .microphone) else { return }
        isGeneratingTranscript = true
        let recording = videoURL, bundle = bundleURL
        Task {
            defer { isGeneratingTranscript = false }
            do {
                let words = try await SpeechTranscription.transcribe(recording: recording, audioTrackIndex: track, locale: locale)
                let result = SessionTranscript(generator: .system(locale: locale), transcript: words)
                try result.save(bundle: bundle)
                transcript = result
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    /// "Export transcript": an SRT with one cue per visible word, in playback time.
    func exportTranscript() {
        let panel = NSSavePanel()
        panel.message = "Where to save the transcript?"
        panel.allowedContentTypes = [UTType(filenameExtension: "srt") ?? .plainText]
        panel.nameFieldStringValue = projectName + ".srt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let words = CaptionWords.visible(clientTranscript, resolver: project.resolver, showSoundLabels: false)
        do {
            try CaptionWords.srt(words, resolver: project.resolver).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

struct TranscriptPanel: View {
    @ObservedObject var editor: EditorModel

    var body: some View {
        if editor.isGeneratingTranscript {
            VStack(spacing: Theme.gap(2)) {
                ProgressView().controlSize(.small)
                Text("Transcript is being generated. You can still edit your project while it's being generated.")
                    .font(Theme.Typo.label)
                    .foregroundStyle(Theme.Colors.tertiary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 40)
        } else if editor.transcript == nil {
            SidebarSection(title: "Generate transcript", showsDivider: false) {
                TranscriptGenerationForm(editor: editor)
            }
        } else {
            VStack(alignment: .leading, spacing: 0) {
                SidebarSection(title: "Captions") {
                    RSButton(title: "Export transcript", kind: .secondary) { editor.exportTranscript() }
                }
                SidebarSection(title: "Generate transcript", showsDivider: false) {
                    NamedField(name: "Re-Generate transcript", togglable: true) {
                        Callout(message: "When re-generating transcript, previous transcript (and all changes you made to it) will be lost.")
                        TranscriptGenerationForm(editor: editor)
                    }
                }
            }
        }
    }
}

/// Local sub-form: searchable Language and Generate transcript.
private struct TranscriptGenerationForm: View {
    @ObservedObject var editor: EditorModel
    @State private var locales: [String] = []
    @State private var locale = "en_US"
    @State private var isPickerOpen = false
    @State private var search = ""

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.gap(2)) {
            NamedField(name: "Language") {
                Button { isPickerOpen = true } label: {
                    HStack {
                        Text(Self.displayName(locale)).lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 10))
                    }
                    .font(Theme.Typo.controlCopy)
                    .padding(.horizontal, 12)
                    .frame(height: Theme.Boxes.control.height)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $isPickerOpen, arrowEdge: .bottom) { picker }
            }
            RSButton(title: "Generate transcript", kind: .primary, isWide: true) { editor.generateTranscript(locale: locale) }
                .disabled(locales.isEmpty || !locales.contains(locale))
            Callout(kind: .secondary, icon: nil, message: "Transcript will be generated locally using Apple's native speech recognition engine (requires macOS 26.0 or later). No data will be sent to the server.")
        }
        .task {
            locales = await SpeechTranscription.supportedLocales()
            locale = editor.transcript?.generator.locale ?? "en_US"
        }
    }

    private var picker: some View {
        let filtered = locales.filter { search.isEmpty || Self.displayName($0).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search) }
        return VStack(alignment: .leading, spacing: 4) {
            TextField("Search", text: $search).textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { id in
                        Button {
                            locale = id
                            isPickerOpen = false
                        } label: {
                            HStack {
                                Text(Self.displayName(id))
                                Spacer()
                                if id == locale { Image(systemName: "checkmark") }
                            }
                            .font(Theme.Typo.controlCopy)
                            .padding(.horizontal, 8)
                            .frame(height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(height: 260)
        }
        .padding(8)
        .frame(width: 280)
    }

    /// `Intl.DisplayNames('en')` of the id with its first `_` as `-`: "English (United States)".
    static func displayName(_ id: String) -> String {
        let bcp = id.replacingOccurrences(of: "_", with: "-", options: [], range: id.range(of: "_"))
        return Locale(identifier: "en").localizedString(forIdentifier: bcp) ?? id
    }
}
