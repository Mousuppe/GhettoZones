import AppKit
import SwiftUI

/// Interactive full-display overlay for editing zones at real size.
@MainActor
final class ZoneScreenEditorWindow: NSWindow {
    private var hostingView: PassThroughHostingView<ZoneScreenEditorRoot>?
    private(set) var displayID: CGDirectDisplayID
    weak var editorPanel: NSWindow?

    init(display: DisplayInfo, session: ZoneScreenEditorSession) {
        displayID = display.id
        let frame = display.visibleFrame
        super.init(
            contentRect: frame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        setFrame(frame, display: true)
        level = .floating
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isReleasedWhenClosed = false

        let root = ZoneScreenEditorRoot(session: session, referenceFrame: frame)
        let hosting = PassThroughHostingView(rootView: root)
        hosting.excludedFramesProvider = { [weak self] in
            guard let panel = self?.editorPanel, panel.isVisible else { return [] }
            // Inflate slightly so window shadow / traffic lights stay clickable.
            return [panel.frame.insetBy(dx: -8, dy: -8)]
        }
        hostingView = hosting
        contentView = hosting
    }

    override var canBecomeKey: Bool { true }

    func update(display: DisplayInfo, session: ZoneScreenEditorSession) {
        displayID = display.id
        let frame = display.visibleFrame
        setFrame(frame, display: true)
        hostingView?.rootView = ZoneScreenEditorRoot(session: session, referenceFrame: frame)
    }

    func showEditor() {
        orderFrontRegardless()
    }

    func hideEditor() {
        orderOut(nil)
    }
}

/// Clicks that land on the control panel pass through to that window underneath.
private final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    var excludedFramesProvider: (() -> [CGRect])?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let window else { return super.hitTest(point) }

        // `point` is in the superview's coordinate system.
        let pointInWindow = superview?.convert(point, to: nil) ?? convert(point, to: nil)
        let screenPoint = window.convertToScreen(NSRect(origin: pointInWindow, size: .init(width: 1, height: 1))).origin

        for frame in excludedFramesProvider?() ?? [] where frame.contains(screenPoint) {
            return nil
        }
        return super.hitTest(point)
    }
}

@MainActor
final class ZoneScreenEditorSession: ObservableObject {
    @Published var layout: ZoneLayout
    @Published var selectedZoneID: UUID?
    @Published var snapGuides: [SnapGuide] = []

    var onRequestClose: (() -> Void)?

    let minZoneSize: CGFloat = 0.04
    let snapPoints: CGFloat = 10

    init(layout: ZoneLayout, selectedZoneID: UUID? = nil) {
        self.layout = layout
        self.selectedZoneID = selectedZoneID
    }

    func selectZone(_ id: UUID?) {
        selectedZoneID = id
    }

    func setZoneFrame(id: UUID, frame: CGRect) {
        guard let index = layout.zones.firstIndex(where: { $0.id == id }) else { return }
        var updated = layout
        updated.zones[index].frame = ZoneEdgeSnapper.clamp(frame)
        layout = updated
    }

    func appendZone(_ zone: Zone) {
        var updated = layout
        updated.zones.append(zone)
        layout = updated
        selectedZoneID = zone.id
    }

    func deleteSelected() {
        guard let id = selectedZoneID else { return }
        var updated = layout
        updated.zones.removeAll { $0.id == id }
        layout = updated
        selectedZoneID = nil
    }
}

struct ZoneScreenEditorRoot: View {
    @ObservedObject var session: ZoneScreenEditorSession
    let referenceFrame: CGRect

    @State private var drag: DragSession?
    @State private var drawingStart: CGPoint?
    @State private var drawingCurrent: CGPoint?

    private struct DragSession {
        enum Kind {
            case move
            case resize(ResizeHandle)
        }
        let zoneID: UUID
        let kind: Kind
        let startFrame: CGRect
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size
            ZStack {
                // Backdrop for drawing / deselect — behind zones.
                Rectangle()
                    .fill(Color.black.opacity(0.12))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        endDrag()
                        session.selectZone(nil)
                    }
                    .gesture(backgroundDrawGesture(canvasSize: size))

                snapGuideOverlay(canvasSize: size)

                ForEach(session.layout.zones) { zone in
                    zoneBody(zone: zone, canvasSize: size)
                        .zIndex(session.selectedZoneID == zone.id ? 5 : 1)
                }

                if let selectedID = session.selectedZoneID,
                   let zone = session.layout.zones.first(where: { $0.id == selectedID }) {
                    ForEach(ResizeHandle.allCases, id: \.self) { handle in
                        resizeHandleView(handle, zone: zone, canvasSize: size)
                            .zIndex(20)
                    }
                }

