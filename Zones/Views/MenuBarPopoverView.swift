import SwiftUI

struct MenuBarPopoverView: View {
    @ObservedObject var zoneManager: ZoneManager
    @EnvironmentObject var appState: AppState

    private var mainDisplayID: CGDirectDisplayID {
        zoneManager.displayManager.displays.first(where: \.isMain)?.id
            ?? zoneManager.displayManager.displays.first?.id
            ?? 0
    }

    private var availableLayouts: [ZoneLayout] {
        zoneManager.layouts(for: mainDisplayID)
    }

    private var selectedLayoutID: UUID? {
        zoneManager.activeLayoutID(for: mainDisplayID)
    }

    private var activeLayout: ZoneLayout? {
        guard let selectedLayoutID else { return availableLayouts.first }
        return availableLayouts.first { $0.id == selectedLayoutID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                LayoutIconView(layout: activeLayout)
                Text(NSLocalizedString("GhettoZones", comment: "App name in popover"))
                    .font(.headline)
                if zoneManager.permissionWarning {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .help(NSLocalizedString("Accessibility permission required", comment: "Permission warning tooltip"))
                }
            }

            if !availableLayouts.isEmpty {
                Picker(NSLocalizedString("Layout", comment: "Layout picker label"), selection: layoutBinding) {
                    ForEach(availableLayouts) { layout in
                        Text(layout.name).tag(Optional(layout.id))
                    }
                }
                .labelsHidden()
            }

            Toggle(NSLocalizedString("Snapping Enabled", comment: "Snapping toggle"), isOn: $zoneManager.snappingEnabled)
                .disabled(!zoneManager.isAccessibilityGranted)

            Divider()

            Button(NSLocalizedString("Edit GhettoZones Layouts…", comment: "Open zone editor")) {
                appState.openZoneEditor()
            }

            Button(NSLocalizedString("GhettoZones Settings…", comment: "Open settings")) {
                appState.openSettings()
            }

            Divider()

            Button(NSLocalizedString("Quit GhettoZones", comment: "Quit app")) {
                NSApplication.shared.terminate(nil)
            }
        }
        .padding()
        .frame(width: 260)
    }

    private var layoutBinding: Binding<UUID?> {
        Binding(
            get: { selectedLayoutID },
            set: { newID in
                guard let newID,
                      let layout = availableLayouts.first(where: { $0.id == newID }) else { return }
                zoneManager.setActiveLayout(layout, for: mainDisplayID)
            }
        )
    }
}
