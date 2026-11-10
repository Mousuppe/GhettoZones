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
    private var lastHoveredZoneID: UUID?
    private var lastHoveredDisplayID: CGDirectDisplayID?
    private var draggedWindowPID: pid_t?
    private var pendingSnapContext: SnapContext?
    private var snapTask: Task<Void, Never>?
    private var dragStartPoint: NSPoint?
    private var didRestorePreSnapSize = false
    private var preSnapFrames: [PreSnapRecord] = []

    private struct SnapContext {
        let window: AXUIElement?
        let zone: Zone
        let layout: ZoneLayout
        let displayID: CGDirectDisplayID
        let frame: CGRect
        let bundleID: String?
        let windowPID: pid_t?
        let fallbackFrame: CGRect?
    }

    /// Remembers the window's free size before a zone snap so a later drag can restore it.
    private struct PreSnapRecord {
        let pid: pid_t
        var previousFrame: CGRect
        var snappedFrame: CGRect
    }

    private static let snapRetryDelays: [TimeInterval] = [0.08, 0.18, 0.3, 0.45, 0.65, 0.9, 1.2]
    private static let restoreDragThreshold: CGFloat = 4

    private init() {}

    func start(zoneManager: ZoneManager) {
        self.zoneManager = zoneManager
        stop()
        SnapDebugLog.clear()
        SnapDebugLog.log(
            "WindowMonitor start snapping=\(zoneManager.snappingEnabled) ax=\(zoneManager.isAccessibilityGranted) displays=\(zoneManager.displayManager.displays.count)"
        )
        setupOverlayWindows()
        startEventTap()
        SnapDebugLog.log("eventTap running=\(eventTapMonitor?.isRunning == true) fallback=\(fallbackMouseMonitor != nil)")
    }

    func stop() {
        snapTask?.cancel()
        snapTask = nil
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
            // Capture location/flags immediately — the CGEvent may be reused after the tap returns.
            let point = type == .flagsChanged ? NSEvent.mouseLocation : event.appKitScreenPoint
            let commandPressed = event.isCommandPressed
            DispatchQueue.main.async {
                self?.handleCGEvent(type: type, point: point, commandPressed: commandPressed)
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
        let type: CGEventType
        switch event.type {
        case .leftMouseDown: type = .leftMouseDown
        case .leftMouseDragged: type = .leftMouseDragged
        case .leftMouseUp: type = .leftMouseUp
        case .flagsChanged: type = .flagsChanged
        default: return
        }
        handleCGEvent(
            type: type,
            point: NSEvent.mouseLocation,
            commandPressed: event.modifierFlags.contains(.command)
        )
    }

    var isListeningForDragEvents: Bool {
        eventTapMonitor?.isRunning == true || fallbackMouseMonitor != nil
    }

    @MainActor
    private func handleCGEvent(type: CGEventType, point: NSPoint, commandPressed: Bool) {
        guard let zoneManager, zoneManager.snappingEnabled, zoneManager.isAccessibilityGranted else { return }

        if !isListeningForDragEvents {
            startEventTap()
        }

        switch type {
        case .leftMouseDown:
            isLeftMouseDown = true
            windowLookupAttempts = 0
            didRestorePreSnapSize = false
            dragStartPoint = point
            captureDraggedWindow(at: point)
            if commandPressed {
                commandInvolvedInDrag = true
                beginCommandDragIfNeeded()
            }

        case .leftMouseDragged:
            isLeftMouseDown = true
            resolveDraggedWindowIfNeeded(at: point)
            maybeRestorePreSnapSize(at: point)
            if commandPressed {
                commandInvolvedInDrag = true
                refreshDraggedWindowDuringCommandDrag(at: point)
                beginCommandDragIfNeeded()
                continueCommandDrag(at: point)
            } else if isCommandDragActive {
                cancelCommandDragPreview()
            }

        case .leftMouseUp:
            isLeftMouseDown = false
            resolveDraggedWindowIfNeeded(at: point)
            ensureDraggedWindowForSnap(at: point)
            SnapDebugLog.log(
                "mouseUp point=\(point) cmdDrag=\(commandInvolvedInDrag) active=\(isCommandDragActive) hover=\(String(describing: lastHoveredZoneID)) pending=\(pendingSnapContext != nil) pid=\(String(describing: draggedWindowPID)) shouldSnap=\(shouldSnapOnRelease)"
            )
            if commandInvolvedInDrag || isCommandDragActive {
                refreshSnapTargetAtRelease(at: point)
            }
            if shouldSnapOnRelease {
                performSnap(at: point)
            } else {
                SnapDebugLog.log("mouseUp skipped snap (shouldSnapOnRelease=false)")
            }
            finishCommandDragSession()
            resetDragState()

        case .flagsChanged:
            guard isLeftMouseDown else { return }
            resolveDraggedWindowIfNeeded(at: point)
            if commandPressed {
                commandInvolvedInDrag = true
                beginCommandDragIfNeeded()
                continueCommandDrag(at: point)
            } else if isCommandDragActive || commandInvolvedInDrag {
                ensureDraggedWindowForSnap(at: point)
                refreshSnapTargetAtRelease(at: point)
                SnapDebugLog.log(
                    "commandRelease point=\(point) hover=\(String(describing: lastHoveredZoneID)) pending=\(pendingSnapContext != nil) shouldSnap=\(shouldSnapOnRelease)"
                )
                if shouldSnapOnRelease {
                    performSnap(at: point)
                }
                cancelCommandDragPreview()
            }

        default:
            break
        }
    }

    private func refreshDraggedWindowDuringCommandDrag(at point: NSPoint) {
        if let trackedPID = draggedWindowPID,
           let existing = draggedWindow,
           WindowAccessibility.windowFrame(existing) != nil {
            var pid: pid_t = 0
            if AXUIElementGetPid(existing, &pid) == .success, pid == trackedPID {
                return
            }
        }

        guard let window = WindowAccessibility.windowElementUnderCursor(at: point, preferWindowList: true),
              !isTextEntryAtCursor(point) else { return }

        var pid: pid_t = 0
        guard AXUIElementGetPid(window, &pid) == .success else { return }
        if let trackedPID = draggedWindowPID, trackedPID != pid { return }

        assignDraggedWindow(window, pid: pid)
    }

    private func assignDraggedWindow(_ window: AXUIElement, pid: pid_t? = nil) {
        draggedWindow = window
        draggedBundleID = bundleIdentifier(for: window)
        // Freeze free size at first capture of this gesture — later lookups must not
        // overwrite with a mid-drag / post-snap frame or restore remembers the zone size.
        if initialWindowFrame == nil {
            initialWindowFrame = WindowAccessibility.windowFrame(window)
        }
        if let pid {
            draggedWindowPID = pid
        } else {
            var resolvedPID: pid_t = 0
            if AXUIElementGetPid(window, &resolvedPID) == .success {
                draggedWindowPID = resolvedPID
            }
        }
    }

    private func captureDraggedWindow(at point: NSPoint) {
        if isTextEntryAtCursor(point) {
            draggedWindow = nil
            draggedBundleID = nil
            initialWindowFrame = nil
            draggedWindowPID = nil
            return
        }

        if let window = WindowAccessibility.windowElementUnderCursor(at: point) {
            assignDraggedWindow(window)
        } else if let window = WindowAccessibility.frontmostWindow() {
            assignDraggedWindow(window)
        } else {
            draggedWindow = nil
            draggedBundleID = nil
            initialWindowFrame = nil
            draggedWindowPID = nil
        }
    }

    private func resolveDraggedWindowIfNeeded(at point: NSPoint) {
        guard draggedWindow == nil, windowLookupAttempts < 30 else { return }
        windowLookupAttempts += 1
        if let window = WindowAccessibility.windowElementUnderCursor(at: point) {
            assignDraggedWindow(window)
        } else if windowLookupAttempts > 5, let window = WindowAccessibility.frontmostWindow() {
            assignDraggedWindow(window)
        }
    }

    private var shouldSnapOnRelease: Bool {
        commandInvolvedInDrag || isCommandDragActive || lastHoveredZoneID != nil || pendingSnapContext != nil
    }

    private func resetDragState() {
        draggedWindow = nil
        draggedBundleID = nil
        initialWindowFrame = nil
        windowLookupAttempts = 0
        isLeftMouseDown = false
        commandInvolvedInDrag = false
        lastHoveredZoneID = nil
        lastHoveredDisplayID = nil
        draggedWindowPID = nil
        pendingSnapContext = nil
        dragStartPoint = nil
        didRestorePreSnapSize = false
    }

    // MARK: - Pre-snap size restore

    func rememberPreSnapFrame(pid: pid_t, previous: CGRect?, snapped: CGRect) {
        guard pid > 0, let previous else {
            SnapDebugLog.log("rememberPreSnap skipped pid=\(pid) previousNil=\(previous == nil)")
            return
        }
        // Already snapped → snapped again: keep the original free size, update zone frame only.
        if let existingIndex = preSnapFrames.firstIndex(where: { $0.pid == pid }) {
            let existing = preSnapFrames[existingIndex]
            if WindowAccessibility.sizesMatch(existing.snappedFrame.size, previous.size, tolerance: 24)
                || WindowAccessibility.sizesMatch(previous.size, snapped.size, tolerance: 24) {
                preSnapFrames[existingIndex].snappedFrame = snapped
                SnapDebugLog.log(
                    "rememberPreSnap updateSnapOnly pid=\(pid) previous=\(existing.previousFrame.size) snapped=\(snapped.size)"
                )
                return
            }
            preSnapFrames[existingIndex] = PreSnapRecord(pid: pid, previousFrame: previous, snappedFrame: snapped)
            SnapDebugLog.log("rememberPreSnap replace pid=\(pid) previous=\(previous.size) snapped=\(snapped.size)")
            return
        }
        if WindowAccessibility.sizesMatch(previous.size, snapped.size, tolerance: 24) {
            SnapDebugLog.log("rememberPreSnap skipSameSize pid=\(pid) size=\(previous.size)")
            return
        }
        preSnapFrames.append(PreSnapRecord(pid: pid, previousFrame: previous, snappedFrame: snapped))
        SnapDebugLog.log(
            "rememberPreSnap store pid=\(pid) previous=\(previous.size) snapped=\(snapped.size) count=\(preSnapFrames.count)"
        )
        if preSnapFrames.count > 40 {
            preSnapFrames.removeFirst(preSnapFrames.count - 40)
        }
    }

    @MainActor
    private func maybeRestorePreSnapSize(at point: NSPoint) {
        guard !didRestorePreSnapSize else { return }
        guard let start = dragStartPoint else { return }
        let distance = hypot(point.x - start.x, point.y - start.y)
        guard distance >= Self.restoreDragThreshold else { return }

        guard let window = draggedWindow ?? resolveWindowForSnap(at: point),
              let current = WindowAccessibility.windowFrame(window) else {
            SnapDebugLog.log("restorePreSnap noWindow point=\(point)")
            return
        }

        var pid: pid_t = draggedWindowPID ?? 0
        if pid == 0 {
            _ = AXUIElementGetPid(window, &pid)
        }
        guard pid > 0, let index = preSnapFrames.firstIndex(where: { $0.pid == pid }) else {
            // Only log once per gesture once we've moved far enough; keep trying if pid resolves later.
            if pid > 0 {
                SnapDebugLog.log("restorePreSnap noRecord pid=\(pid) records=\(preSnapFrames.count)")
                didRestorePreSnapSize = true
            }
            return
        }

        let record = preSnapFrames[index]
        let previous = record.previousFrame
        let looksSnapped = WindowAccessibility.sizesMatch(current.size, record.snappedFrame.size, tolerance: 48)
            || (
                abs(current.height - record.snappedFrame.height) <= 48
                && abs(current.width - previous.width) > 24
            )
            || (
                abs(current.width - record.snappedFrame.width) <= 48
                && abs(current.height - previous.height) > 24
            )
        guard looksSnapped else {
            SnapDebugLog.log(
                "restorePreSnap notSnapped pid=\(pid) current=\(current.size) snapped=\(record.snappedFrame.size) previous=\(previous.size)"
            )
            // Don't burn the one-shot flag — window under cursor may still resolve next tick.
            return
        }
        guard previous.width > 50, previous.height > 50 else { return }
        guard !WindowAccessibility.sizesMatch(current.size, previous.size, tolerance: 8) else {
            preSnapFrames.remove(at: index)
            didRestorePreSnapSize = true
            SnapDebugLog.log("restorePreSnap alreadyFree pid=\(pid)")
            return
        }

        // Keep the cursor on the same relative spot of the title bar while restoring size.
        let relativeX = current.width > 0 ? (point.x - current.minX) / current.width : 0.5
        let clampedRelativeX = min(max(relativeX, 0.05), 0.95)
        let offsetFromTop = current.maxY - point.y
        let restoredSize = previous.size
        let newMaxY = point.y + offsetFromTop
        let restoredFrame = CGRect(
            x: point.x - clampedRelativeX * restoredSize.width,
            y: newMaxY - restoredSize.height,
            width: restoredSize.width,
            height: restoredSize.height
        )

        didRestorePreSnapSize = true
        preSnapFrames.remove(at: index)
        snapTask?.cancel()

        // Instant restore without activate/raise — those fight the live title-bar drag.
        SnapDebugLog.log("restorePreSnap apply pid=\(pid) from=\(current) to=\(restoredFrame)")
        let ok = WindowAccessibility.setWindowFrameDuringDrag(window, frame: restoredFrame)
        SnapDebugLog.log("restorePreSnap result ok=\(ok) after=\(String(describing: WindowAccessibility.windowFrame(window)?.size))")
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
        if let window = resolveWindowForSnap(at: point) {
            draggedWindow = window
            draggedBundleID = bundleIdentifier(for: window)
            var pid: pid_t = 0
            if AXUIElementGetPid(window, &pid) == .success {
                draggedWindowPID = pid
            }
        }
    }

    private func resolveWindowForSnap(at point: NSPoint) -> AXUIElement? {
        if let draggedWindow, WindowAccessibility.windowFrame(draggedWindow) != nil {
            return draggedWindow
        }
        if let pid = draggedWindowPID,
           let window = WindowAccessibility.frontmostWindow(for: pid) {
            return window
        }
        if let window = WindowAccessibility.windowElementUnderCursor(at: point, preferWindowList: true) {
            return window
        }
        if let window = WindowAccessibility.focusedWindow() {
            return window
        }
        if let window = WindowAccessibility.frontmostWindow() {
            return window
        }
        if let frame = initialWindowFrame,
           let window = WindowAccessibility.windowMatching(frame: frame) {
            return window
        }
        return nil
    }

    @MainActor
    private func performSnap(at point: NSPoint) {
        guard let zoneManager else { return }
        guard let context = resolvedSnapContext(at: point, zoneManager: zoneManager) else {
            SnapDebugLog.log("performSnap aborted — no snap context at \(point)")
            return
        }
        SnapDebugLog.log(
            "performSnap zone=\(context.zone.name) frame=\(context.frame) pid=\(String(describing: context.windowPID)) bundle=\(context.bundleID ?? "nil") hasWindow=\(context.window != nil)"
        )
        scheduleSnap(context, zoneManager: zoneManager)
    }

    @MainActor
    private func refreshSnapTargetAtRelease(at point: NSPoint) {
        guard let zoneManager else { return }
        guard let display = zoneManager.displayManager.display(for: point),
              let layout = zoneManager.activeLayout(for: display.id),
              let zone = zoneManager.zone(at: point, on: display.id) else {
            return
        }

        lastHoveredZoneID = zone.id
        lastHoveredDisplayID = display.id
        cachePendingSnapContext(
            zone: zone,
            layout: layout,
            displayID: display.id,
            at: point,
            zoneManager: zoneManager
        )
    }

    @MainActor
    private func resolvedSnapContext(at point: NSPoint, zoneManager: ZoneManager) -> SnapContext? {
        guard let baseContext = pendingSnapContext ?? makeSnapContext(at: point, zoneManager: zoneManager) else {
            return nil
        }

        if let window = baseContext.window,
           WindowAccessibility.windowFrame(window) != nil {
            return baseContext
        }

        guard let window = resolveWindowForSnap(at: point) else { return baseContext }

        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) != .success {
            pid = baseContext.windowPID ?? draggedWindowPID ?? 0
        }

        return SnapContext(
            window: window,
            zone: baseContext.zone,
            layout: baseContext.layout,
            displayID: baseContext.displayID,
            frame: baseContext.frame,
            bundleID: baseContext.bundleID ?? draggedBundleID ?? bundleIdentifier(for: window),
            windowPID: pid > 0 ? pid : baseContext.windowPID ?? draggedWindowPID,
            fallbackFrame: baseContext.fallbackFrame ?? initialWindowFrame
        )
    }

    @MainActor
    private func cachePendingSnapContext(
        zone: Zone,
        layout: ZoneLayout,
        displayID: CGDirectDisplayID,
        at point: NSPoint,
        zoneManager: ZoneManager
    ) {
        guard let frame = zoneManager.displayManager.absoluteFrame(for: zone, on: displayID) else { return }

        let window = draggedWindow ?? resolveWindowForSnap(at: point)
        var pid: pid_t = draggedWindowPID ?? 0
        if let window, AXUIElementGetPid(window, &pid) != .success {
            pid = draggedWindowPID ?? 0
        }

        pendingSnapContext = SnapContext(
            window: window,
            zone: zone,
            layout: layout,
            displayID: displayID,
            frame: frame,
            bundleID: draggedBundleID ?? window.flatMap(bundleIdentifier(for:)),
            windowPID: pid > 0 ? pid : draggedWindowPID,
            fallbackFrame: initialWindowFrame
        )
    }

    @MainActor
    private func makeSnapContext(at point: NSPoint, zoneManager: ZoneManager) -> SnapContext? {
        guard let window = resolveWindowForSnap(at: point) else { return nil }

        let displayID = lastHoveredDisplayID
            ?? previewDisplayID
            ?? zoneManager.displayManager.display(for: point)?.id
        guard let displayID,
              let layout = zoneManager.activeLayout(for: displayID),
              let zone = zoneForSnap(at: point, displayID: displayID, layout: layout, zoneManager: zoneManager),
              let frame = zoneManager.displayManager.absoluteFrame(for: zone, on: displayID) else {
            return nil
        }

        return SnapContext(
            window: window,
            zone: zone,
            layout: layout,
            displayID: displayID,
            frame: frame,
            bundleID: draggedBundleID ?? bundleIdentifier(for: window),
            windowPID: draggedWindowPID,
            fallbackFrame: initialWindowFrame
        )
    }

    @MainActor
    private func scheduleSnap(_ context: SnapContext, zoneManager: ZoneManager) {
        scheduleSnap(context, zoneManager: zoneManager, remember: true)
    }

    @MainActor
    private static func applySnap(
        _ context: SnapContext,
        zoneManager: ZoneManager,
        attempt: Int,
        remember: Bool = true,
        animated: Bool
    ) async {
        guard let window = resolveWindow(for: context, attempt: attempt) else {
            SnapDebugLog.log("applySnap attempt=\(attempt) — resolveWindow returned nil")
            guard attempt + 1 < snapRetryDelays.count else { return }
            let delay = snapRetryDelays[attempt + 1] - snapRetryDelays[attempt]
            try? await Task.sleep(for: .seconds(delay))
            await applySnap(
                context,
                zoneManager: zoneManager,
                attempt: attempt + 1,
                remember: remember,
                animated: animated
            )
            return
        }

        // Capture free size BEFORE mutating — animated snaps otherwise report "before" as the last tick.
        let preSnapFrame = context.fallbackFrame ?? WindowAccessibility.windowFrame(window)
        let pid = context.windowPID ?? {
            var value: pid_t = 0
            _ = AXUIElementGetPid(window, &value)
            return value > 0 ? value : nil
        }()

        let result: WindowAccessibility.SetFrameResult
        if animated, attempt == 0 {
            result = await WindowAccessibility.setWindowFrameAnimated(window, frame: context.frame)
        } else {
            result = WindowAccessibility.setWindowFrameDetailed(window, frame: context.frame)
        }

        SnapDebugLog.log(
            "applySnap attempt=\(attempt) animated=\(animated) success=\(result.success) preSnap=\(String(describing: preSnapFrame)) before=\(String(describing: result.before)) after=\(String(describing: result.after)) target=\(context.frame) sizeErr=\(result.sizeError) posErr=\(result.positionError)"
        )

        // Remember only after a successful snap, using the real landed size (not the ideal zone rect).
        if result.success, let pid {
            WindowMonitor.shared.rememberPreSnapFrame(
                pid: pid,
                previous: preSnapFrame,
                snapped: result.after ?? context.frame
            )
        }

        if result.success, remember, let bundleID = context.bundleID, !bundleID.isEmpty {
            zoneManager.rememberPosition(
                bundleIdentifier: bundleID,
                zone: context.zone,
                layout: context.layout,
                displayID: context.displayID
            )
        }
        guard !result.success, attempt + 1 < snapRetryDelays.count else { return }
        let delay = snapRetryDelays[attempt + 1] - snapRetryDelays[attempt]
        try? await Task.sleep(for: .seconds(delay))
        await applySnap(
            context,
            zoneManager: zoneManager,
            attempt: attempt + 1,
            remember: remember,
            animated: false
        )
    }

    private static func resolveWindow(for context: SnapContext, attempt: Int) -> AXUIElement? {
        if let window = context.window,
           WindowAccessibility.windowFrame(window) != nil {
            return window
        }
        if let pid = context.windowPID,
           let window = WindowAccessibility.frontmostWindow(for: pid) {
            return window
        }
        if let frame = context.fallbackFrame ?? context.window.flatMap(WindowAccessibility.windowFrame(_:)),
           let window = WindowAccessibility.windowMatching(frame: frame) {
            return window
        }
        return context.window
    }

    @MainActor
    @discardableResult
    private func snapIfPointerInZone(at point: NSPoint) -> Bool {
        guard let zoneManager else { return false }
        guard pendingSnapContext != nil || makeSnapContext(at: point, zoneManager: zoneManager) != nil else { return false }
        performSnap(at: point)
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
        if let point, let zone = zoneManager.zone(at: point, on: displayID) {
            return zone
        }
        if let lastHoveredZoneID,
           let zone = layout.zones.first(where: { $0.id == lastHoveredZoneID }) {
            return zone
        }
        if let highlightedID = zoneManager.highlightedZoneID,
           let zone = layout.zones.first(where: { $0.id == highlightedID }) {
            return zone
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
        lastHoveredZoneID = hoveredZone?.id
        lastHoveredDisplayID = display.id

        if let hoveredZone {
            cachePendingSnapContext(
                zone: hoveredZone,
                layout: layout,
                displayID: display.id,
                at: point,
                zoneManager: zoneManager
            )
        } else {
            pendingSnapContext = nil
        }

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

        var pid: pid_t = 0
        if AXUIElementGetPid(window, &pid) != .success {
            pid = 0
        }

        let context = SnapContext(
            window: window,
            zone: zone,
            layout: layout,
            displayID: displayID,
            frame: frame,
            bundleID: draggedBundleID ?? bundleIdentifier(for: window),
            windowPID: pid > 0 ? pid : nil,
            fallbackFrame: WindowAccessibility.windowFrame(window)
        )
        scheduleSnap(context, zoneManager: zoneManager, remember: remember)
    }

    @MainActor
    private func scheduleSnap(_ context: SnapContext, zoneManager: ZoneManager, remember: Bool = true) {
        let captured = context
        let animated = zoneManager.animateWindowSnapping
        let initialDelay: TimeInterval = animated ? 0.04 : Self.snapRetryDelays[0]
        snapTask?.cancel()
        snapTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(initialDelay))
            guard !Task.isCancelled else { return }
            await Self.applySnap(
                captured,
                zoneManager: zoneManager,
                attempt: 0,
                remember: remember,
                animated: animated
            )
        }
    }

    @MainActor
    func moveFocusedWindowToAdjacentMonitor(direction: ZoneDirection, zoneManager: ZoneManager) {
        guard let window = focusedWindowElement() else { return }
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
        if zoneManager.animateWindowSnapping {
            Task { @MainActor in
                _ = await WindowAccessibility.setWindowFrameAnimated(window, frame: newFrame)
            }
        } else {
            WindowAccessibility.setWindowFrame(window, frame: newFrame)
        }
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

    private func isTextEntryAtCursor(_ point: NSPoint) -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var element: AXUIElement?
        let axPoint = point.quartzScreenPoint
        guard AXUIElementCopyElementAtPosition(
            systemWide,
            Float(axPoint.x),
            Float(axPoint.y),
            &element
        ) == .success,
              let element else { return false }

        var roleRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
              let role = roleRef as? String else { return false }

        return role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
    }

}
