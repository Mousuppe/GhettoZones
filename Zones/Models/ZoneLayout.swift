import CoreGraphics
import Foundation

struct ZoneLayout: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var zones: [Zone]
    var displayID: CGDirectDisplayID

    init(id: UUID = UUID(), name: String, zones: [Zone], displayID: CGDirectDisplayID) {
        self.id = id
        self.name = name
        self.zones = zones
        self.displayID = displayID
    }
}
