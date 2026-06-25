import AppKit
import ApplicationServices
import CoreGraphics

enum WindowAccessibility {
    /// Returns the standard window under the cursor, using AX first then CGWindowList.
    static func windowElementUnderCursor(at point: NSPoint) -> AXUIElement? {
        if let window = windowFromAccessibility(at: point) {
            return window
        }
        return windowFromWindowList(at: point)
    }

    private static func windowFromAccessibility(at point: NSPoint) -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let axPoint = point.quartzScreenPoint
        let result = AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &element
        )
        guard result == .success, let element else { return nil }
        return resolveWindow(from: element)
    }

    private static func resolveWindow(from element: AXUIElement) -> AXUIElement? {
        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == kAXWindowRole {
            return isStandardWindow(element) ? element : nil
        }

        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXWindowAttribute as CFString, &windowRef) == .success,
           let windowRef {
            let window = windowRef as! AXUIElement
            return isStandardWindow(window) ? window : nil
        }

        var topLevelRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXTopLevelUIElementAttribute as CFString, &topLevelRef) == .success,
           let topLevelRef {
            let topLevel = topLevelRef as! AXUIElement
            if isStandardWindow(topLevel) { return topLevel }
        }

        return nil
    }

    private static func windowFromWindowList(at point: NSPoint) -> AXUIElement? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let mainHeight = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0

        for info in infoList {
            guard let boundsDict = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = boundsDict["X"],
                  let y = boundsDict["Y"],
                  let width = boundsDict["Width"],
                  let height = boundsDict["Height"],
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }

            let appKitBounds = CGRect(
                x: x,
                y: mainHeight - y - height,
                width: width,
                height: height
            )
            guard appKitBounds.contains(point) else { continue }

            if let ownerName = info[kCGWindowOwnerName as String] as? String,
               ["Dock", "WindowManager", "GhettoZones"].contains(ownerName) {
                continue
            }

            if let window = windowElement(for: ownerPID, expectedBounds: appKitBounds) {
                return window
            }
        }

        return nil
    }

    private static func windowElement(for pid: pid_t, expectedBounds: CGRect) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return nil
        }

        for window in windows where isStandardWindow(window) {
            if let frame = windowFrame(window), framesMatch(frame, expectedBounds) {
                return window
            }
        }

        return windows.first(where: isStandardWindow(_:))
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String else {
            return true
        }
        return subrole == kAXStandardWindowSubrole
    }

    static func windowFrame(_ window: AXUIElement) -> CGRect? {
        var positionRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let positionRef, let sizeRef else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        AXValueGetValue(positionRef as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeRef as! AXValue, .cgSize, &size)
        return CGRect(origin: position, size: size)
    }
}
