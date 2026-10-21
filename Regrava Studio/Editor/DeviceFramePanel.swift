import RegravaCore
import SwiftUI

/// "Device frame" panel (`DeviceFrameSettings`).
struct DeviceFramePanel: View {
    @ObservedObject var editor: EditorModel
    /// Local, not saved: resets to Perfect each time the panel opens.
    @State private var mode = "perfect"

    private var config: DeviceConfig { editor.project.device }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSection(showsDivider: config.enableMockup) {
                ToggleRow(title: "Use device mockup", description: "Wrap recording in device mockup.", isOn: editor.binding(\.device.enableMockup))
            }
            if config.enableMockup {
                SidebarSection(title: "Device frames", showsDivider: false) {
                    SegmentedPicker(
                        options: ["perfect", "loose"],
                        label: { $0 == "perfect" ? "Perfect" : "Flexible" },
                        icon: { $0 == "perfect" ? "iphone" : "iphone.sizes" },
                        description: {
                            $0 == "perfect"
                                ? "Show only device frames that precisely match your recording size."
                                : "Show all device frames, even those that don't precisely match your recording size."
                        },
                        isWide: true,
                        selection: $mode
                    )
                    // Models without colours are left out of the list.
                    ForEach(editor.project.deviceFrameChoices(perfect: mode == "perfect").filter { !$0.colors.isEmpty }, id: \.name) { device in
                        SidebarSection(title: device.name, showsDivider: false) {
                            SegmentedPicker(
                                options: device.colors.map { device.key($0) },
                                label: { key in device.colors.first { device.key($0) == key } ?? "Unknown" },
                                icon: { _ in "circle.lefthalf.filled.righthalf.striped.horizontal.inverse" },
                                // Selected only once a frame was chosen; the automatic one isn't.
                                selection: Binding(get: { config.frameKey ?? "" }, set: { key in editor.change { $0.device.frameKey = key } })
                            )
                        }
                    }
                }
            }
        }
    }
}
