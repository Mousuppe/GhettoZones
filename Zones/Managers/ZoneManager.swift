import ApplicationServices
import AppKit
import Combine
import Defaults
import Foundation

@MainActor
final class ZoneManager: ObservableObject {
    @Published var layouts: [ZoneLayout] = []
    @Published var bindings: [AppZoneBinding] = []
    @Published var snappingEnabled: Bool = Defaults[.snappingEnabled] {
        didSet { Defaults[.snappingEnabled] = snappingEnabled }
    }
    @Published var activationThresholdMs: Int = Defaults[.activationThresholdMs] {
        didSet { Defaults[.activationThresholdMs] = activationThresholdMs }
    }
    @Published var highlightedZoneID: UUID?
    @Published var isAccessibilityGranted: Bool = AccessibilityChecker.isGranted()
    @Published var permissionWarning: Bool = false

    let displayManager: DisplayManager
    private let persistence = PersistenceController.shared
    private var cancellables = Set<AnyCancellable>()

    init(displayManager: DisplayManager) {
        self.displayManager = displayManager
        loadData()
        startPermissionMonitoring()
        displayManager.$displays
            .sink { [weak self] displays in
                self?.ensureLayoutsForDisplays(displays)
            }
            .store(in: &cancellables)
    }

    func startPermissionMonitoring() {
        refreshPermissionState()

        NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)
            .sink { [weak self] _ in
                self?.refreshPermissionState()
            }
            .store(in: &cancellables)

        DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.api"))
            .merge(with: DistributedNotificationCenter.default().publisher(for: Notification.Name("com.apple.accessibility.auth.status")))
            .sink { [weak self] _ in
                self?.refreshPermissionState()
            }
            .store(in: &cancellables)

