import AppKit
import SwiftUI

final class ZoneOverlayWindow: NSWindow {
    private var hostingView: NSHostingView<ZoneOverlayContent>?

    init(screen: NSScreen) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false,
            screen: screen
        )
        level = .screenSaver
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        let content = ZoneOverlayContent(highlightFrame: nil)
        let hosting = NSHostingView(rootView: content)
        hostingView = hosting
        contentView = hosting
    }

    func updateScreen(_ screen: NSScreen) {
        setFrame(screen.frame, display: true)
    }

    func showZoneHighlight(frame: CGRect) {
        guard let hostingView else { return }
        hostingView.rootView = ZoneOverlayContent(highlightFrame: frame)
        orderFrontRegardless()
    }

    func hideHighlight() {
        guard let hostingView else { return }
        hostingView.rootView = ZoneOverlayContent(highlightFrame: nil)
    }
}

struct ZoneOverlayContent: View {
    let highlightFrame: CGRect?

    var body: some View {
        GeometryReader { geometry in
            if let frame = highlightFrame {
                let local = convertToLocal(frame: frame, in: geometry.size)
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.25))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .strokeBorder(Color.accentColor, lineWidth: 2)
                    )
                    .frame(width: local.width, height: local.height)
                    .position(x: local.midX, y: local.midY)
                    .transition(.opacity)
                    .animation(.spring(response: 0.2, dampingFraction: 0.7), value: highlightFrame)
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
