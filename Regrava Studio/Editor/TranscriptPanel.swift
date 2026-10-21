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
                refreshRendering()
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
                    CaptionsSettings(editor: editor)
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

// MARK: - Captions settings

private struct CaptionsSettings: View {
    @ObservedObject var editor: EditorModel

    private var config: CaptionsConfig { editor.project.captions }

    var body: some View {
        ToggleRow(title: "Disable captions", isOn: Binding(get: { !config.enableTranscript }, set: { v in editor.change { $0.captions.enableTranscript = !v } }))
        if config.enableTranscript {
            if editor.clientTranscript.contains(where: { $0.type == "sound-label" }) {
                ToggleRow(title: "Show sound labels", description: "Adds sounds such as [keyboard clacking] to your captions.", isOn: editor.binding(\.captions.showSoundLabels))
            }
            SliderField(name: "Caption size", value: editor.binding(\.captions.sizeRatio), range: 0.02...0.125, preview: { String(format: "%.1f×", $0 / 0.05) }, resetValue: 0.05)
            NamedField(name: "Font style") {
                SegmentedPicker(options: CaptionsConfig.Font.allCases, label: { ["sans-serif": "Sans-serif", "serif": "Serif", "mono": "Mono"][$0.rawValue] ?? "" }, isWide: true, selection: editor.binding(\.captions.font))
            }
            NamedField(name: "Word reveal") {
                SegmentedPicker(
                    options: CaptionsConfig.WordsReveal.allCases,
                    label: { $0 == .lineByLine ? "Line by line" : "Word by word" },
                    description: { $0 == .lineByLine ? "Show whole caption lines as their words are spoken." : "Show one word at a time. Each spoken word pushes the previous one out." },
                    isWide: true,
                    selection: editor.binding(\.captions.wordsReveal)
                )
            }
            if config.wordsReveal == .lineByLine {
                NamedField(name: "Line growth") {
                    SegmentedPicker(
                        options: CaptionsConfig.LineGrowth.allCases,
                        label: { ["entire-line": "Full line", "left-anchored": "Expanding", "centered": "Centered"][$0.rawValue] ?? "" },
                        description: {
                            [
                                "entire-line": "The line box appears at its full size right away.",
                                "left-anchored": "The line box grows from its left edge as words are spoken.",
                                "centered": "The line box grows while staying centered as words are spoken.",
                            ][$0.rawValue]
                        },
                        isWide: true,
                        selection: editor.binding(\.captions.lineGrowth)
                    )
                }
                NamedField(name: "Word animation") {
                    SegmentedPicker(
                        options: CaptionsConfig.WordEntrance.allCases,
                        label: { ["appear": "Appear", "fade-in": "Fade in", "slide-in": "Slide in"][$0.rawValue] ?? "" },
                        description: {
                            [
                                "appear": "Words pop in as they are spoken.",
                                "fade-in": "Upcoming words are shown dimmed and light up when spoken.",
                                "slide-in": "Words slide into place as they are spoken.",
                            ][$0.rawValue]
                        },
                        isWide: true,
                        selection: editor.binding(\.captions.wordEntrance)
                    )
                }
            }
            NamedField(name: "Color") {
                SegmentedPicker(
                    options: ["dark", "light"],
                    label: { $0 == "dark" ? "Dark" : "Light" },
                    isWide: true,
                    selection: Binding(
                        get: { config.isDark ? "dark" : "light" },
                        set: { v in
                            editor.change {
                                $0.captions.color = v == "dark" ? "#ffffff" : "#000000"
                                $0.captions.backgroundColor = v == "dark" ? "#000000" : "#ffffff"
                            }
                        }
                    )
                )
            }
            NamedField(name: "Caption position") {
                VStack(alignment: .leading, spacing: Theme.gap(1)) {
                    // With shortcuts on, captions stay at least 10% from the top.
                    CaptionPositionPad(position: Binding(
                        get: { config.position01 },
                        set: { v in editor.change(coalesce: "caption-position") { $0.captions.position01 = $0.captions.enableShortcuts ? Vec2(v.x, max(v.y, 0.1)) : v } }
                    ))
                    SegmentedPicker(
                        options: ["bottom", "center"],
                        label: { $0 == "bottom" ? "Bottom" : "Center" },
                        isWide: true,
                        selection: Binding(
                            get: { config.position01 == Vec2(0.5, 0.5) ? "center" : "bottom" },
                            set: { v in editor.change { $0.captions.position01 = v == "center" ? Vec2(0.5, 0.5) : Vec2(0.5, 1) } }
                        )
                    )
                }
            }
        }
    }
}

/// A 16:9 pad with a draggable dot for `position01`.
private struct CaptionPositionPad: View {
    @Binding var position: Vec2

    var body: some View {
        GeometryReader { proxy in
            let size = proxy.size
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg)
                Capsule()
                    .fill(Theme.Colors.primaryActiveText)
                    .frame(width: size.width * 0.3, height: 8)
                    .position(x: 12 + position.x * (size.width - 24), y: 10 + position.y * (size.height - 20))
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                position = Vec2(clamp((value.location.x - 12) / max(size.width - 24, 1), 0, 1), clamp((value.location.y - 10) / max(size.height - 20, 1), 0, 1))
            })
        }
        .aspectRatio(16.0 / 9, contentMode: .fit)
    }
}
