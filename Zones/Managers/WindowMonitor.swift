import AppKit
import ApplicationServices
import Combine

@MainActor
final class WindowMonitor {
    static let shared = WindowMonitor()

    private var eventTapMonitor: CGEventTapMonitor?
    private var fallbackMouseMonitor: Any?
    private var fallbackLocalMonitor: Any?
    private var draggedWindow: AXUIElement?
    private var draggedBundleID: String?
    private var initialWindowFrame: CGRect?
    private var isCommandDragActive = false
    private var commandInvolvedInDrag = false
    private var isLeftMouseDown = false
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
        stopFallbackMonitors()
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
        eventTapMonitor?.stop()
        eventTapMonitor = nil

        let monitor = CGEventTapMonitor(eventTypes: [
            .leftMouseDown,
            .leftMouseDragged,
            .leftMouseUp,
            .flagsChanged
        ]) { [weak self] event, type in
            DispatchQueue.main.async {
                self?.handleCGEvent(event, type: type)
            }
        }

        if monitor.start() {
            eventTapMonitor = monitor
            stopFallbackMonitors()
        } else {
            startFallbackMonitors()
        }
    }

    private func startFallbackMonitors() {
        guard fallbackMouseMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .leftMouseDragged, .leftMouseUp, .flagsChanged]
        fallbackMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
        }
        fallbackLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            self?.handleNSEvent(event)
            return event
        }
    }

    private func stopFallbackMonitors() {
        if let monitor = fallbackMouseMonitor {
            NSEvent.removeMonitor(monitor)
            fallbackMouseMonitor = nil
        }
        if let monitor = fallbackLocalMonitor {
            NSEvent.removeMonitor(monitor)
            fallbackLocalMonitor = nil
        }
    }

    @MainActor
    private func handleNSEvent(_ event: NSEvent) {
        guard let cgEvent = event.cgEvent else { return }
        let type: CGEventType
        switch event.type {
        case .leftMouseDown: type = .leftMouseDown
        case .leftMouseDragged: type = .leftMouseDragged
        case .leftMouseUp: type = .leftMouseUp
        case .flagsChanged: type = .flagsChanged
        default: return
        }
        handleCGEvent(cgEvent, type: type)
    }

    var isListeningForDragEvents: Bool {
        eventTapMonitor?.isRunning == true || fallbackMouseMonitor != nil
    }

    @MainActor
    private func handleCGEvent(_ event: CGEvent, type: CGEventType) {
        guard let zoneManager, zoneManager.snappingEnabled else { return }

        if !isListeningForDragEvents {
            startEventTap()
        }

        let point = pointerLocation(for: event, type: type)

        switch type {
        case .leftMouseDown:
            isLeftMouseDown = true
            windowLookupAttempts = 0
            captureDraggedWindow(at: point)

        case .leftMouseDragged:
            isLeftMouseDown = true
            resolveDraggedWindowIfNeeded(at: point)
            if event.isCommandPressed {
                commandInvolvedInDrag = true
                beginCommandDragIfNeeded()
                continueCommandDrag(at: point)
            } else if isCommandDragActive {
                cancelCommandDragPreview()
            }

        case .leftMouseUp:
            isLeftMouseDown = false
            resolveDraggedWindowIfNeeded(at: point)
            ensureDraggedWindowForSnap(at: point)
            if commandInvolvedInDrag {
                snapIfPointerInZone(at: point)
            }
            finishCommandDragSession()
            resetDragState()

        case .flagsChanged:
            guard isLeftMouseDown else { return }
            resolveDraggedWindowIfNeeded(at: point)
            if event.isCommandPressed {
                commandInvolvedInDrag = true
                beginCommandDragIfNeeded()
                continueCommandDrag(at: point)
            } else if isCommandDragActive || commandInvolvedInDrag {
                ensureDraggedWindowForSnap(at: point)
                snapIfPointerInZone(at: point)
                cancelCommandDragPreview()
            }

        default:
            break
        }
    }

    private func pointerLocation(for event: CGEvent, type: CGEventType) -> NSPoint {
        if type == .flagsChanged {
            return NSEvent.mouseLocation
        }
        return event.appKitScreenPoint
    }

    private func captureDraggedWindow(at point: NSPoint) {
        if let window = WindowAccessibility.windowElementUnderCursor(at: point),
           !isUserTyping(in: window) {
            draggedWindow = window
            draggedBundleID = bundleIdentifier(for: window)
            initialWindowFrame = WindowAccessibility.windowFrame(window)
        } else if let window = WindowAccessibility.frontmostWindow(),
                  !isUserTyping(in: window) {
            draggedWindow = window
            draggedBundleID = bundleIdentifier(for: window)
            initialWindowFrame = WindowAccessibility.windowFrame(window)
        } else {
            draggedWindow = nil
            draggedBundleID = nil
            initialWindowFrame = nil
        }
    }

    private func resolveDraggedWindowIfNeeded(at point: NSPoint) {
        guard draggedWindow == nil, windowLookupAttempts < 30 else { return }
        windowLookupAttempts += 1
        if let window = WindowAccessibility.windowElementUnderCursor(at: point),
           !isUserTyping(in: window) {
            draggedWindow = window
            draggedBundleID = bundleIdentifier(for: window)
            initialWindowFrame = WindowAccessibility.windowFrame(window)
        } else if windowLookupAttempts > 5, let window = WindowAccessibility.frontmostWindow(),
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
        isLeftMouseDown = false
        commandInvolvedInDrag = false
    }

    @MainActor
    private func beginCommandDragIfNeeded() {
        guard !isCommandDragActive else { return }
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
    private func finishCommandDragSession() {
        zoneManager?.highlightedZoneID = nil
        previewDisplayID = nil
        hideAllPreviews()
        isCommandDragActive = false
    }

    @MainActor
    private func ensureDraggedWindowForSnap(at point: NSPoint) {
        guard draggedWindow == nil else { return }
        if let window = WindowAccessibility.windowElementUnderCursor(at: point),
           !isUserTyping(in: window) {
            draggedWindow = window
            draggedBundleID = bundleIdentifier(for: window)
        } else if let window = WindowAccessibility.frontmostWindow(),
                  !isUserTyping(in: window) {
            draggedWindow = window
            draggedBundleID = bundleIdentifier(for: window)
        }
    }

    @MainActor
    @discardableResult
    private func snapIfPointerInZone(at point: NSPoint) -> Bool {
        guard let zoneManager, let window = draggedWindow else { return false }

        let displayID = previewDisplayID
            ?? zoneManager.displayManager.display(for: point)?.id
        guard let displayID,
              let layout = zoneManager.activeLayout(for: displayID),
              let zone = zoneForSnap(at: point, displayID: displayID, layout: layout, zoneManager: zoneManager) else {
            return false
        }

        snapWindow(window, to: zone, displayID: displayID, zoneManager: zoneManager, layout: layout)
        return true
    }

    @MainActor
    private func endCommandDragSession(snap: Bool, at point: NSPoint? = nil) {
        if snap, let point {
            snapIfPointerInZone(at: point)
        }
        finishCommandDragSession()
    }

    private func zoneForSnap(
        at point: NSPoint?,
        displayID: CGDirectDisplayID,
        layout: ZoneLayout,
        zoneManager: ZoneManager
    ) -> Zone? {
        if let highlightedID = zoneManager.highlightedZoneID,
           let zone = layout.zones.first(where: { $0.id == highlightedID }) {
            return zone
        }
        if let point {
            return zoneManager.zone(at: point, on: displayID)
        }
        return nil
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
        WindowAccessibility.setWindowFrame(window, frame: frame)
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
        WindowAccessibility.setWindowFrame(window, frame: newFrame)
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

}
