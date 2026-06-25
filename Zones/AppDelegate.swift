import AppKit
import ApplicationServices
import Combine
import Defaults
import SwiftUI

@MainActor
final class AppState: ObservableObject {
    @Published var showZoneEditor = false
    @Published var showSettings = false
    @Published var showAccessibilitySheet = false

    func openZoneEditor() { showZoneEditor = true }
    func openSettings() { showSettings = true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var zoneEditorWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private let displayManager = DisplayManager()
    private lazy var zoneManager = ZoneManager(displayManager: displayManager)
    private let shortcutManager = ShortcutManager()
    private var cancellables = Set<AnyCancellable>()

    private lazy var appState: AppState = {
        let state = AppState()
        state.$showZoneEditor
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.presentZoneEditor()
                state.showZoneEditor = false
            }
            .store(in: &cancellables)
        state.$showSettings
            .dropFirst()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.presentSettings()
                state.showSettings = false
            }
            .store(in: &cancellables)
        return state
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        updateStatusItemAppearance()
        setupScreenChangeObserver()
        zoneManager.refreshPermissionState()

        if !Defaults[.hasShownAccessibilityPrompt] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.showAccessibilityPromptIfNeeded()
            }
        }

        Task { @MainActor in
            WindowMonitor.shared.start(zoneManager: zoneManager)
            shortcutManager.register(zoneManager: zoneManager)
            zoneManager.restoreRememberedPositions()
        }

        NotificationCenter.default.publisher(for: .accessibilityPermissionGranted)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let self else { return }
                WindowMonitor.shared.start(zoneManager: self.zoneManager)
                self.zoneManager.restoreRememberedPositions()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        WindowMonitor.shared.stop()
        shortcutManager.unregister()
        popover?.close()
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
            statusItem = nil
        }
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: "GhettoZones")
        button.image?.isTemplate = true
        button.action = #selector(togglePopover(_:))
        button.target = self

        zoneManager.$permissionWarning
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
            }
            .store(in: &cancellables)

        zoneManager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.updateStatusItemAppearance()
            }
            .store(in: &cancellables)

        let popover = NSPopover()
        popover.contentSize = NSSize(width: 280, height: 240)
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(
            rootView: MenuBarPopoverView(zoneManager: zoneManager)
                .environmentObject(appState)
        )
        self.popover = popover
    }

    private func updateStatusItemAppearance() {
        guard let button = statusItem?.button else { return }
        if zoneManager.permissionWarning {
            button.image = NSImage(systemSymbolName: "exclamationmark.triangle", accessibilityDescription: "GhettoZones")
            button.image?.isTemplate = true
            return
        }
        let displayID = zoneManager.displayManager.displays.first(where: \.isMain)?.id
            ?? zoneManager.displayManager.displays.first?.id
            ?? 0
        let layout = zoneManager.activeLayout(for: displayID)
        button.image = LayoutIconRenderer.image(for: layout)
            ?? NSImage(systemSymbolName: "square.split.2x2", accessibilityDescription: "GhettoZones")
        button.image?.isTemplate = true
    }

    @objc private func togglePopover(_ sender: AnyObject?) {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown {
            popover.performClose(sender)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    // MARK: - Windows

    private func presentZoneEditor() {
        if zoneEditorWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 900, height: 600),
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("GhettoZones Zone Editor", comment: "Zone editor window title")
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: ZoneEditorView(zoneManager: zoneManager)
            )
            zoneEditorWindow = window
        }
        zoneEditorWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func presentSettings() {
        if settingsWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 540, height: 440),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = NSLocalizedString("GhettoZones Settings", comment: "Settings window title")
            window.center()
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(
                rootView: SettingsView(zoneManager: zoneManager)
            )
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - Screen changes

    private func setupScreenChangeObserver() {
        displayManager.$displays
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor in
                    WindowMonitor.shared.refreshOverlays()
                    self?.zoneManager.restoreRememberedPositions()
                }
            }
            .store(in: &cancellables)
    }

    // MARK: - Accessibility

    private func showAccessibilityPromptIfNeeded() {
        guard !AccessibilityChecker.isGranted() else { return }
        let alert = NSAlert()
        alert.messageText = NSLocalizedString("Accessibility Permission Required", comment: "Accessibility alert title")
        alert.informativeText = CodeSigningHelper.isAdHocSigned
            ? NSLocalizedString(
                "GhettoZones needs Accessibility access to snap and resize windows.\n\nThis build is ad-hoc signed. If GhettoZones is already in the list, remove it with the − button first, then enable it again for this install.",
                comment: "Accessibility alert message for ad-hoc builds"
            )
            : NSLocalizedString(
                "GhettoZones needs Accessibility access to snap and resize windows. Grant access in System Settings, then return here.",
                comment: "Accessibility alert message"
            )
        alert.addButton(withTitle: NSLocalizedString("Open System Settings", comment: "Accessibility alert button"))
        alert.addButton(withTitle: NSLocalizedString("Later", comment: "Dismiss accessibility alert"))
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            zoneManager.openAccessibilitySettings()
        }
        setHasShownAccessibilityPrompt()
    }

    private func setHasShownAccessibilityPrompt() {
        Defaults[.hasShownAccessibilityPrompt] = true
    }
}
