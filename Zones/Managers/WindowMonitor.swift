import AppKit
import ApplicationServices
import Combine

@MainActor
final class WindowMonitor {
    static let shared = WindowMonitor()

    private var eventTapMonitor: CGEventTapMonitor?
    private var draggedWindow: AXUIElement?
    private var draggedBundleID: String?
    private var initialWindowFrame: CGRect?
    private var isCommandDragActive = false
    private var windowLookupAttempts = 0
    private weak var zoneManager: ZoneManager?
    private var overlayWindows: [CGDirectDisplayID: ZoneOverlayWindow] = [:]
    private var previewDisplayID: CGDirectDisplayID?

    private init() {}

    func start(zoneManager: ZoneManager) {
        self.zoneManager = zoneManager
        stop()
        setupOverlayWindows()
        startEventTap()
    }

    func stop() {
        eventTapMonitor?.stop()
        eventTapMonitor = nil
        endCommandDragSession(snap: false)
        hideAllPreviews()
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        resetDragState()
    }

    func refreshOverlays() {
        setupOverlayWindows()
        if isCommandDragActive {
            updateZonePreview(at: NSEvent.mouseLocation)
        }
    }

    // MARK: - Event tap

    private func startEventTap() {
        let monitor = CGEventTapMonitor(eventTypes: [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .flagsChanged
        ]) { [weak self] event, type in
            Task { @MainActor in
                self?.handleCGEvent(event, type: type)
            }
        }

        if monitor.start() {
            eventTapMonitor = monitor
        }
    }

    @MainActor
    private func handleCGEvent(_ event: CGEvent, type: CGEventType) {
        guard let zoneManager, zoneManager.snappingEnabled, zoneManager.isAccessibilityGranted else { return }

        let point = event.appKitScreenPoint

        switch type {
        case .leftMouseDown:
            windowLookupAttempts = 0
            if let window = WindowAccessibility.windowElementUnderCursor(at: point),
               !isUserTyping(in: window) {
                draggedWindow = window
                draggedBundleID = bundleIdentifier(for: window)
                initialWindowFrame = WindowAccessibility.windowFrame(window)
            } else {
                draggedWindow = nil
                draggedBundleID = nil
                initialWindowFrame = nil
            }

        case .leftMouseDragged:
            resolveDraggedWindowIfNeeded(at: point)
            guard draggedWindow != nil else { return }
            if event.isCommandPressed {
                beginCommandDragIfNeeded()
                continueCommandDrag(at: point)
            } else if isCommandDragActive {
                cancelCommandDragPreview()
            }

        case .leftMouseUp:
            if isCommandDragActive {
                endCommandDragSession(snap: true, at: point)
            } else {
                endCommandDragSession(snap: false)
            }
            resetDragState()

        case .flagsChanged:
            if draggedWindow != nil {
                if event.isCommandPressed {
                    beginCommandDragIfNeeded()
                    continueCommandDrag(at: point)
                } else if isCommandDragActive {
                    cancelCommandDragPreview()
                }
            }

        default:
            break
        }
    }

    private func resolveDraggedWindowIfNeeded(at point: NSPoint) {
        guard draggedWindow == nil, windowLookupAttempts < 20 else { return }
        windowLookupAttempts += 1
        if let window = WindowAccessibility.windowElementUnderCursor(at: point),
           !isUserTyping(in: window) {
            draggedWindow = window
            draggedBundleID = bundleIdentifier(for: window)
            initialWindowFrame = WindowAccessibility.windowFrame(window)
        }
    }

    private func resetDragState() {
        draggedWindow = nil
        draggedBundleID = nil
        initialWindowFrame = nil
        windowLookupAttempts = 0
    }

    @MainActor
    private func beginCommandDragIfNeeded() {
        guard !isCommandDragActive, draggedWindow != nil else { return }
        isCommandDragActive = true
    }

