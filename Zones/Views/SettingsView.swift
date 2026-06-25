import AppKit
import KeyboardShortcuts
import SwiftUI

struct SettingsView: View {
    @ObservedObject var zoneManager: ZoneManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label(NSLocalizedString("General", comment: "Settings tab"), systemImage: "gearshape")
                }
            shortcutsTab
                .tabItem {
                    Label(NSLocalizedString("Shortcuts", comment: "Settings tab"), systemImage: "keyboard")
                }
            rememberedAppsTab
                .tabItem {
                    Label(NSLocalizedString("Remembered Apps", comment: "Settings tab"), systemImage: "app.badge")
                }
        }
        .frame(width: 520, height: 420)
        .padding()
    }

    private var generalTab: some View {
        Form {
            Section {
                Toggle(NSLocalizedString("Enable Snapping", comment: "Settings toggle"), isOn: $zoneManager.snappingEnabled)
                    .disabled(!zoneManager.isAccessibilityGranted)

                HStack {
                    Text(NSLocalizedString("Activation Threshold", comment: "Drag threshold setting"))
                    Slider(
                        value: Binding(
                            get: { Double(zoneManager.activationThresholdMs) },
                            set: { zoneManager.activationThresholdMs = Int($0) }
                        ),
                        in: 0...1000,
                        step: 50
                    )
                    Text("\(zoneManager.activationThresholdMs) ms")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
            }

            Section(NSLocalizedString("Permissions", comment: "Permissions section")) {
                HStack {
                    Image(systemName: zoneManager.isAccessibilityGranted ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(zoneManager.isAccessibilityGranted ? .green : .red)
                    Text(NSLocalizedString("Accessibility", comment: "Accessibility permission"))
                    Spacer()
                    if !zoneManager.isAccessibilityGranted {
                        Button(NSLocalizedString("Grant Access", comment: "Open accessibility settings")) {
                            zoneManager.requestAccessibility()
                        }
                        Button(NSLocalizedString("Open Settings", comment: "Open system settings")) {
                            zoneManager.openAccessibilitySettings()
                        }
                    }
                }

                if zoneManager.isAccessibilityGranted {
                    Text(NSLocalizedString("Accessibility access is enabled.", comment: "Accessibility granted message"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(NSLocalizedString("GhettoZones needs Accessibility access to move and resize windows.", comment: "Accessibility explanation"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("If you already enabled GhettoZones in System Settings, toggle it off and on, then switch back here — or quit and reopen the app.", comment: "Accessibility troubleshooting"))
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Text(Bundle.main.bundlePath)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { zoneManager.refreshPermissionState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            zoneManager.refreshPermissionState()
        }
    }

    private var shortcutsTab: some View {
        Form {
            Section(NSLocalizedString("Snap to Adjacent Zone", comment: "Shortcuts section")) {
                shortcutRow(NSLocalizedString("Snap Left", comment: "Shortcut label"), name: .snapLeft)
                shortcutRow(NSLocalizedString("Snap Right", comment: "Shortcut label"), name: .snapRight)
                shortcutRow(NSLocalizedString("Snap Up", comment: "Shortcut label"), name: .snapUp)
                shortcutRow(NSLocalizedString("Snap Down", comment: "Shortcut label"), name: .snapDown)
            }
            Section(NSLocalizedString("Snap to Zone by Number", comment: "Shortcuts section")) {
                shortcutRow(NSLocalizedString("Zone 1", comment: "Shortcut label"), name: .snapZone1)
                shortcutRow(NSLocalizedString("Zone 2", comment: "Shortcut label"), name: .snapZone2)
                shortcutRow(NSLocalizedString("Zone 3", comment: "Shortcut label"), name: .snapZone3)
                shortcutRow(NSLocalizedString("Zone 4", comment: "Shortcut label"), name: .snapZone4)
                shortcutRow(NSLocalizedString("Zone 5", comment: "Shortcut label"), name: .snapZone5)
                shortcutRow(NSLocalizedString("Zone 6", comment: "Shortcut label"), name: .snapZone6)
                shortcutRow(NSLocalizedString("Zone 7", comment: "Shortcut label"), name: .snapZone7)
                shortcutRow(NSLocalizedString("Zone 8", comment: "Shortcut label"), name: .snapZone8)
                shortcutRow(NSLocalizedString("Zone 9", comment: "Shortcut label"), name: .snapZone9)
            }
            Section(NSLocalizedString("Move Between Monitors", comment: "Shortcuts section")) {
                shortcutRow(NSLocalizedString("Next Monitor", comment: "Shortcut label"), name: .moveToNextMonitor)
                shortcutRow(NSLocalizedString("Previous Monitor", comment: "Shortcut label"), name: .moveToPreviousMonitor)
            }
        }
        .formStyle(.grouped)
    }

    private func shortcutRow(_ title: String, name: KeyboardShortcuts.Name) -> some View {
        HStack {
            Text(title)
            Spacer()
            KeyboardShortcuts.Recorder(for: name)
        }
    }

    private var rememberedAppsTab: some View {
        VStack(alignment: .leading) {
            HStack {
                Text(NSLocalizedString("Remembered App Positions", comment: "Bindings section title"))
                    .font(.headline)
                Spacer()
                Button(NSLocalizedString("Clear All", comment: "Clear all bindings"), role: .destructive) {
                    zoneManager.clearAllBindings()
                }
                .disabled(zoneManager.bindings.isEmpty)
            }

            if zoneManager.bindings.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "app.dashed")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    Text(NSLocalizedString("No Remembered Apps", comment: "Empty bindings"))
                        .font(.headline)
                    Text(NSLocalizedString("Apps will appear here after you snap them to a zone.", comment: "Empty bindings description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(zoneManager.bindings) { binding in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(binding.bundleIdentifier)
                                    .font(.body)
                                if let layout = zoneManager.layouts.first(where: { $0.id == binding.layoutID }),
                                   let zone = layout.zones.first(where: { $0.id == binding.zoneID }) {
                                    Text("\(layout.name) → \(zone.name)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Button(role: .destructive) {
                                zoneManager.clearBinding(binding)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }
        }
    }
}
