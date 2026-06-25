import AppKit
import ApplicationServices
import Combine

@MainActor
final class WindowMonitor {
    static let shared = WindowMonitor()

    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var draggedWindow: AXUIElement?
    private var draggedBundleID: String?
    private var isMouseDragging = false
    private var isOptionDragActive = false
    private weak var zoneManager: ZoneManager?
    private var overlayWindows: [CGDirectDisplayID: ZoneOverlayWindow] = [:]
    private var previewDisplayID: CGDirectDisplayID?

    private init() {}

    func start(zoneManager: ZoneManager) {
        self.zoneManager = zoneManager
        stop()
        setupOverlayWindows()

        let events: NSEvent.EventTypeMask = [.leftMouseDragged, .leftMouseUp, .flagsChanged]
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseEvent(event)
            }
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: events) { [weak self] event in
            Task { @MainActor in
                self?.handleMouseEvent(event)
            }
            return event
        }
    }

    func stop() {
        if let monitor = globalMouseMonitor {
            NSEvent.removeMonitor(monitor)
            globalMouseMonitor = nil
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
            localMouseMonitor = nil
        }
        endOptionDragSession(snap: false)
        hideAllPreviews()
        overlayWindows.values.forEach { $0.orderOut(nil) }
        overlayWindows.removeAll()
        draggedWindow = nil
        isMouseDragging = false
        isOptionDragActive = false
    }

    func refreshOverlays() {
        setupOverlayWindows()
        if isOptionDragActive {
            updateZonePreview(at: NSEvent.mouseLocation)
        }
    }

    // MARK: - Mouse handling

    @MainActor
    private func handleMouseEvent(_ event: NSEvent) {
        guard let zoneManager, zoneManager.snappingEnabled, zoneManager.isAccessibilityGranted else { return }

        switch event.type {
        case .leftMouseDragged:
            isMouseDragging = true
            if isOptionPressed(for: event) {
                beginOptionDragIfNeeded()
                continueOptionDrag(at: NSEvent.mouseLocation)
            } else if isOptionDragActive {
                cancelOptionDragPreview()
            }
        case .leftMouseUp:
            if isOptionDragActive && isOptionPressed(for: event) {
                endOptionDragSession(snap: true, at: NSEvent.mouseLocation)
            } else {
                endOptionDragSession(snap: false)
            }
            isMouseDragging = false
        case .flagsChanged:
            if isMouseDragging {
                if isOptionPressed(for: event) {
                    beginOptionDragIfNeeded()
                    continueOptionDrag(at: NSEvent.mouseLocation)
                } else if isOptionDragActive {
                    cancelOptionDragPreview()
                }
            }
        default:
            break
        }
    }

    private func isOptionPressed(for event: NSEvent) -> Bool {
        event.modifierFlags.contains(.option)
    }

    @MainActor
    private func beginOptionDragIfNeeded() {
        guard !isOptionDragActive else { return }
        guard let window = focusedWindowElement(), !isUserTyping(in: window) else { return }
        draggedWindow = window
        draggedBundleID = bundleIdentifier(for: window)
        isOptionDragActive = true
    }

    @MainActor
    private func continueOptionDrag(at point: NSPoint) {
        guard isOptionDragActive else { return }
        updateZonePreview(at: point)
    }

    @MainActor
    private func cancelOptionDragPreview() {
        zoneManager?.highlightedZoneID = nil
        previewDisplayID = nil
        hideAllPreviews()
        isOptionDragActive = false
        draggedWindow = nil
        draggedBundleID = nil
    }

    @MainActor
    private func endOptionDragSession(snap: Bool, at point: NSPoint? = nil) {
        defer {
            zoneManager?.highlightedZoneID = nil
            previewDisplayID = nil
            hideAllPreviews()
            isOptionDragActive = false
            draggedWindow = nil
            draggedBundleID = nil
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
        guard var currentFrame = windowFrame(window) else { return }
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
              let frame = windowFrame(window),
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

    private func windowFrame(_ window: AXUIElement) -> CGRect? {
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
