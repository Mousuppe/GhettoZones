import AppKit
import CoreGraphics

/// Listen-only session event tap on a dedicated run loop thread.
/// NSEvent global monitors miss mouse-drag events while another app is moving a window;
/// a CGEvent tap receives them reliably (see Rectangle ActiveEventMonitor).
final class CGEventTapMonitor {
    typealias Handler = (_ event: CGEvent, _ type: CGEventType) -> Void

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var thread: RunLoopThread?
    private let eventMask: CGEventMask
    private let handler: Handler

    init(eventTypes: [CGEventType], handler: @escaping Handler) {
        var mask: UInt64 = 0
        for eventType in eventTypes {
            mask |= 1 << eventType.rawValue
        }
        eventMask = CGEventMask(mask)
        self.handler = handler
    }

    deinit {
        stop()
    }

    var isRunning: Bool { eventTap != nil }

    @discardableResult
    func start() -> Bool {
        guard eventTap == nil else { return true }

        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: Self.eventTapCallback,
            userInfo: userInfo
        ) else {
            return false
        }

        eventTap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        runLoopSource = source

        let thread = RunLoopThread()
        self.thread = thread
        thread.start()
        thread.waitUntilReady()

        if let source, let runLoop = thread.runLoop {
            CFRunLoopAddSource(runLoop, source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }

        return true
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource, let runLoop = thread?.runLoop {
            CFRunLoopRemoveSource(runLoop, source, .commonModes)
        }
        runLoopSource = nil
        thread?.cancel()
        thread = nil
        eventTap = nil
    }

    private static let eventTapCallback: CGEventTapCallBack = { _, type, event, userInfo in
        guard let userInfo else { return Unmanaged.passRetained(event) }
        let monitor = Unmanaged<CGEventTapMonitor>.fromOpaque(userInfo).takeUnretainedValue()

        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = monitor.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        monitor.handler(event, type)
        return Unmanaged.passRetained(event)
    }
}

private final class RunLoopThread: Thread {
    private let readySemaphore = DispatchSemaphore(value: 0)
    private(set) var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        readySemaphore.signal()
        while !isCancelled {
            RunLoop.current.run(mode: .default, before: .distantFuture)
        }
    }

    func waitUntilReady() {
        readySemaphore.wait()
    }
}

extension CGEvent {
    /// Converts Quartz screen coordinates (origin top-left) to AppKit global coordinates (origin bottom-left).
    var appKitScreenPoint: NSPoint {
        NSPoint(cgPoint: location).appKitScreenPoint
    }

    var isCommandPressed: Bool {
        flags.contains(.maskCommand)
    }
}

extension NSPoint {
    var appKitScreenPoint: NSPoint { self }

    /// AppKit global coordinates → Quartz screen coordinates for AX / CGWindowList.
    var quartzScreenPoint: NSPoint {
        let mainHeight = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
        return NSPoint(x: x, y: mainHeight - y)
    }

    init(cgPoint: CGPoint) {
        let mainHeight = NSScreen.screens.map(\.frame.maxY).max() ?? NSScreen.main?.frame.maxY ?? 0
        self.init(x: cgPoint.x, y: mainHeight - cgPoint.y)
    }
}
