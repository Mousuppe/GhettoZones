import AppKit
import ApplicationServices
import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let snapLeft = Self("snapLeft", default: .init(.leftArrow, modifiers: [.command]))
    static let snapRight = Self("snapRight", default: .init(.rightArrow, modifiers: [.command]))
    static let snapUp = Self("snapUp", default: .init(.upArrow, modifiers: [.command]))
    static let snapDown = Self("snapDown", default: .init(.downArrow, modifiers: [.command]))
    static let snapZone1 = Self("snapZone1", default: .init(.one, modifiers: [.command]))
    static let snapZone2 = Self("snapZone2", default: .init(.two, modifiers: [.command]))
    static let snapZone3 = Self("snapZone3", default: .init(.three, modifiers: [.command]))
    static let snapZone4 = Self("snapZone4", default: .init(.four, modifiers: [.command]))
    static let snapZone5 = Self("snapZone5", default: .init(.five, modifiers: [.command]))
    static let snapZone6 = Self("snapZone6", default: .init(.six, modifiers: [.command]))
    static let snapZone7 = Self("snapZone7", default: .init(.seven, modifiers: [.command]))
    static let snapZone8 = Self("snapZone8", default: .init(.eight, modifiers: [.command]))
    static let snapZone9 = Self("snapZone9", default: .init(.nine, modifiers: [.command]))
    static let moveToNextMonitor = Self("moveToNextMonitor", default: .init(.rightArrow, modifiers: [.command, .shift]))
    static let moveToPreviousMonitor = Self("moveToPreviousMonitor", default: .init(.leftArrow, modifiers: [.command, .shift]))
}

@MainActor
final class ShortcutManager {
    private weak var zoneManager: ZoneManager?
    private var observers: [Any] = []

    func register(zoneManager: ZoneManager) {
        self.zoneManager = zoneManager
        unregister()

        let shortcuts: [(KeyboardShortcuts.Name, () -> Void)] = [
            (.snapLeft, { [weak self] in self?.snapAdjacent(.left) }),
            (.snapRight, { [weak self] in self?.snapAdjacent(.right) }),
            (.snapUp, { [weak self] in self?.snapAdjacent(.up) }),
            (.snapDown, { [weak self] in self?.snapAdjacent(.down) }),
            (.snapZone1, { [weak self] in self?.snapToIndex(1) }),
            (.snapZone2, { [weak self] in self?.snapToIndex(2) }),
            (.snapZone3, { [weak self] in self?.snapToIndex(3) }),
            (.snapZone4, { [weak self] in self?.snapToIndex(4) }),
            (.snapZone5, { [weak self] in self?.snapToIndex(5) }),
            (.snapZone6, { [weak self] in self?.snapToIndex(6) }),
            (.snapZone7, { [weak self] in self?.snapToIndex(7) }),
            (.snapZone8, { [weak self] in self?.snapToIndex(8) }),
            (.snapZone9, { [weak self] in self?.snapToIndex(9) }),
            (.moveToNextMonitor, { [weak self] in self?.moveMonitor(.right) }),
            (.moveToPreviousMonitor, { [weak self] in self?.moveMonitor(.left) })
        ]

        for (name, action) in shortcuts {
            let observer = KeyboardShortcuts.onKeyUp(for: name) {
                Task { @MainActor in
                    action()
                }
            }
            observers.append(observer)
        }
    }

    func unregister() {
        observers.removeAll()
    }

    @MainActor
    private func snapAdjacent(_ direction: ZoneDirection) {
        guard let zoneManager, zoneManager.snappingEnabled, zoneManager.isAccessibilityGranted else { return }
        guard let window = WindowMonitor.shared.focusedWindowElement(),
              let frame = windowFrame(window) else { return }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let display = zoneManager.displayManager.display(for: center) else { return }
        let current = WindowMonitor.shared.currentFocusedZone(on: display.id, zoneManager: zoneManager)
            ?? zoneManager.zone(at: center, on: display.id)
        guard let current else { return }
        guard let target = zoneManager.adjacentZone(from: current, direction: direction, on: display.id) else { return }
        WindowMonitor.shared.snapFocusedWindow(to: target, on: display.id, zoneManager: zoneManager)
    }

    @MainActor
    private func snapToIndex(_ index: Int) {
        guard let zoneManager, zoneManager.snappingEnabled, zoneManager.isAccessibilityGranted else { return }
        guard let window = WindowMonitor.shared.focusedWindowElement(),
              let frame = windowFrame(window) else { return }
        let center = NSPoint(x: frame.midX, y: frame.midY)
        guard let display = zoneManager.displayManager.display(for: center),
              let zone = zoneManager.zone(at: index, on: display.id) else { return }
        WindowMonitor.shared.snapFocusedWindow(to: zone, on: display.id, zoneManager: zoneManager)
    }

    @MainActor
    private func moveMonitor(_ direction: ZoneDirection) {
        guard let zoneManager, zoneManager.snappingEnabled, zoneManager.isAccessibilityGranted else { return }
        WindowMonitor.shared.moveFocusedWindowToAdjacentMonitor(direction: direction, zoneManager: zoneManager)
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
}