    @MainActor
    private func continueCommandDrag(at point: NSPoint) {
        guard isCommandDragActive else { return }
        updateZonePreview(at: point)
    }

    @MainActor
    private func cancelCommandDragPreview() {
        zoneManager?.highlightedZoneID = nil
        previewDisplayID = nil
        hideAllPreviews()
        isCommandDragActive = false
    }

    @MainActor
    private func endCommandDragSession(snap: Bool, at point: NSPoint? = nil) {
        defer {
            zoneManager?.highlightedZoneID = nil
            previewDisplayID = nil
            hideAllPreviews()
            isCommandDragActive = false
        }

        guard snap,
              let zoneManager,
              let window = draggedWindow,
              let point,
              let display = zoneManager.displayManager.display(for: point),
              let zone = zoneManager.zone(at: point, on: display.id),
              let layout = zoneManager.activeLayout(for: display.id) else { return }

        snapWindow(window, to: zone, displayID: display.id, zoneManager: zoneManager, layout: layout)
    }

    @MainActor
    private func updateZonePreview(at point: NSPoint) {
        guard let zoneManager,
              let display = zoneManager.displayManager.display(for: point),
              let layout = zoneManager.activeLayout(for: display.id) else {
            zoneManager?.highlightedZoneID = nil
            hideAllPreviews()
            return
        }

        previewDisplayID = display.id

        let zoneFrames = layout.zones.compactMap {
            zoneManager.displayManager.absoluteFrame(for: $0, on: display.id)
        }
        let hoveredZone = zoneManager.zone(at: point, on: display.id)
        let hoveredIndex = hoveredZone.flatMap { zone in layout.zones.firstIndex(where: { $0.id == zone.id }) }

        zoneManager.highlightedZoneID = hoveredZone?.id

        for (displayID, overlay) in overlayWindows {
            if displayID == display.id {
                overlay.showZonePreview(ZoneOverlayPreview(zoneFrames: zoneFrames, hoveredIndex: hoveredIndex))
            } else {
                overlay.hidePreview()
            }
        }
    }

    // MARK: - Snapping

    @MainActor
    func snapFocusedWindow(to zone: Zone, on displayID: CGDirectDisplayID, zoneManager: ZoneManager) {
        guard let window = focusedWindowElement(),
              !isUserTyping(in: window),
              let layout = zoneManager.activeLayout(for: displayID) else { return }
        draggedBundleID = bundleIdentifier(for: window)
        snapWindow(window, to: zone, displayID: displayID, zoneManager: zoneManager, layout: layout)
        draggedBundleID = nil
    }