                if let start = drawingStart, let current = drawingCurrent {
                    let rect = pixelRect(from: start, to: current)
                    RoundedRectangle(cornerRadius: 10)
                        .strokeBorder(Color.white, lineWidth: 2)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.2)))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                        .allowsHitTesting(false)
                }

                overlayChrome
                    .zIndex(30)
            }
            .frame(width: size.width, height: size.height)
            .onDeleteCommand { session.deleteSelected() }
        }
    }

    private var overlayChrome: some View {
        VStack {
            HStack(spacing: 10) {
                Text(session.layout.name.isEmpty
                     ? NSLocalizedString("Zone Editor", comment: "Overlay title fallback")
                     : session.layout.name)
                    .font(.headline)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())

                if let selected = session.layout.zones.first(where: { $0.id == session.selectedZoneID }) {
                    Text(String(format: NSLocalizedString("Selected: %@", comment: "Selected zone chip"), selected.name))
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.85), in: Capsule())
                        .foregroundStyle(.white)
                }

                Spacer()

                Button {
                    session.onRequestClose?()
                } label: {
                    Text(NSLocalizedString("Save & Close", comment: "Close on-screen editor"))
                        .fontWeight(.semibold)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(16)
            Spacer()
        }
    }

    // MARK: - Zones

    private func zoneBody(zone: Zone, canvasSize: CGSize) -> some View {
        let local = localRect(for: zone.frame, canvasSize: canvasSize)
        let isSelected = session.selectedZoneID == zone.id

        return RoundedRectangle(cornerRadius: 12)
            .fill(Color.accentColor.opacity(isSelected ? 0.38 : 0.22))
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(
                        isSelected ? Color.white : Color.accentColor,
                        lineWidth: isSelected ? 3 : 2
                    )
            )
            .overlay(
                VStack(spacing: 6) {
                    Text(zone.name)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                    if isSelected {
                        Text(NSLocalizedString("Drag body to move · drag white handles to resize", comment: "Selected zone hint"))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                }
                .padding(12)
            )
            .frame(width: max(local.width, 1), height: max(local.height, 1))
            .contentShape(Rectangle())
            .position(x: local.midX, y: local.midY)
            .onTapGesture {
                endDrag()
                session.selectZone(zone.id)
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        if session.selectedZoneID != zone.id {
                            endDrag()
                            session.selectZone(zone.id)
                        }
                        beginMoveIfNeeded(zone: zone)
                        applyMove(value: value, canvasSize: canvasSize)
                    }
                    .onEnded { _ in
                        endDrag()
                    }
            )
    }

    private func resizeHandleView(_ handle: ResizeHandle, zone: Zone, canvasSize: CGSize) -> some View {
        let point = handlePoint(handle, frame: zone.frame, canvasSize: canvasSize)
        return Circle()
            .fill(Color.white)
            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2))
            .frame(width: 18, height: 18)
            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
            .padding(12)
            .contentShape(Rectangle())
            .position(point)
            .highPriorityGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        beginResizeIfNeeded(zone: zone, handle: handle)
                        applyResize(value: value, canvasSize: canvasSize)
                    }
                    .onEnded { _ in
                        endDrag()
                    }
            )
    }

    private func snapGuideOverlay(canvasSize: CGSize) -> some View {
        Canvas { context, size in
            for guide in session.snapGuides {
                var path = Path()
                switch guide.axis {
                case .vertical:
                    let x = guide.position * size.width
                    path.move(to: CGPoint(x: x, y: 0))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                case .horizontal:
                    let y = (1 - guide.position) * size.height
                    path.move(to: CGPoint(x: 0, y: y))
                    path.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(path, with: .color(.yellow.opacity(0.95)), lineWidth: 1.5)
            }
        }
        .allowsHitTesting(false)
    }

    // MARK: - Gestures

    private func backgroundDrawGesture(canvasSize: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                guard drag == nil else { return }
                if drawingStart == nil {
                    drawingStart = value.startLocation
                    session.selectZone(nil)
                }
                drawingCurrent = value.location
            }
            .onEnded { _ in
                finishDrawing(canvasSize: canvasSize)
            }
    }

    private func beginMoveIfNeeded(zone: Zone) {
        if case .move = drag?.kind, drag?.zoneID == zone.id { return }
        drag = DragSession(zoneID: zone.id, kind: .move, startFrame: zone.frame)
    }

    private func beginResizeIfNeeded(zone: Zone, handle: ResizeHandle) {
        if case .resize(let current) = drag?.kind, drag?.zoneID == zone.id, current == handle {
            return
        }
        drag = DragSession(zoneID: zone.id, kind: .resize(handle), startFrame: zone.frame)
        session.selectZone(zone.id)
    }

    private func applyMove(value: DragGesture.Value, canvasSize: CGSize) {
        guard let drag, case .move = drag.kind else { return }
        let dx = value.translation.width / canvasSize.width
        let dy = -value.translation.height / canvasSize.height
        var frame = ZoneEdgeSnapper.movedFrame(start: drag.startFrame, dx: dx, dy: dy)
        let others = session.layout.zones.filter { $0.id != drag.zoneID }.map(\.frame)
        let snapped = ZoneEdgeSnapper.snapMove(
            frame,
            otherFrames: others,
            thresholdX: ZoneEdgeSnapper.normalizedThreshold(points: session.snapPoints, axisLength: canvasSize.width),
            thresholdY: ZoneEdgeSnapper.normalizedThreshold(points: session.snapPoints, axisLength: canvasSize.height),
            enabled: !NSEvent.modifierFlags.contains(.option)
        )
        frame = snapped.frame
        session.snapGuides = snapped.guides
        session.setZoneFrame(id: drag.zoneID, frame: frame)
    }

    private func applyResize(value: DragGesture.Value, canvasSize: CGSize) {
        guard let drag, case .resize(let handle) = drag.kind else { return }
        let dx = value.translation.width / canvasSize.width
        let dy = -value.translation.height / canvasSize.height
        var frame = ZoneEdgeSnapper.resizedFrame(
            start: drag.startFrame,
            handle: handle,
            dx: dx,
            dy: dy,
            minSize: session.minZoneSize
        )
        let others = session.layout.zones.filter { $0.id != drag.zoneID }.map(\.frame)
        let snapped = ZoneEdgeSnapper.snapResize(
            frame,
            edges: ZoneEdgeSnapper.edges(for: handle),
            otherFrames: others,
            thresholdX: ZoneEdgeSnapper.normalizedThreshold(points: session.snapPoints, axisLength: canvasSize.width),
            thresholdY: ZoneEdgeSnapper.normalizedThreshold(points: session.snapPoints, axisLength: canvasSize.height),
            enabled: !NSEvent.modifierFlags.contains(.option)
        )
        frame = snapped.frame
        session.snapGuides = snapped.guides
        session.setZoneFrame(id: drag.zoneID, frame: frame)
    }

    private func endDrag() {
        drag = nil
        session.snapGuides = []
    }

    private func finishDrawing(canvasSize: CGSize) {
        defer {
            drawingStart = nil
            drawingCurrent = nil
        }
        guard let start = drawingStart, let end = drawingCurrent else { return }
        let normalized = normalizedRect(from: start, to: end, canvasSize: canvasSize)
        guard normalized.width >= session.minZoneSize, normalized.height >= session.minZoneSize else { return }
        let count = session.layout.zones.count + 1
        session.appendZone(
            Zone(
                name: String(format: NSLocalizedString("Zone %d", comment: "Default zone name"), count),
                frame: normalized
            )
        )
    }

    // MARK: - Geometry

    private func localRect(for normalized: CGRect, canvasSize: CGSize) -> CGRect {
        let x = normalized.origin.x * canvasSize.width
        let width = normalized.width * canvasSize.width
        let height = normalized.height * canvasSize.height
        let y = (1 - normalized.origin.y - normalized.height) * canvasSize.height
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private func handlePoint(_ handle: ResizeHandle, frame: CGRect, canvasSize: CGSize) -> CGPoint {
        let local = localRect(for: frame, canvasSize: canvasSize)
        switch handle {
        case .topLeft: return CGPoint(x: local.minX, y: local.minY)
        case .top: return CGPoint(x: local.midX, y: local.minY)
        case .topRight: return CGPoint(x: local.maxX, y: local.minY)
        case .left: return CGPoint(x: local.minX, y: local.midY)
        case .right: return CGPoint(x: local.maxX, y: local.midY)
        case .bottomLeft: return CGPoint(x: local.minX, y: local.maxY)
        case .bottom: return CGPoint(x: local.midX, y: local.maxY)
        case .bottomRight: return CGPoint(x: local.maxX, y: local.maxY)
        }
    }

    private func pixelRect(from start: CGPoint, to end: CGPoint) -> CGRect {
        let x = min(start.x, end.x)
        let y = min(start.y, end.y)
        return CGRect(x: x, y: y, width: abs(end.x - start.x), height: abs(end.y - start.y))
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, canvasSize: CGSize) -> CGRect {
        let x1 = min(start.x, end.x) / canvasSize.width
        let x2 = max(start.x, end.x) / canvasSize.width
        let yTop = min(start.y, end.y) / canvasSize.height
        let yBottom = max(start.y, end.y) / canvasSize.height
        return CGRect(x: x1, y: 1 - yBottom, width: x2 - x1, height: yBottom - yTop)
    }
}
