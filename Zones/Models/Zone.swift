import CoreGraphics
import Foundation

struct Zone: Codable, Identifiable, Equatable {
    var id: UUID
    var name: String
    var frame: CGRect

    init(id: UUID = UUID(), name: String, frame: CGRect) {
        self.id = id
        self.name = name
        self.frame = frame
    }

    enum CodingKeys: String, CodingKey {
        case id, name, frame
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        frame = try container.decode(NormalizedRect.self, forKey: .frame).cgRect
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(NormalizedRect(frame), forKey: .frame)
    }
}

private struct NormalizedRect: Codable {
    var x: CGFloat
    var y: CGFloat
    var width: CGFloat
    var height: CGFloat

    init(_ rect: CGRect) {
        x = rect.origin.x
        y = rect.origin.y
        width = rect.size.width
        height = rect.size.height
    }

    var cgRect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}
