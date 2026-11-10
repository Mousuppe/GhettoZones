import CoreGraphics
import Foundation

enum ZoneEdgeSnapper {
    /// Snap threshold in normalized layout units (0…1), derived from on-screen points.
    static func normalizedThreshold(points: CGFloat, axisLength: CGFloat) -> CGFloat {
        guard axisLength > 0 else { return 0.01 }
        return points / axisLength
    }

    /// Snaps while resizing (only the dragged edges move).
    static func snapResize(
        _ frame: CGRect,
        edges: Set<SnapEdge>,
        otherFrames: [CGRect],
        thresholdX: CGFloat,
        thresholdY: CGFloat,
        enabled: Bool
    ) -> (frame: CGRect, guides: [SnapGuide]) {
        guard enabled else { return (frame, []) }

        var result = frame
        var guides: [SnapGuide] = []
        let (xTargets, yTargets) = targets(from: otherFrames)

        if edges.contains(.left), let snap = nearest(result.minX, in: xTargets, threshold: thresholdX) {
            let delta = snap.value - result.minX
            result.origin.x += delta
            result.size.width -= delta
            guides.append(SnapGuide(axis: .vertical, position: snap.value))
        }
        if edges.contains(.right), let snap = nearest(result.maxX, in: xTargets, threshold: thresholdX) {
            result.size.width += snap.value - result.maxX
            guides.append(SnapGuide(axis: .vertical, position: snap.value))
        }
        if edges.contains(.bottom), let snap = nearest(result.minY, in: yTargets, threshold: thresholdY) {
            let delta = snap.value - result.minY
            result.origin.y += delta
            result.size.height -= delta
            guides.append(SnapGuide(axis: .horizontal, position: snap.value))
        }
        if edges.contains(.top), let snap = nearest(result.maxY, in: yTargets, threshold: thresholdY) {
            result.size.height += snap.value - result.maxY
            guides.append(SnapGuide(axis: .horizontal, position: snap.value))
        }

        return (clamp(result), guides)
    }

    /// Snaps while moving (keeps size; aligns any edge to nearby targets).
    static func snapMove(
        _ frame: CGRect,
        otherFrames: [CGRect],
        thresholdX: CGFloat,
        thresholdY: CGFloat,
        enabled: Bool
    ) -> (frame: CGRect, guides: [SnapGuide]) {
        guard enabled else { return (frame, []) }

        var result = frame
        var guides: [SnapGuide] = []
        let (xTargets, yTargets) = targets(from: otherFrames)

        if let snap = nearest(result.minX, in: xTargets, threshold: thresholdX) {
            result.origin.x = snap.value
            guides.append(SnapGuide(axis: .vertical, position: snap.value))
        } else if let snap = nearest(result.maxX, in: xTargets, threshold: thresholdX) {
            result.origin.x = snap.value - result.width
            guides.append(SnapGuide(axis: .vertical, position: snap.value))
        }

        if let snap = nearest(result.minY, in: yTargets, threshold: thresholdY) {
            result.origin.y = snap.value
            guides.append(SnapGuide(axis: .horizontal, position: snap.value))
        } else if let snap = nearest(result.maxY, in: yTargets, threshold: thresholdY) {
            result.origin.y = snap.value - result.height
            guides.append(SnapGuide(axis: .horizontal, position: snap.value))
        }

        return (clamp(result), guides)
    }

    static func edges(for handle: ResizeHandle) -> Set<SnapEdge> {
        switch handle {
        case .left: return [.left]
        case .right: return [.right]
        case .top: return [.top]
        case .bottom: return [.bottom]
        case .topLeft: return [.top, .left]
        case .topRight: return [.top, .right]
        case .bottomLeft: return [.bottom, .left]
        case .bottomRight: return [.bottom, .right]
        }
    }

    private static func targets(from otherFrames: [CGRect]) -> (x: [CGFloat], y: [CGFloat]) {
        var xTargets: [CGFloat] = [0, 1]
        var yTargets: [CGFloat] = [0, 1]
        for other in otherFrames {
            xTargets.append(contentsOf: [other.minX, other.maxX])
            yTargets.append(contentsOf: [other.minY, other.maxY])
        }
        return (xTargets, yTargets)
    }

    /// Applies resize delta in normalized coordinates from a frozen start frame (avoids jitter).
    static func resizedFrame(
        start: CGRect,
        handle: ResizeHandle,
        dx: CGFloat,
        dy: CGFloat,
        minSize: CGFloat
    ) -> CGRect {
        var frame = start
        switch handle {
        case .left:
            frame.origin.x += dx
            frame.size.width -= dx
        case .right:
            frame.size.width += dx
        case .top:
            frame.size.height += dy
            frame.origin.y -= dy
        case .bottom:
            frame.origin.y += dy
            frame.size.height -= dy
        case .topLeft:
            frame.origin.x += dx
            frame.size.width -= dx
            frame.size.height += dy
            frame.origin.y -= dy
        case .topRight:
            frame.size.width += dx
            frame.size.height += dy
            frame.origin.y -= dy
        case .bottomLeft:
            frame.origin.x += dx
            frame.size.width -= dx
            frame.origin.y += dy
            frame.size.height -= dy
        case .bottomRight:
            frame.size.width += dx
            frame.origin.y += dy
            frame.size.height -= dy
        }
        frame.size.width = max(minSize, frame.size.width)
        frame.size.height = max(minSize, frame.size.height)
        return clamp(frame)
    }

    static func movedFrame(start: CGRect, dx: CGFloat, dy: CGFloat) -> CGRect {
        var frame = start
        frame.origin.x += dx
        frame.origin.y += dy
        frame.origin.x = max(0, min(1 - frame.width, frame.origin.x))
        frame.origin.y = max(0, min(1 - frame.height, frame.origin.y))
        return frame
    }

    static func clamp(_ frame: CGRect) -> CGRect {
        var result = frame
        result.size.width = max(0.02, min(1, result.size.width))
        result.size.height = max(0.02, min(1, result.size.height))
        result.origin.x = max(0, min(1 - result.size.width, result.origin.x))
        result.origin.y = max(0, min(1 - result.size.height, result.origin.y))
        return result
    }

    private static func nearest(
        _ value: CGFloat,
        in targets: [CGFloat],
        threshold: CGFloat
    ) -> (value: CGFloat, distance: CGFloat)? {
        var best: (value: CGFloat, distance: CGFloat)?
        for target in targets {
            let distance = abs(target - value)
            guard distance <= threshold else { continue }
            if best == nil || distance < best!.distance {
                best = (target, distance)
            }
        }
        return best
    }
}

enum SnapEdge {
    case left, right, top, bottom, horizontalCenter, verticalCenter
}

struct SnapGuide: Equatable {
    enum Axis { case horizontal, vertical }
    var axis: Axis
    var position: CGFloat
}

enum ResizeHandle: CaseIterable, Hashable {
    case topLeft, top, topRight, left, right, bottomLeft, bottom, bottomRight
}