        Timer.publish(every: 1.0, on: .main, in: .common)
            .autoconnect()
            .sink { [weak self] _ in
                guard let self, !self.isAccessibilityGranted else { return }
                self.refreshPermissionState()
            }
            .store(in: &cancellables)
    }

    func loadData() {
        layouts = persistence.loadLayouts()
        bindings = persistence.loadBindings()
        snappingEnabled = Defaults[.snappingEnabled]
        activationThresholdMs = Defaults[.activationThresholdMs]
        refreshPermissionState()
        ensureLayoutsForDisplays(displayManager.displays)
    }

    func refreshPermissionState() {
        let granted = AccessibilityChecker.isGranted()
        let previouslyGranted = isAccessibilityGranted
        isAccessibilityGranted = granted
        permissionWarning = !granted
        if granted && !previouslyGranted {
            NotificationCenter.default.post(name: .accessibilityPermissionGranted, object: nil)
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        refreshPermissionState()
    }

    func repairAccessibilityAccess() {
        if CodeSigningHelper.isAdHocSigned {
            openAccessibilitySettings()
        }
        requestAccessibility()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.refreshPermissionState()
        }
    }

    var accessibilityStatusDetail: String {
        if isAccessibilityGranted {
            return NSLocalizedString("Accessibility access is enabled.", comment: "Accessibility granted message")
        }
        if CodeSigningHelper.isAdHocSigned {
            return NSLocalizedString(
                "This GhettoZones build is ad-hoc signed. macOS links Accessibility to the app signature, so reinstalling invalidates access even if the toggle looks enabled. Remove GhettoZones from the Accessibility list with the − button, then click Re-grant Access.",
                comment: "Ad-hoc signing accessibility explanation"
            )
        }
        return NSLocalizedString(
            "GhettoZones needs Accessibility access to move and resize windows.",
            comment: "Accessibility explanation"
        )
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Layout management

    func layouts(for displayID: CGDirectDisplayID) -> [ZoneLayout] {
        layouts.filter { $0.displayID == displayID || $0.displayID == 0 }
    }

    func activeLayout(for displayID: CGDirectDisplayID) -> ZoneLayout? {
        if let savedID = persistence.activeLayoutID(for: displayID),
           let layout = layouts(for: displayID).first(where: { $0.id == savedID }) {
            return layout
        }
        return layouts(for: displayID).first
    }

    func setActiveLayout(_ layout: ZoneLayout, for displayID: CGDirectDisplayID) {
        persistence.setActiveLayoutID(layout.id, for: displayID)
        objectWillChange.send()
    }

    func activeLayoutID(for displayID: CGDirectDisplayID) -> UUID? {
        activeLayout(for: displayID)?.id
    }

    func saveLayouts() {
        persistence.saveLayouts(layouts)
    }

    func addLayout(_ layout: ZoneLayout) {
        layouts.append(layout)
        saveLayouts()
    }

    func updateLayout(_ layout: ZoneLayout) {
        guard let index = layouts.firstIndex(where: { $0.id == layout.id }) else { return }
        layouts[index] = layout
        saveLayouts()
    }

    func deleteLayout(_ layout: ZoneLayout) {
        layouts.removeAll { $0.id == layout.id }
        bindings.removeAll { $0.layoutID == layout.id }
        persistence.saveBindings(bindings)
        saveLayouts()
    }

    func duplicateLayoutForDisplay(_ template: ZoneLayout, displayID: CGDirectDisplayID) -> ZoneLayout {
        let newZones = template.zones.map { zone in
            Zone(id: UUID(), name: zone.name, frame: zone.frame)
        }
        return ZoneLayout(id: UUID(), name: template.name, zones: newZones, displayID: displayID)
    }

    func ensureLayoutsForDisplays(_ displays: [DisplayInfo]) {
        var changed = false
        for display in displays {
            let existing = layouts(for: display.id)
            if existing.isEmpty {
                let presets = persistence.loadDefaultLayouts()
                for preset in presets {
                    var copy = duplicateLayoutForDisplay(preset, displayID: display.id)
                    copy.name = preset.name
                    layouts.append(copy)
                    changed = true
                }
                if let first = layouts(for: display.id).first {
                    persistence.setActiveLayoutID(first.id, for: display.id)
                }
            }
        }
        if changed { saveLayouts() }
    }

    // MARK: - Zone helpers

    func zone(at point: NSPoint, on displayID: CGDirectDisplayID) -> Zone? {
        guard let layout = activeLayout(for: displayID),
              let visible = displayManager.screenFrame(for: displayID) else { return nil }
        let relativeX = (point.x - visible.origin.x) / visible.width
        let relativeY = (point.y - visible.origin.y) / visible.height
        let relativePoint = CGPoint(x: relativeX, y: relativeY)
        return layout.zones.first { $0.frame.contains(relativePoint) }
    }

    func adjacentZone(from zone: Zone, direction: ZoneDirection, on displayID: CGDirectDisplayID) -> Zone? {
        guard let layout = activeLayout(for: displayID) else { return nil }
        let zones = layout.zones
        guard let index = zones.firstIndex(where: { $0.id == zone.id }) else { return nil }

        switch direction {
        case .left:
            return zones.filter { $0.frame.maxX <= zone.frame.minX + 0.01 }
                .max(by: { $0.frame.maxX < $1.frame.maxX })
        case .right:
            return zones.filter { $0.frame.minX >= zone.frame.maxX - 0.01 }
                .min(by: { $0.frame.minX < $1.frame.minX })
        case .up:
            return zones.filter { $0.frame.minY >= zone.frame.maxY - 0.01 }
                .min(by: { $0.frame.minY < $1.frame.minY })
        case .down:
            return zones.filter { $0.frame.maxY <= zone.frame.minY + 0.01 }
                .max(by: { $0.frame.maxY < $1.frame.maxY })
        }
    }

    func zone(at index: Int, on displayID: CGDirectDisplayID) -> Zone? {
        guard let layout = activeLayout(for: displayID), index >= 1, index <= layout.zones.count else { return nil }
        return layout.zones[index - 1]
    }

    // MARK: - Bindings

    func rememberPosition(bundleIdentifier: String, zone: Zone, layout: ZoneLayout, displayID: CGDirectDisplayID) {
        bindings.removeAll { $0.bundleIdentifier == bundleIdentifier && $0.displayID == displayID }
        bindings.append(AppZoneBinding(
            bundleIdentifier: bundleIdentifier,
            zoneID: zone.id,
            layoutID: layout.id,
            displayID: displayID
        ))
        persistence.saveBindings(bindings)
    }

    func binding(for bundleIdentifier: String, displayID: CGDirectDisplayID) -> AppZoneBinding? {
        bindings.last { $0.bundleIdentifier == bundleIdentifier && $0.displayID == displayID }
    }

    func clearBinding(_ binding: AppZoneBinding) {
        bindings.removeAll { $0.bundleIdentifier == binding.bundleIdentifier && $0.displayID == binding.displayID }
        persistence.saveBindings(bindings)
    }

    func clearAllBindings() {
        bindings.removeAll()
        persistence.saveBindings(bindings)
    }

    func restoreRememberedPositions() {
        guard snappingEnabled, isAccessibilityGranted else { return }
        for binding in bindings {
            guard let layout = layouts.first(where: { $0.id == binding.layoutID }),
                  let zone = layout.zones.first(where: { $0.id == binding.zoneID }) else { continue }
            WindowMonitor.shared.snapApp(
                bundleIdentifier: binding.bundleIdentifier,
                to: zone,
                layout: layout,
                displayID: binding.displayID,
                zoneManager: self
            )
        }
    }
}

extension Notification.Name {
    static let accessibilityPermissionGranted = Notification.Name("accessibilityPermissionGranted")
}

enum ZoneDirection {
    case left, right, up, down
}
