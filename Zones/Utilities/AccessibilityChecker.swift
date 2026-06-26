import ApplicationServices
import AppKit

enum AccessibilityChecker {
    /// Returns true when Accessibility permission is active for this process.
    static func isGranted() -> Bool {
        if AXIsProcessTrusted() { return true }
        return probeAXAccess()
    }

    /// Read access alone is not enough to resize windows — verify AX can modify the focused window.
    static func canModifyWindows() -> Bool {
        guard isGranted() else { return false }
        guard let window = WindowAccessibility.focusedWindow() else { return AXIsProcessTrusted() }
        var sizeSettable = DarwinBoolean(false)
        var positionSettable = DarwinBoolean(false)
        let sizeOK = AXUIElementIsAttributeSettable(window, kAXSizeAttribute as CFString, &sizeSettable) == .success
            && sizeSettable.boolValue
        let positionOK = AXUIElementIsAttributeSettable(window, kAXPositionAttribute as CFString, &positionSettable) == .success
            && positionSettable.boolValue
        return sizeOK && positionOK
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