    @MainActor
    func snapApp(bundleIdentifier: String, to zone: Zone, layout: ZoneLayout, displayID: CGDirectDisplayID, zoneManager: ZoneManager) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier).first else { return }
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        guard let window = firstStandardWindow(of: appElement) else { return }
        snapWindow(window, to: zone, displayID: displayID, zoneManager: zoneManager, layout: layout, remember: false)
    }

    @MainActor
    private func snapWindow(
        _ window: AXUIElement,
        to zone: Zone,
        displayID: CGDirectDisplayID,
        zoneManager: ZoneManager,
        layout: ZoneLayout,
        remember: Bool = true
    ) {
        guard let frame = zoneManager.displayManager.absoluteFrame(for: zone, on: displayID) else { return }
        setWindowFrame(window, frame: frame)
        if remember, let bundleID = draggedBundleID ?? bundleIdentifier(for: window) {
            zoneManager.rememberPosition(
                bundleIdentifier: bundleID,
                zone: zone,
                layout: layout,
                displayID: displayID
            )
        }
    }

    @MainActor
    func moveFocusedWindowToAdjacentMonitor(direction: ZoneDirection, zoneManager: ZoneManager) {
        guard let window = focusedWindowElement(), !isUserTyping(in: window) else { return }
        guard var currentFrame = WindowAccessibility.windowFrame(window) else { return }
        let center = CGPoint(x: currentFrame.midX, y: currentFrame.midY)
        guard let currentDisplay = zoneManager.displayManager.display(for: NSPoint(x: center.x, y: center.y)) else { return }

        let displays = zoneManager.displayManager.displays
        guard displays.count > 1, let currentIndex = displays.firstIndex(where: { $0.id == currentDisplay.id }) else { return }

        let nextIndex: Int
        switch direction {
        case .left, .down:
            nextIndex = (currentIndex - 1 + displays.count) % displays.count
        case .right, .up:
            nextIndex = (currentIndex + 1) % displays.count
        }

        let targetDisplay = displays[nextIndex]
        let relativeX = (center.x - currentDisplay.visibleFrame.origin.x) / currentDisplay.visibleFrame.width
        let relativeY = (center.y - currentDisplay.visibleFrame.origin.y) / currentDisplay.visibleFrame.height
        let newWidth = min(currentFrame.width, targetDisplay.visibleFrame.width)
        let newHeight = min(currentFrame.height, targetDisplay.visibleFrame.height)
        let newFrame = CGRect(
            x: targetDisplay.visibleFrame.origin.x + relativeX * targetDisplay.visibleFrame.width - newWidth / 2,
            y: targetDisplay.visibleFrame.origin.y + relativeY * targetDisplay.visibleFrame.height - newHeight / 2,
            width: newWidth,
            height: newHeight
        )
        setWindowFrame(window, frame: newFrame)
    }

    // MARK: - Overlay

    @MainActor
    private func setupOverlayWindows() {
        guard let zoneManager else { return }
        let displayIDs = Set(zoneManager.displayManager.displays.map(\.id))
        for (id, window) in overlayWindows where !displayIDs.contains(id) {
            window.orderOut(nil)
            overlayWindows.removeValue(forKey: id)
        }
        for display in zoneManager.displayManager.displays {
            if overlayWindows[display.id] == nil {
                overlayWindows[display.id] = ZoneOverlayWindow(screen: display.screen)
            } else {
                overlayWindows[display.id]?.updateScreen(display.screen)
            }
        }
    }

    @MainActor
    private func hideAllPreviews() {
        overlayWindows.values.forEach { $0.hidePreview() }
    }

    // MARK: - AX helpers

    func focusedWindowElement() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focused) == .success,
              let element = focused else { return nil }
        return (element as! AXUIElement)
    }

    func currentFocusedZone(on displayID: CGDirectDisplayID, zoneManager: ZoneManager) -> Zone? {
        guard let window = focusedWindowElement(),
              let frame = WindowAccessibility.windowFrame(window),
              let display = zoneManager.displayManager.display(for: NSPoint(x: frame.midX, y: frame.midY)) else { return nil }
        return zoneManager.zone(at: NSPoint(x: frame.midX, y: frame.midY), on: display.id)
    }

    private func bundleIdentifier(for window: AXUIElement) -> String? {
        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success,
              let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        return app.bundleIdentifier
    }

    private func firstStandardWindow(of app: AXUIElement) -> AXUIElement? {
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else { return nil }
        return windows.first { isStandardWindow($0) }
    }

    private func isStandardWindow(_ window: AXUIElement) -> Bool {
        var subrole: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
              let role = subrole as? String else { return true }
        return role == kAXStandardWindowSubrole
    }

    private func isUserTyping(in window: AXUIElement) -> Bool {
        var focusedRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXFocusedUIElementAttribute as CFString, &focusedRef) == .success,
              let focused = focusedRef else { return false }
        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return false }
        return role == kAXTextFieldRole || role == kAXTextAreaRole
    }

    private func setWindowFrame(_ window: AXUIElement, frame: CGRect) {
        var position = frame.origin
        var size = frame.size
        if let positionValue = AXValueCreate(.cgPoint, &position) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, positionValue)
        }
        if let sizeValue = AXValueCreate(.cgSize, &size) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, sizeValue)
        }
    }
}
