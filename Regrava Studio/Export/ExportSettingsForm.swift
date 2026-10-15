import RegravaCore
import SwiftUI

/// Export settings form. Shareable-link targets are not offered by this app, so the
/// link-only fields are omitted.
struct ExportSettingsForm: View {
    @Binding var store: ExportSettingsStore
    /// nil in Settings ▸ Quick export (codec "Both" not offered there).
    var target: ExportTarget?
    /// Canvas used for the "<w>px × <h>px" label.
    var canvas: Size2?

    private var settings: Binding<ExportSettings> {
        Binding(
            get: { store.current },
            set: { store.current = $0.normalized(target: target) }
        )
    }

    var body: some View {
        let s = store.current
        VStack(alignment: .leading, spacing: Theme.gap(3)) {
            row {
                NamedField(name: "Format", icon: "video.square") {
                    SegmentedPicker(
                        options: ExportFormat.allCases,
                        label: { $0.label },
                        selection: Binding(get: { store.preferredFormat }, set: { store.select(format: $0) })
                    )
                }
                NamedField(name: "Frame rate", icon: "camera.aperture") {
                    FrameRateDropdown(options: s.format.fpsOptions, selection: settings.fps)
                }
            }
            row {
                NamedField(name: "Resolution", icon: "rectangle.dashed") {
                    VStack(alignment: .leading, spacing: Theme.gap(1)) {
                        SegmentedPicker(
                            options: s.format.resolutionOptions,
                            label: { ExportSettings.resolutionLabel($0) },
                            isDisabled: { !s.allowedResolutions.contains($0) },
                            selection: settings.height
                        )
                        if let canvas {
                            let size = s.outputSize(canvas: canvas)
                            Text(verbatim: "\(Int(size.width))px × \(Int(size.height))px")
                                .font(Theme.Typo.label)
                                .foregroundStyle(Theme.Colors.tertiary)
                        }
                        if s.format == .gif && s.height == 1080 {
                            Text("Will result in a large file size")
                                .font(Theme.Typo.label)
                                .foregroundStyle(Theme.Colors.tertiary)
                        }
                    }
                }
                formatSpecificColumn(s)
            }
        }
    }

    @ViewBuilder
    private func formatSpecificColumn(_ s: ExportSettings) -> some View {
        switch s.format {
        case .mp4:
            VStack(alignment: .leading, spacing: Theme.gap(2)) {
                NamedField(name: "Compression", icon: "scribble.variable") {
                    VStack(alignment: .leading, spacing: Theme.gap(1)) {
                        SegmentedPicker(
                            options: s.format.qualityOptions,
                            label: { $0.label },
                            description: { Self.qualityDescription($0) },
                            selection: settings.quality
                        )
                        Text("Quality setting does not impact export speed.")
                            .font(Theme.Typo.label)
                            .foregroundStyle(Theme.Colors.tertiary)
                    }
                }
                NamedField(name: "Advanced", togglable: true, defaultOpen: s.codec != .h264) {
                    NamedField(name: "Codec", icon: "film") {
                        SegmentedPicker(
                            options: s.codecOptions(target: target),
                            label: { $0.label },
                            description: { Self.codecDescription($0) },
                            selection: settings.codec
                        )
                    }
                }
            }
        case .prores:
            NamedField(name: "Profile", icon: "film") {
                SegmentedPicker(
                    options: ProResProfile.allCases,
                    label: { $0.label },
                    description: { Self.profileDescription($0) },
                    descriptionMinLines: 3,
                    selection: settings.proresProfile
                )
            }
        case .gif:
            VStack(alignment: .leading, spacing: Theme.gap(2)) {
                ToggleRow(
                    title: "High quality",
                    description: "Keeps more detail and fewer compression artifacts, for a larger file. Turn off for the best balance of file size and quality.",
                    isOn: Binding(get: { s.quality == .studio }, set: { settings.wrappedValue.quality = $0 ? .studio : .socialMedia })
                )
                ToggleRow(
                    title: "Disable loop",
                    description: "Exported GIF will only play once and then stop",
                    isOn: settings.gifDisableLoop
                )
            }
        }
    }

    /// Two-column row: 32px gap, top aligned, last column grows.
    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .top, spacing: Theme.gap(3)) { content() }
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func qualityDescription(_ quality: ExportQuality) -> String {
        switch quality {
        case .studio: return "Highest quality, best for further editing. Compression is almost impossible to notice."
        case .socialMedia: return "Good for sharing on social media, etc. Compression is noticable when taking a good look. Keep in mind that social media server might further compress the video."
        case .webHigh: return "Good for directly playing on websites. Compression is slightly visible, but not distracting."
        case .webLow: return "Good for sharing on the web, where quality is less important, increasing loading speed. Compressions is clearly visible."
        }
    }

    static func codecDescription(_ codec: ExportCodec) -> String {
        switch codec {
        case .h264: return "Great compatibility. Can play literally everywhere. Worse quality to file size ratio than HEVC."
        case .h265: return "Better quality to file size ratio than H.264. Not every player can open it."
        case .both: return "Saves both an H.264 and an HEVC file next to each other. Export may be slower, since it has to encode two files at once."
        }
    }

    static func profileDescription(_ profile: ProResProfile) -> String {
        switch profile {
        case .lt: return "Smaller files for editing. Some detail is lost in fine gradients."
        case .standard: return "The standard for editing. Visually lossless for most recordings."
        case .hq: return "Visually lossless, even for detailed screens and gradients. The usual choice for editing and archiving."
        case .p4444: return "Full color resolution, for color grading and compositing. The largest files."
        }
    }
}

/// Dropdown whose label is the number with the description "FPS" (kind secondary).
private struct FrameRateDropdown: View {
    var options: [Int]
    @Binding var selection: Int

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { fps in
                Button {
                    selection = fps
                } label: {
                    if fps == selection { Label("\(fps) FPS", systemImage: "checkmark") } else { Text("\(fps) FPS") }
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(verbatim: "\(selection)").font(Theme.Typo.controlCopy)
                Text("FPS").font(Theme.Typo.label).foregroundStyle(Theme.Colors.tertiary)
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 12)
            .frame(height: 38)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Colors.lighterBg))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.Colors.systemBorder))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}
