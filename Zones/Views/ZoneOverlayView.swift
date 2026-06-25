import AppKit
import SwiftUI

struct ZoneOverlayPreview {
    var zoneFrames: [CGRect] = []
    var hoveredIndex: Int?
}

final class ZoneOverlayWindow: NSWindow {
    private var hostingView: NSHostingView<ZoneOverlayContent>?
    private var referenceFrame: CGRect = .zero

    init(screen: NSScreen) {
        let frame = screen.visibleFrame
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        referenceFrame = frame
        setFrame(frame, display: true)
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        let hosting = NSHostingView(rootView: ZoneOverlayContent(referenceFrame: frame, preview: ZoneOverlayPreview()))
        hostingView = hosting
        contentView = hosting
    }

    func updateScreen(_ screen: NSScreen) {
        referenceFrame = screen.visibleFrame
        setFrame(screen.visibleFrame, display: true)
        hostingView?.rootView = ZoneOverlayContent(referenceFrame: referenceFrame, preview: ZoneOverlayPreview())
    }

    func showZonePreview(_ preview: ZoneOverlayPreview) {
        guard let hostingView else { return }
        hostingView.rootView = ZoneOverlayContent(referenceFrame: referenceFrame, preview: preview)
        orderFrontRegardless()
    }

    func hidePreview() {
        guard let hostingView else { return }
        hostingView.rootView = ZoneOverlayContent(referenceFrame: referenceFrame, preview: ZoneOverlayPreview())
        orderOut(nil)
    }
}

struct ZoneOverlayContent: View {
    let referenceFrame: CGRect
    let preview: ZoneOverlayPreview

    var body: some View {
        GeometryReader { geometry in
            ForEach(Array(preview.zoneFrames.enumerated()), id: \.offset) { index, frame in
                let local = convertToLocal(frame: frame, in: geometry.size)
                let isHovered = preview.hoveredIndex == index
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.blue.opacity(isHovered ? 0.35 : 0.18))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(
                                Color.blue.opacity(isHovered ? 0.95 : 0.55),
                                lineWidth: isHovered ? 2.5 : 1.5
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
        let localX = frame.origin.x - referenceFrame.origin.x
        let localBottomY = frame.origin.y - referenceFrame.origin.y
        let localTopY = size.height - localBottomY - frame.height
        return CGRect(x: localX, y: localTopY, width: frame.width, height: frame.height)
    }
}
