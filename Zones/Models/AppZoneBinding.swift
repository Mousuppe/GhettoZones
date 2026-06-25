import CoreGraphics
import Foundation

struct AppZoneBinding: Codable, Identifiable, Equatable {
    var id: String { bundleIdentifier }
    var bundleIdentifier: String
    var zoneID: UUID
    var layoutID: UUID
    var displayID: CGDirectDisplayID

    init(bundleIdentifier: String, zoneID: UUID, layoutID: UUID, displayID: CGDirectDisplayID) {
        self.bundleIdentifier = bundleIdentifier
        self.zoneID = zoneID
        self.layoutID = layoutID
        self.displayID = displayID
    }
}
