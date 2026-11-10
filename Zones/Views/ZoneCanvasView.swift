import SwiftUI

struct ZoneCanvasView: View {
    @Binding var layout: ZoneLayout
    @Binding var selectedZoneID: UUID?
    let displayFrame: CGRect

    @State private var drawingStart: CGPoint?
    @State private var drawingCurrent: CGPoint?
    @State private var resizingZoneID: UUID?
    @State private var resizeHandle: ResizeHandle?
    @State private var resizeStartFrame: CGRect?
    @State private var moveZoneID: UUID?
    @State private var moveStartOrigin: CGPoint?

    private let gridSpacing: CGFloat = 20
    private let minZoneSize: CGFloat = 0.05

    var body: some View {
        GeometryReader { geometry in
            let canvasSize = geometry.size
            ZStack {
                gridBackground(size: canvasSize)
                ForEach(layout.zones) { zone in
                    zoneView(zone: zone, canvasSize: canvasSize)
                }
                if let start = drawingStart, let current = drawingCurrent {
                    let rect = normalizedRect(from: start, to: current, canvasSize: canvasSize)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.2))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.accentColor, lineWidth: 1.5))
                        .frame(width: rect.width * canvasSize.width, height: rect.height * canvasSize.height)
                        .position(
                            x: rect.midX * canvasSize.width,
                            y: (1 - rect.midY) * canvasSize.height
                        )
                }
            }
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
            .gesture(
                DragGesture(minimumDistance: 4)
                    .onChanged { value in
                        guard resizingZoneID == nil, selectedZoneID == nil else { return }
                        if drawingStart == nil { drawingStart = value.startLocation }
                        drawingCurrent = value.location
                    }
                    .onEnded { _ in
                        guard resizingZoneID == nil, selectedZoneID == nil else { return }
                        if drawingStart != nil {
                            finishDrawing(canvasSize: canvasSize)
                        }
                    }
            )
            .onDeleteCommand {
                deleteSelectedZone()
            }
        }
        .aspectRatio(displayFrame.width / displayFrame.height, contentMode: .fit)
    }

    // MARK: - Zone rendering

    @ViewBuilder
    private func zoneView(zone: Zone, canvasSize: CGSize) -> some View {
        let rect = zone.frame
        let isSelected = selectedZoneID == zone.id
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.accentColor.opacity(isSelected ? 0.35 : 0.2))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(isSelected ? Color.accentColor : Color.accentColor.opacity(0.6), lineWidth: isSelected ? 2 : 1)
                )
            VStack(spacing: 4) {
                Image(systemName: "macwindow")
                    .font(.title2)
                    .foregroundStyle(.secondary)
                Text(zone.name)
                    .font(.caption)
                    .lineLimit(1)
            }
            if isSelected {
                resizeHandles(for: zone, canvasSize: canvasSize)
            }
        }
        .frame(width: rect.width * canvasSize.width, height: rect.height * canvasSize.height)
        .position(x: rect.midX * canvasSize.width, y: (1 - rect.midY) * canvasSize.height)
        .onTapGesture { selectedZoneID = zone.id }
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    guard isSelected, resizingZoneID == nil else { return }
                    updateMove(value: value, zoneID: zone.id, canvasSize: canvasSize)
                }
                .onEnded { _ in
                    finishMove()
                }
        )
    }

    @ViewBuilder
    private func resizeHandles(for zone: Zone, canvasSize: CGSize) -> some View {
        ForEach(ResizeHandle.allCases, id: \.self) { handle in
            Circle()
                .fill(Color.accentColor)
                .frame(width: 10, height: 10)
                .padding(6)
                .contentShape(Rectangle())
                .position(handlePosition(handle, zone: zone, canvasSize: canvasSize))
                .highPriorityGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if resizingZoneID == nil {
                                resizingZoneID = zone.id
                                resizeHandle = handle
                                resizeStartFrame = zone.frame
                            }
                            updateResize(value: value, canvasSize: canvasSize)
                        }
                        .onEnded { _ in
                            finishResize(zoneID: zone.id)
                        }
                )
        }
    }

    private func handlePosition(_ handle: ResizeHandle, zone: Zone, canvasSize: CGSize) -> CGPoint {
        let r = zone.frame
        let local: CGPoint
        switch handle {
        case .topLeft: local = CGPoint(x: 0, y: 0)
        case .topRight: local = CGPoint(x: r.width * canvasSize.width, y: 0)
        case .bottomLeft: local = CGPoint(x: 0, y: r.height * canvasSize.height)
        case .bottomRight: local = CGPoint(x: r.width * canvasSize.width, y: r.height * canvasSize.height)
        case .top: local = CGPoint(x: r.width * canvasSize.width / 2, y: 0)
        case .bottom: local = CGPoint(x: r.width * canvasSize.width / 2, y: r.height * canvasSize.height)
        case .left: local = CGPoint(x: 0, y: r.height * canvasSize.height / 2)
        case .right: local = CGPoint(x: r.width * canvasSize.width, y: r.height * canvasSize.height / 2)
        }
        return local
    }

    // MARK: - Grid

    @ViewBuilder
    private func gridBackground(size: CGSize) -> some View {
        Canvas { context, canvasSize in
            var path = Path()
            stride(from: 0, through: canvasSize.width, by: gridSpacing).forEach { x in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: canvasSize.height))
            }
            stride(from: 0, through: canvasSize.height, by: gridSpacing).forEach { y in
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: canvasSize.width, y: y))
            }
            context.stroke(path, with: .color(.secondary.opacity(0.15)), lineWidth: 0.5)
        }
    }

    private func setZoneFrame(at index: Int, frame: CGRect) {
        var updated = layout
        updated.zones[index].frame = frame
        layout = updated
    }

    private func appendZone(_ zone: Zone) {
        var updated = layout
        updated.zones.append(zone)
        layout = updated
    }

    private func removeZone(id: UUID) {
        var updated = layout
        updated.zones.removeAll { $0.id == id }
        layout = updated
    }

    private func finishDrawing(canvasSize: CGSize) {
        guard let start = drawingStart, let end = drawingCurrent else { return }
        let rect = normalizedRect(from: start, to: end, canvasSize: canvasSize)
        guard rect.width >= minZoneSize, rect.height >= minZoneSize else {
            drawingStart = nil
            drawingCurrent = nil
            return
        }
        let count = layout.zones.count + 1
        let newZone = Zone(
            name: String(format: NSLocalizedString("Zone %d", comment: "Default zone name"), count),
            frame: rect
        )
        appendZone(newZone)
        selectedZoneID = newZone.id
        drawingStart = nil
        drawingCurrent = nil
    }

    private func normalizedRect(from start: CGPoint, to end: CGPoint, canvasSize: CGSize) -> CGRect {
        let x1 = min(start.x, end.x) / canvasSize.width
        let x2 = max(start.x, end.x) / canvasSize.width
        let y1 = 1 - max(start.y, end.y) / canvasSize.height
        let y2 = 1 - min(start.y, end.y) / canvasSize.height
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
    }

    // MARK: - Move & resize

    private func updateMove(value: DragGesture.Value, zoneID: UUID, canvasSize: CGSize) {
        guard let index = layout.zones.firstIndex(where: { $0.id == zoneID }) else { return }
        if moveZoneID != zoneID {
            moveZoneID = zoneID
            moveStartOrigin = layout.zones[index].frame.origin
        }
        guard let startOrigin = moveStartOrigin else { return }
        var frame = layout.zones[index].frame
        frame.origin.x = startOrigin.x + value.translation.width / canvasSize.width
        frame.origin.y = startOrigin.y - value.translation.height / canvasSize.height
        frame.origin.x = max(0, min(1 - frame.width, frame.origin.x))
        frame.origin.y = max(0, min(1 - frame.height, frame.origin.y))
        setZoneFrame(at: index, frame: frame)
    }

    private func finishMove() {
        moveZoneID = nil
        moveStartOrigin = nil
    }

    private func updateResize(value: DragGesture.Value, canvasSize: CGSize) {
        guard let zoneID = resizingZoneID,
              let handle = resizeHandle,
              let startFrame = resizeStartFrame,
              let index = layout.zones.firstIndex(where: { $0.id == zoneID }) else { return }
        var frame = startFrame
        let dx = value.translation.width / canvasSize.width
        let dy = -value.translation.height / canvasSize.height
        switch handle {
        case .left: frame.origin.x += dx; frame.size.width -= dx
        case .right: frame.size.width += dx
        case .top: frame.size.height += dy; frame.origin.y -= dy
        case .bottom: frame.origin.y += dy; frame.size.height -= dy
        case .topLeft: frame.origin.x += dx; frame.size.width -= dx; frame.size.height += dy; frame.origin.y -= dy
        case .topRight: frame.size.width += dx; frame.size.height += dy; frame.origin.y -= dy
        case .bottomLeft: frame.origin.x += dx; frame.size.width -= dx; frame.origin.y += dy; frame.size.height -= dy
        case .bottomRight: frame.size.width += dx; frame.origin.y += dy; frame.size.height -= dy
        }
        frame.size.width = max(minZoneSize, frame.size.width)
        frame.size.height = max(minZoneSize, frame.size.height)
        setZoneFrame(at: index, frame: frame)
    }

    private func finishResize(zoneID: UUID) {
        resizingZoneID = nil
        resizeHandle = nil
        resizeStartFrame = nil
        selectedZoneID = zoneID
    }

    private func deleteSelectedZone() {
        guard let id = selectedZoneID else { return }
        removeZone(id: id)
        selectedZoneID = nil
    }
}

