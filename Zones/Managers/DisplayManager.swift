import AppKit
import Combine
import CoreGraphics

struct DisplayInfo: Identifiable, Equatable {
    let id: CGDirectDisplayID
    let screen: NSScreen
    let name: String
    let frame: CGRect
    let visibleFrame: CGRect

    var isMain: Bool { screen == NSScreen.main }
}

final class DisplayManager: ObservableObject {
    @Published private(set) var displays: [DisplayInfo] = []

    private var cancellables = Set<AnyCancellable>()

    init() {
        refreshDisplays()
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)
            .sink { [weak self] _ in
                self?.refreshDisplays()
            }
            .store(in: &cancellables)
    }

    func refreshDisplays() {
        displays = NSScreen.screens.compactMap { screen in
            guard let displayID = screen.displayID else { return nil }
            return DisplayInfo(
                id: displayID,
                screen: screen,
                name: localizedDisplayName(for: screen, displayID: displayID),
                frame: screen.frame,
                visibleFrame: screen.visibleFrame
            )
        }
    }

    func display(for point: NSPoint) -> DisplayInfo? {
        displays.first { $0.frame.contains(point) }
    }

    func display(forID displayID: CGDirectDisplayID) -> DisplayInfo? {
        displays.first { $0.id == displayID }
    }

    func screenFrame(for displayID: CGDirectDisplayID) -> CGRect? {
        display(forID: displayID)?.visibleFrame
    }

    func absoluteFrame(for zone: Zone, on displayID: CGDirectDisplayID) -> CGRect? {
        guard let visible = screenFrame(for: displayID) else { return nil }
        return CGRect(
            x: visible.origin.x + zone.frame.origin.x * visible.width,
            y: visible.origin.y + zone.frame.origin.y * visible.height,
            width: zone.frame.width * visible.width,
            height: zone.frame.height * visible.height
        )
    }

    private func localizedDisplayName(for screen: NSScreen, displayID: CGDirectDisplayID) -> String {
        if screen == NSScreen.main {
            return NSLocalizedString("Main Display", comment: "Primary monitor label")
        }
        return String(format: NSLocalizedString("Display %d", comment: "External monitor label"), displayID)
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID? {
        guard let screenNumber = deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else {
            return nil
        }
        return CGDirectDisplayID(screenNumber.uint32Value)
    }
}
