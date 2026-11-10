import AppKit
import ApplicationServices
import CoreGraphics

enum WindowAccessibility {
    /// Returns the standard window under the cursor, using AX first then CGWindowList.
    static func windowElementUnderCursor(at point: NSPoint, preferWindowList: Bool = false) -> AXUIElement? {
        if preferWindowList, let window = windowFromWindowList(at: point) {
            return window
        }
        if let window = windowFromAccessibility(at: point) {
            return window
        }
        return windowFromWindowList(at: point)
    }

    static func focusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
              let focusedRef else { return nil }
        let window = focusedRef as! AXUIElement
        return isStandardWindow(window) ? window : nil
    }

    static func frontmostWindow(for pid: pid_t) -> AXUIElement? {
        let appElement = AXUIElementCreateApplication(pid)
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(appElement, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let windowRef {
            let window = windowRef as! AXUIElement
            if isStandardWindow(window) { return window }
        }
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first(where: isStandardWindow(_:))
    }

    static func windowMatching(frame: CGRect) -> AXUIElement? {
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
            guard framesMatch(appKitBounds, frame, tolerance: 8) else { continue }

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

    /// Focused window of the frontmost app — fallback while dragging.
    static func frontmostWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &appRef
        ) == .success,
              let appRef else { return nil }

        let app = appRef as! AXUIElement
        var windowRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &windowRef) == .success,
           let windowRef {
            let window = windowRef as! AXUIElement
            if isStandardWindow(window) { return window }
        }

        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first(where: isStandardWindow(_:))
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
        var current: AXUIElement? = element
        for _ in 0..<25 {
            guard let el = current else { break }

            var roleRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef) == .success,
               let role = roleRef as? String,
               role == kAXWindowRole,
               isStandardWindow(el) {
                return el
            }

            var windowRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXWindowAttribute as CFString, &windowRef) == .success,
               let windowRef {
                let window = windowRef as! AXUIElement
                if isStandardWindow(window) { return window }
            }

            var topLevelRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXTopLevelUIElementAttribute as CFString, &topLevelRef) == .success,
               let topLevelRef {
                let topLevel = topLevelRef as! AXUIElement
                if isStandardWindow(topLevel) { return topLevel }
            }

            var parentRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(el, kAXParentAttribute as CFString, &parentRef) == .success,
               let parentRef {
                current = (parentRef as! AXUIElement)
            } else {
                break
            }
        }

        return nil
    }

    private static func windowFromWindowList(at point: NSPoint) -> AXUIElement? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let infoList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        let quartzPoint = point.quartzScreenPoint

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

            let quartzBounds = CGRect(x: x, y: y, width: width, height: height)
            guard quartzBounds.contains(CGPoint(x: quartzPoint.x, y: quartzPoint.y)) else { continue }

            if let ownerName = info[kCGWindowOwnerName as String] as? String,
               ["Dock", "WindowManager", "GhettoZones"].contains(ownerName) {
                continue
            }

            let mainHeight = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
            let appKitBounds = CGRect(
                x: x,
                y: mainHeight - y - height,
                width: width,
                height: height
            )

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

        for window in windows where isResizableWindow(window) {
            if let frame = windowFrame(window), framesMatch(frame, expectedBounds) {
                return window
            }
        }

        return windows.first(where: isResizableWindow(_:))
    }

    private static func framesMatch(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(lhs.origin.x - rhs.origin.x) <= tolerance
            && abs(lhs.origin.y - rhs.origin.y) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private static func isResizableWindow(_ window: AXUIElement) -> Bool {
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String,
              role == kAXWindowRole else {
            return false
        }

        var subroleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subroleRef) == .success,
              let subrole = subroleRef as? String else {
            return true
        }

        let excludedSubroles: Set<String> = [
            kAXFloatingWindowSubrole as String,
            kAXSystemDialogSubrole as String,
        ]
        return !excludedSubroles.contains(subrole)
    }

    private static func isStandardWindow(_ window: AXUIElement) -> Bool {
        isResizableWindow(window)
    }

    /// Global AppKit maxY used to convert to/from Accessibility (Quartz) coordinates.
    private static var axCoordinateSpaceHeight: CGFloat {
        NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
    }

    /// AppKit bottom-left frame for an AX window (converts from Quartz top-left AX position).
    static func windowFrame(_ window: AXUIElement) -> CGRect? {
        guard let axTopLeft = rawAXPosition(window),
              let size = windowSize(window) else { return nil }
        let appKitOrigin = CGPoint(
            x: axTopLeft.x,
            y: axCoordinateSpaceHeight - axTopLeft.y - size.height
        )
        return CGRect(origin: appKitOrigin, size: size)
    }

    struct SetFrameResult {
        var success: Bool
        var before: CGRect?
        var after: CGRect?
        var sizeError: Int
        var positionError: Int
    }

    /// Resize and move a window to fill a zone frame (yabai / Rectangle triple-set pattern).
    /// `frame` is in AppKit global coordinates (origin bottom-left).
    @discardableResult
    static func setWindowFrame(_ window: AXUIElement, frame: CGRect) -> Bool {
        setWindowFrameDetailed(window, frame: frame).success
    }

    @discardableResult
    static func setWindowFrameDetailed(_ window: AXUIElement, frame: CGRect) -> SetFrameResult {
        let target = frame.integral
        let before = windowFrame(window)

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else {
            return SetFrameResult(success: false, before: before, after: nil, sizeError: -1, positionError: -1)
        }
        if let app = NSRunningApplication(processIdentifier: pid) {
            app.activate(options: [.activateAllWindows])
        }

        let appElement = AXUIElementCreateApplication(pid)
        let hadEnhancedUI = disableEnhancedUIIfNeeded(appElement)

        // Raise the window so apps that ignore AX while backgrounded still accept resize.
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)

        let sizeError1 = setWindowSize(window, size: target.size)
        let positionError = setWindowPosition(window, appKitBottomLeft: target.origin, size: target.size)
        let sizeError2 = setWindowSize(window, size: target.size)
        // Second position pass — some apps clamp the first move against the old size.
        let positionError2 = setWindowPosition(window, appKitBottomLeft: target.origin, size: target.size)

        if hadEnhancedUI {
            AXUIElementSetAttributeValue(
                appElement,
                "AXEnhancedUserInterface" as CFString,
                kCFBooleanTrue
            )
        }

        let after = windowFrame(window)
        let matched = after.map { framesMatch($0, target, tolerance: 12) } ?? false
        return SetFrameResult(
            success: matched,
            before: before,
            after: after,
            sizeError: sizeError2 != 0 ? sizeError2 : sizeError1,
            positionError: positionError2 != 0 ? positionError2 : positionError
        )
    }

    private static func rawAXPosition(_ window: AXUIElement) -> CGPoint? {
        var positionRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionRef) == .success,
              let positionRef else { return nil }
        var position = CGPoint.zero
        guard AXValueGetValue(positionRef as! AXValue, .cgPoint, &position) else { return nil }
        return position
    }

    private static func windowSize(_ window: AXUIElement) -> CGSize? {
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let sizeRef else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(sizeRef as! AXValue, .cgSize, &size) else { return nil }
        return size
    }

    /// Sets AX position from an AppKit bottom-left origin + size (AX wants Quartz top-left).
    @discardableResult
    private static func setWindowPosition(
        _ window: AXUIElement,
        appKitBottomLeft: CGPoint,
        size: CGSize
    ) -> Int {
        var axTopLeft = CGPoint(
            x: appKitBottomLeft.x,
            y: axCoordinateSpaceHeight - appKitBottomLeft.y - size.height
        )
        guard let value = AXValueCreate(.cgPoint, &axTopLeft) else { return -2 }
        return Int(AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value).rawValue)
    }

    @discardableResult
    private static func setWindowSize(_ window: AXUIElement, size: CGSize) -> Int {
        var dimensions = size
        guard let value = AXValueCreate(.cgSize, &dimensions) else { return -2 }
        return Int(AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value).rawValue)
    }

    private static func disableEnhancedUIIfNeeded(_ appElement: AXUIElement) -> Bool {
        var enhancedUIRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, &enhancedUIRef) == .success,
              let enabled = enhancedUIRef as? Bool,
              enabled else { return false }
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanFalse)
        return true
    }
}
