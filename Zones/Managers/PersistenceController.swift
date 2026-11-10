import CoreGraphics
import Defaults
import Foundation

extension Defaults.Keys {
    static let snappingEnabled = Key<Bool>("snappingEnabled", default: true)
    static let animateWindowSnapping = Key<Bool>("animateWindowSnapping", default: true)
    static let activationThresholdMs = Key<Int>("activationThresholdMs", default: 300)
    static let activeLayoutIDs = Key<[String: String]>("activeLayoutIDs", default: [:])
    static let appZoneBindings = Key<[AppZoneBinding]>("appZoneBindings", default: [])
    static let hasShownAccessibilityPrompt = Key<Bool>("hasShownAccessibilityPrompt", default: false)
}

final class PersistenceController {
    static let shared = PersistenceController()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var layoutsDirectory: URL {
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("Zones", isDirectory: true)
    }

    private var layoutsFileURL: URL {
        layoutsDirectory.appendingPathComponent("layouts.json")
    }

    private init() {
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func loadLayouts() -> [ZoneLayout] {
        ensureDirectoryExists()
        if fileManager.fileExists(atPath: layoutsFileURL.path) {
            do {
                let data = try Data(contentsOf: layoutsFileURL)
                return try decoder.decode([ZoneLayout].self, from: data)
            } catch {
                NSLog("Failed to load layouts: \(error)")
            }
        }
        return loadDefaultLayouts()
    }

    func saveLayouts(_ layouts: [ZoneLayout]) {
        ensureDirectoryExists()
        do {
            let data = try encoder.encode(layouts)
            try data.write(to: layoutsFileURL, options: .atomic)
        } catch {
            NSLog("Failed to save layouts: \(error)")
        }
    }

    func loadDefaultLayouts() -> [ZoneLayout] {
        guard let url = Bundle.main.url(forResource: "default-layouts", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let layouts = try? decoder.decode([ZoneLayout].self, from: data) else {
            return ZoneLayout.builtInPresets()
        }
        return layouts
    }

    func loadBindings() -> [AppZoneBinding] {
        Defaults[.appZoneBindings]
    }

    func saveBindings(_ bindings: [AppZoneBinding]) {
        Defaults[.appZoneBindings] = bindings
    }

    func activeLayoutID(for displayID: CGDirectDisplayID) -> UUID? {
        let key = String(displayID)
        guard let idString = Defaults[.activeLayoutIDs][key] else { return nil }
        return UUID(uuidString: idString)
    }

    func setActiveLayoutID(_ id: UUID?, for displayID: CGDirectDisplayID) {
        var map = Defaults[.activeLayoutIDs]
        let key = String(displayID)
        if let id {
            map[key] = id.uuidString
        } else {
            map.removeValue(forKey: key)
        }
        Defaults[.activeLayoutIDs] = map
    }

    private func ensureDirectoryExists() {
        if !fileManager.fileExists(atPath: layoutsDirectory.path) {
            try? fileManager.createDirectory(at: layoutsDirectory, withIntermediateDirectories: true)
        }
    }
}

extension ZoneLayout {
    static func builtInPresets() -> [ZoneLayout] {
        [
            ZoneLayout(
                name: NSLocalizedString("Halves", comment: "Layout preset name"),
                zones: [
                    Zone(name: NSLocalizedString("Left", comment: "Zone name"), frame: CGRect(x: 0, y: 0, width: 0.5, height: 1)),
                    Zone(name: NSLocalizedString("Right", comment: "Zone name"), frame: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
                ],
                displayID: 0
            ),
            ZoneLayout(
                name: NSLocalizedString("Thirds", comment: "Layout preset name"),
                zones: [
                    Zone(name: NSLocalizedString("Left", comment: "Zone name"), frame: CGRect(x: 0, y: 0, width: 0.3333, height: 1)),
                    Zone(name: NSLocalizedString("Center", comment: "Zone name"), frame: CGRect(x: 0.3333, y: 0, width: 0.3334, height: 1)),
                    Zone(name: NSLocalizedString("Right", comment: "Zone name"), frame: CGRect(x: 0.6667, y: 0, width: 0.3333, height: 1))
                ],
                displayID: 0
            ),
            ZoneLayout(
                name: NSLocalizedString("Quarters", comment: "Layout preset name"),
                zones: [
                    Zone(name: NSLocalizedString("Top Left", comment: "Zone name"), frame: CGRect(x: 0, y: 0.5, width: 0.5, height: 0.5)),
                    Zone(name: NSLocalizedString("Top Right", comment: "Zone name"), frame: CGRect(x: 0.5, y: 0.5, width: 0.5, height: 0.5)),
                    Zone(name: NSLocalizedString("Bottom Left", comment: "Zone name"), frame: CGRect(x: 0, y: 0, width: 0.5, height: 0.5)),
                    Zone(name: NSLocalizedString("Bottom Right", comment: "Zone name"), frame: CGRect(x: 0.5, y: 0, width: 0.5, height: 0.5))
                ],
                displayID: 0
            ),
            ZoneLayout(
                name: NSLocalizedString("Primary + Sidebar", comment: "Layout preset name"),
                zones: [
                    Zone(name: NSLocalizedString("Primary", comment: "Zone name"), frame: CGRect(x: 0, y: 0, width: 0.7, height: 1)),
                    Zone(name: NSLocalizedString("Sidebar", comment: "Zone name"), frame: CGRect(x: 0.7, y: 0, width: 0.3, height: 1))
                ],
                displayID: 0
            ),
            ZoneLayout(
                name: NSLocalizedString("Focus", comment: "Layout preset name"),
                zones: [
                    Zone(name: NSLocalizedString("Focus", comment: "Zone name"), frame: CGRect(x: 0, y: 0, width: 0.7, height: 1)),
                    Zone(name: NSLocalizedString("Secondary", comment: "Zone name"), frame: CGRect(x: 0.7, y: 0, width: 0.3, height: 1))
                ],
                displayID: 0
            )
        ]
    }
}
