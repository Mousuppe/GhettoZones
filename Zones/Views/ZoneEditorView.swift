import SwiftUI

struct ZoneEditorView: View {
    @ObservedObject var zoneManager: ZoneManager
    @Environment(\.dismiss) private var dismiss

    @State private var selectedDisplayID: CGDirectDisplayID = 0
    @State private var selectedLayoutID: UUID?
    @State private var editingLayout: ZoneLayout?
    @State private var selectedZoneID: UUID?
    @State private var newLayoutName = ""

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            editorDetail
        }
        .frame(minWidth: 800, minHeight: 500)
        .navigationTitle(NSLocalizedString("GhettoZones Zone Editor", comment: "Zone editor window title"))
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(NSLocalizedString("Done", comment: "Close editor")) {
                    saveAndClose()
                }
            }
            ToolbarItem(placement: .primaryAction) {
                Button {
                    addNewLayout()
                } label: {
                    Label(NSLocalizedString("New Layout", comment: "Create layout button"), systemImage: "plus")
                }
            }
        }
        .onAppear { initializeSelection() }
        .onChange(of: selectedLayoutID) { _ in loadEditingLayout() }
        .onChange(of: selectedDisplayID) { _ in
            selectedLayoutID = zoneManager.activeLayoutID(for: selectedDisplayID)
            loadEditingLayout()
        }
    }

    private var sidebar: some View {
        List(selection: $selectedLayoutID) {
            Section(NSLocalizedString("Displays", comment: "Displays section")) {
                Picker(NSLocalizedString("Display", comment: "Display picker"), selection: $selectedDisplayID) {
                    ForEach(zoneManager.displayManager.displays) { display in
                        Text(display.name).tag(display.id)
                    }
                }
                .labelsHidden()
            }

            Section(NSLocalizedString("Layouts", comment: "Layouts section")) {
                ForEach(layoutsForSelectedDisplay) { layout in
                    Text(layout.name)
                        .tag(Optional(layout.id))
                        .contextMenu {
                            Button(NSLocalizedString("Delete", comment: "Delete layout"), role: .destructive) {
                                zoneManager.deleteLayout(layout)
                                initializeSelection()
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200)
    }

    @ViewBuilder
    private var editorDetail: some View {
        if var layout = editingLayout {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    TextField(
                        NSLocalizedString("Layout Name", comment: "Layout name field"),
                        text: Binding(
                            get: { editingLayout?.name ?? "" },
                            set: { editingLayout?.name = $0 }
                        )
                    )
                    .textFieldStyle(.roundedBorder)
                    if let zoneID = selectedZoneID,
                       let index = layout.zones.firstIndex(where: { $0.id == zoneID }) {
                        TextField(
                            NSLocalizedString("Zone Name", comment: "Zone name field"),
                            text: Binding(
                                get: { layout.zones[index].name },
                                set: { newName in
                                    layout.zones[index].name = newName
                                    editingLayout = layout
                                }
                            )
                        )
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 200)

                        Button(role: .destructive) {
                            layout.zones.removeAll { $0.id == zoneID }
                            editingLayout = layout
                            selectedZoneID = nil
                        } label: {
                            Label(NSLocalizedString("Delete Zone", comment: "Delete zone button"), systemImage: "trash")
                        }
                    }
                }

                Text(NSLocalizedString("Drag on the canvas to draw a new zone. Select a zone to rename or resize.", comment: "Editor instructions"))
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let display = zoneManager.displayManager.display(forID: selectedDisplayID) {
                    ZoneCanvasView(
                        layout: Binding(
                            get: { editingLayout ?? layout },
                            set: { editingLayout = $0 }
                        ),
                        selectedZoneID: $selectedZoneID,
                        displayFrame: display.visibleFrame
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .padding()
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
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var layoutsForSelectedDisplay: [ZoneLayout] {
        zoneManager.layouts(for: selectedDisplayID)
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

    private func addNewLayout() {
        let name = String(format: NSLocalizedString("Custom Layout %d", comment: "New layout default name"), layoutsForSelectedDisplay.count + 1)
        let layout = ZoneLayout(name: name, zones: [], displayID: selectedDisplayID)
        zoneManager.addLayout(layout)
        selectedLayoutID = layout.id
        loadEditingLayout()
    }

    private func saveAndClose() {
        if let layout = editingLayout {
            zoneManager.updateLayout(layout)
            zoneManager.setActiveLayout(layout, for: selectedDisplayID)
        }
        dismiss()
    }
}
