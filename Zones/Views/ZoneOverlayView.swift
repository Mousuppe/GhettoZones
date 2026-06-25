import AppKit
import SwiftUI

struct ZoneOverlayPreview {
    var zoneFrames: [CGRect] = []
    var hoveredIndex: Int?
}

final class ZoneOverlayWindow: NSWindow {
    private var hostingView: NSHostingView<ZoneOverlayContent>?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let hosting = NSHostingView(rootView: ZoneOverlayContent(preview: ZoneOverlayPreview()))
        hostingView = hosting
        contentView = hosting
    }

    func updateScreen(_ screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    func showZonePreview(_ preview: ZoneOverlayPreview) {
        guard let hostingView else { return }
        hostingView.rootView = ZoneOverlayContent(preview: preview)
        orderFrontRegardless()
    }

    func hidePreview() {
        guard let hostingView else { return }
        hostingView.rootView = ZoneOverlayContent(preview: ZoneOverlayPreview())
        orderOut(nil)
    }
}

struct ZoneOverlayContent: View {
    let preview: ZoneOverlayPreview

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(preview.zoneFrames.enumerated()), id: \.offset) { index, frame in
                let local = convertToLocal(frame: frame, in: geometry.size)
                let isHovered = preview.hoveredIndex == index
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(isHovered ? 0.35 : 0.15))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                Color.accentColor.opacity(isHovered ? 1 : 0.5),
                                lineWidth: isHovered ? 2 : 1
                            )
                    )
                    .frame(width: local.width, height: local.height)
                    .position(x: local.midX, y: local.midY)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: isHovered)
            }
        }
        .allowsHitTesting(false)
    }

    private func convertToLocal(frame: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: frame.origin.x,
            y: size.height - frame.origin.y - frame.height,
            width: frame.width,
            height: frame.height
        )
    }
}
