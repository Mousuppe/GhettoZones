import ApplicationServices
import AppKit

enum AccessibilityChecker {
    /// Returns true when Accessibility permission is active for this process.
    /// Prefer `AXIsProcessTrusted`; fall back to a live AX probe because macOS can lag after grant.
    static func isGranted() -> Bool {
        if AXIsProcessTrusted() { return true }
        return probeAXAccess()
    }

    /// Read access alone is not enough to resize windows — verify AX can modify a standard app window.
    /// Must not call `isGranted()` (that would recurse when permission checks chain through here).
    static func canModifyWindows() -> Bool {
        guard AXIsProcessTrusted() || probeAXAccess() else { return false }
        guard let window = focusedWindowForPermissionCheck() else { return true }
        var sizeSettable = DarwinBoolean(false)
        var positionSettable = DarwinBoolean(false)
        let sizeOK = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success
            && sizeSettable.boolValue
        let positionOK = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success
            && positionSettable.boolValue
        return sizeOK && positionOK
    }

    private static func focusedWindowForPermissionCheck() -> AXUIElement? {
        guard let window = WindowAccessibility.focusedWindow() else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return window }
        if pid == ProcessInfo.processInfo.processIdentifier { return nil }
        return window
    }

    /// macOS can lag updating `AXIsProcessTrusted` after the user grants access.
    /// Probe the API directly to detect working access.
    private static func probeAXAccess() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedApp: CFTypeRef?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        if appResult == .success { return true }

        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindow
        )
        if windowResult == .success { return true }

        return false
    }
}
