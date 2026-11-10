import AppKit
import SwiftUI

struct ZoneEditorView: View {
    @ObservedObject var zoneManager: ZoneManager
    var onClose: () -> Void

    @State private var selectedDisplayID: CGDirectDisplayID = 0
    @State private var selectedLayoutID: UUID?
    @State private var editingLayout: ZoneLayout?
    @State private var selectedZoneID: UUID?

    @StateObject private var screenSession = ZoneScreenEditorSession(
        layout: ZoneLayout(name: "", zones: [], displayID: 0)
    )
    @State private var screenWindow: ZoneScreenEditorWindow?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 210)
                .background(Color(nsColor: .controlBackgroundColor))

            Divider()

            editorDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, minHeight: 420)
        .background(Color(nsColor: .windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("Cancel", comment: "Cancel editor")) {
                    closeWithoutSaving()
                }
                .keyboardShortcut(.cancelAction)
            }
            ToolbarItem(placement: .confirmationAction) {
                Button(NSLocalizedString("Save & Close", comment: "Save and close editor")) {
                    saveAndClose()
                }
                .keyboardShortcut(.defaultAction)
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addNewLayout()
                } label: {
                    Label(NSLocalizedString("New Layout", comment: "Create layout button"), systemImage: "plus")
                }
            }
        }
        .onAppear {
            initializeSelection()
            screenSession.onRequestClose = { saveAndClose() }
            syncSessionFromEditor()
            presentScreenEditor()
        }
        .onDisappear {
            tearDownScreenEditor()
        }
        .onChange(of: selectedLayoutID) { _ in
            loadEditingLayout()
            syncSessionFromEditor()
            presentScreenEditor()
        }
        .onChange(of: selectedDisplayID) { _ in
            selectedLayoutID = zoneManager.activeLayoutID(for: selectedDisplayID)
            loadEditingLayout()
            syncSessionFromEditor()
            presentScreenEditor()
        }
        .onChange(of: selectedZoneID) { id in
            if screenSession.selectedZoneID != id {
                screenSession.selectedZoneID = id
            }
            promoteEditorPanel()
        }
        .onReceive(screenSession.$selectedZoneID) { id in
            if selectedZoneID != id {
                selectedZoneID = id
            }
        }
        .onReceive(screenSession.$layout) { layout in
            guard editingLayout?.id == layout.id else { return }
            if editingLayout != layout {
                editingLayout = layout
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(NSLocalizedString("Display", comment: "Display picker"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("", selection: $selectedDisplayID) {
                ForEach(zoneManager.displayManager.displays) { display in
                    Text(display.name).tag(display.id)
                }
            }
            .labelsHidden()

            Text(NSLocalizedString("Layouts", comment: "Layouts section"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            List(selection: $selectedLayoutID) {
                ForEach(layoutsForSelectedDisplay) { layout in
                    Text(layout.name)
                        .tag(Optional(layout.id))
                        .contextMenu {
                            Button(NSLocalizedString("Delete", comment: "Delete layout"), role: .destructive) {
                                zoneManager.deleteLayout(layout)
                                initializeSelection()
                                syncSessionFromEditor()
                                presentScreenEditor()
                            }
                        }
                }
            }
            .listStyle(.sidebar)
        }
        .padding(12)
    }

    @ViewBuilder
    private var editorDetail: some View {
        if let layout = editingLayout {
            VStack(alignment: .leading, spacing: 14) {
                Text(NSLocalizedString("Edit zones on the blue overlay covering your display. Click a zone to select it, then drag its edges. Hold ⌥ to disable snapping.", comment: "On-screen editor instructions"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextField(
                    NSLocalizedString("Layout Name", comment: "Layout name field"),
                    text: Binding(
                        get: { editingLayout?.name ?? "" },
                        set: { newName in
                            editingLayout?.name = newName
                            syncSessionFromEditor()
                        }
                    )
                )
                .textFieldStyle(.roundedBorder)

                if let zoneID = selectedZoneID,
                   let index = layout.zones.firstIndex(where: { $0.id == zoneID }) {
                    HStack {
                        TextField(
                            NSLocalizedString("Zone Name", comment: "Zone name field"),
                            text: Binding(
                                get: { editingLayout?.zones[index].name ?? "" },
                                set: { newName in
                                    editingLayout?.zones[index].name = newName
                                    syncSessionFromEditor()
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)

                        Button(role: .destructive) {
                            editingLayout?.zones.removeAll { $0.id == zoneID }
                            selectedZoneID = nil
                            syncSessionFromEditor()
                        } label: {
                            Label(NSLocalizedString("Delete Zone", comment: "Delete zone button"), systemImage: "trash")
                        }
                    }
                }

                Text(NSLocalizedString("Zones", comment: "Zones list heading"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if layout.zones.isEmpty {
                    Text(NSLocalizedString("No zones yet — drag on the overlay to draw one.", comment: "Empty zones description"))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                } else {
                    List(selection: $selectedZoneID) {
                        ForEach(layout.zones) { zone in
                            HStack {
                                Circle()
                                    .fill(selectedZoneID == zone.id ? Color.accentColor : Color.secondary.opacity(0.4))
                                    .frame(width: 8, height: 8)
                                Text(zone.name)
                                Spacer()
                                Text(sizeLabel(for: zone))
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            .tag(Optional(zone.id))
                            .contentShape(Rectangle())
                        }
                    }
                    .listStyle(.inset)
                }

                HStack {
                    Spacer()
                    Button(NSLocalizedString("Cancel", comment: "Cancel editor")) {
                        closeWithoutSaving()
                    }
                    Button(NSLocalizedString("Save & Close", comment: "Save and close editor")) {
                        saveAndClose()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(16)
        } else {
            VStack(spacing: 12) {
                Image(systemName: "square.dashed")
                    .font(.system(size: 40))
                    .foregroundStyle(.secondary)
                Text(NSLocalizedString("No Layout Selected", comment: "Empty editor state"))
                    .font(.title3)
                Text(NSLocalizedString("Select or create a layout to begin editing.", comment: "Empty editor description"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button(NSLocalizedString("Close", comment: "Close empty editor")) {
                    closeWithoutSaving()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var layoutsForSelectedDisplay: [ZoneLayout] {
        zoneManager.layouts(for: selectedDisplayID)
    }

    private func sizeLabel(for zone: Zone) -> String {
        let width = Int((zone.frame.width * 100).rounded())
        let height = Int((zone.frame.height * 100).rounded())
        return "\(width)×\(height)%"
    }

    private func initializeSelection() {
        if selectedDisplayID == 0, let first = zoneManager.displayManager.displays.first {
            selectedDisplayID = first.id
        }
        selectedLayoutID = zoneManager.activeLayoutID(for: selectedDisplayID)
            ?? layoutsForSelectedDisplay.first?.id
        loadEditingLayout()
    }

    private func loadEditingLayout() {
        guard let id = selectedLayoutID,
              let layout = zoneManager.layouts.first(where: { $0.id == id }) else {
            editingLayout = nil
            return
        }
        editingLayout = layout
        selectedZoneID = nil
    }

    private func syncSessionFromEditor() {
        guard let layout = editingLayout else { return }
        if screenSession.layout != layout {
            screenSession.layout = layout
        }
        if screenSession.selectedZoneID != selectedZoneID {
            screenSession.selectedZoneID = selectedZoneID
        }
    }

    private func presentScreenEditor() {
        guard editingLayout != nil,
              let display = zoneManager.displayManager.display(forID: selectedDisplayID) else {
            tearDownScreenEditor()
            return
        }
        syncSessionFromEditor()

        let panel = NSApp.windows.first {
            $0.title == NSLocalizedString("GhettoZones Zone Editor", comment: "Zone editor window title")
        }

        if let window = screenWindow {
            window.editorPanel = panel
            window.update(display: display, session: screenSession)
            window.showEditor()
        } else {
            let window = ZoneScreenEditorWindow(display: display, session: screenSession)
            window.editorPanel = panel
            screenWindow = window
            window.showEditor()
        }
        promoteEditorPanel()
    }

    private func promoteEditorPanel() {
        let panel = NSApp.windows.first {
            $0.title == NSLocalizedString("GhettoZones Zone Editor", comment: "Zone editor window title")
        }
        screenWindow?.editorPanel = panel
        panel?.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.floatingWindow)) + 3)
        panel?.collectionBehavior.insert(.moveToActiveSpace)
        panel?.makeKeyAndOrderFront(nil)
    }

    private func tearDownScreenEditor() {
        screenWindow?.hideEditor()
        screenWindow?.close()
        screenWindow = nil
    }

    private func addNewLayout() {
        let name = String(format: NSLocalizedString("Custom Layout %d", comment: "New layout default name"), layoutsForSelectedDisplay.count + 1)
        let layout = ZoneLayout(name: name, zones: [], displayID: selectedDisplayID)
        zoneManager.addLayout(layout)
        selectedLayoutID = layout.id
        loadEditingLayout()
        syncSessionFromEditor()
        presentScreenEditor()
    }

    private func saveAndClose() {
        if let layout = editingLayout {
            let latest = screenSession.layout.id == layout.id ? screenSession.layout : layout
            zoneManager.updateLayout(latest)
            zoneManager.setActiveLayout(latest, for: selectedDisplayID)
            WindowMonitor.shared.refreshOverlays()
        }
        tearDownScreenEditor()
        onClose()
    }

    private func closeWithoutSaving() {
        tearDownScreenEditor()
        onClose()
    }
}
