import AppKit
import SwiftUI

struct LayoutIconView: View {
    let layout: ZoneLayout?
    var size: CGFloat = 18

    var body: some View {
        GeometryReader { geometry in
            let canvas = geometry.size
            ZStack {
                RoundedRectangle(cornerRadius: 3)
                    .strokeBorder(Color.primary.opacity(0.35), lineWidth: 1)
                if let layout {
                    ForEach(layout.zones) { zone in
                        let width = max(1, zone.frame.width * canvas.width - 2)
                        let height = max(1, zone.frame.height * canvas.height - 2)
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor.opacity(0.85))
                            .frame(width: width, height: height)
                            .position(
                                x: zone.frame.midX * canvas.width,
                                y: (1 - zone.frame.midY) * canvas.height
                            )
                    }
                }
            }
        }
        .frame(width: size, height: size)
    }
}

enum LayoutIconRenderer {
    @MainActor
    static func image(for layout: ZoneLayout?, size: CGFloat = 18, template: Bool = true) -> NSImage? {
        let content = LayoutIconView(layout: layout, size: size)
        let renderer = ImageRenderer(content: content)
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return nil }
        image.isTemplate = template
        return image
    }
}
