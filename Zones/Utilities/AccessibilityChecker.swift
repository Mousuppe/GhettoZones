import ApplicationServices
import AppKit

enum AccessibilityChecker {
    /// Returns true when Accessibility permission is active for this process.
    static func isGranted() -> Bool {
        if AXIsProcessTrusted() { return true }
        return probeAXAccess()
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
