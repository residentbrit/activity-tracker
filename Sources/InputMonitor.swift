import Foundation
import Cocoa

/// Monitors macOS input events to drive capture triggers (D2).
///
/// Four detection mechanisms:
/// 1. **App-switch** — NSWorkspace.didActivateApplicationNotification (instant)
/// 2. **Keystrokes / typing pause** — CGEvent tap for keyDown; after
///    `typingPauseSec` of no keystrokes (default 3s), yields `.typingPause`
/// 3. **Idle timeout** — polls `CGEventSourceSecondsSinceLastEventType`; after
///    `idleTimeoutMin` (default 5min) of no HID input, yields `.idleTimeout`
/// 4. **Window title change** — periodic AXUIElement poll (every 2s);
///    yields `.windowTitleChange` when the focused window title changes
///
/// CGEvent tap requires Accessibility permission (same as AX API). Falls back
/// gracefully to timer-only detection if the tap cannot be created.
final class InputMonitor: @unchecked Sendable {
    enum Event {
        case appSwitch
        case windowTitleChange
        case typingPause
        case idleTimeout
    }

    /// Direct callback — called on an arbitrary thread when an event fires.
    /// Set by CaptureEngine before start().
    var onEvent: ((Event) -> Void)?

    private let config: Config

    // MARK: - Mutable state (NSLock protected — CGEvent tap fires on arbitrary thread)

    private let lock = NSLock()
    private var _lastInputTime = Date()
    private var lastInputTime: Date {
        get { lock.withLock { _lastInputTime } }
        set { lock.withLock { _lastInputTime = newValue } }
    }

    private var _lastKeystrokeTime = Date.distantPast
    private var lastKeystrokeTime: Date {
        get { lock.withLock { _lastKeystrokeTime } }
        set { lock.withLock { _lastKeystrokeTime = newValue } }
    }

    private var _isIdle = false
    private var isIdle: Bool {
        get { lock.withLock { _isIdle } }
        set { lock.withLock { _isIdle = newValue } }
    }

    private var _lastWindowTitle: String?
    private var lastWindowTitle: String? {
        get { lock.withLock { _lastWindowTitle } }
        set { lock.withLock { _lastWindowTitle = newValue } }
    }

    // MARK: - Timers & tap

    private var eventTap: CFMachPort?
    private var tapRunLoopSource: CFRunLoopSource?
    private var typingPauseTimer: DispatchSourceTimer?
    private var idlePollTimer: DispatchSourceTimer?
    private var windowTitleTimer: DispatchSourceTimer?

    init(config: Config) {
        self.config = config
    }

    deinit {
        stop()
    }

    // MARK: - Start / Stop

    func start() {
        log("[InputMonitor] start() called")

        // App-switch notifications — most important capture trigger
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.lastInputTime = Date()
            self?.onEvent?(.appSwitch)
        }

        log("[InputMonitor] creating event tap…\n")
        createEventTap()
        startTypingPauseTimer()
        startIdlePollTimer()
        startWindowTitleTimer()
    }

    func stop() {
        disableEventTap()
        typingPauseTimer?.cancel()
        idlePollTimer?.cancel()
        windowTitleTimer?.cancel()
        // no-op
    }

    // MARK: - CGEvent tap (keystroke + click detection)

    private func createEventTap() {
        // CGEvent.tapCreate may SIGBUS without Accessibility permission on
        // some macOS versions. Check trust first.
        guard AXIsProcessTrusted() else {
            log("[InputMonitor] ⚠️ Accessibility permission not granted — event tap disabled\n")
            return
        }
        let eventMask: CGEventMask = (
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)
        )

        let callback: CGEventTapCallBack = { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
            let monitor = Unmanaged<InputMonitor>.fromOpaque(refcon!).takeUnretainedValue()
            monitor.handleInputEvent(type: type)

            // .listenOnly — we never modify or suppress events
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[InputMonitor] ⚠️ CGEvent tap creation failed — requires Accessibility permission. Falling back to timer-only detection.")
            return
        }

        self.eventTap = tap

        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.tapRunLoopSource = runLoopSource

        // Run the tap on a dedicated background thread with its own run loop
        Thread.detachNewThread { [weak self] in
            guard let self, let source = self.tapRunLoopSource else { return }
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
    }

    private func disableEventTap() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = tapRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        tapRunLoopSource = nil
    }

    /// Called from CGEvent tap callback thread. Keep it fast — just update timestamps.
    private func handleInputEvent(type: CGEventType) {
        let now = Date()
        lastInputTime = now

        if type == .keyDown {
            lastKeystrokeTime = now
            // Reset typing pause timer — each keystroke pushes the pause deadline forward
            typingPauseTimer?.schedule(
                deadline: .now() + .seconds(config.typingPauseSec),
                repeating: .never
            )
        }

        // Any input (keyboard or mouse) wakes from idle
        if isIdle {
            isIdle = false
            // Don't yield a wake event — the next capture trigger (app-switch, typing pause,
            // or heartbeat) will handle it. We just reset the idle flag.
        }
    }

    // MARK: - Typing pause timer (fires after typingPauseSec of no keystrokes)

    private func startTypingPauseTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .default))
        timer.schedule(
            deadline: .now() + .seconds(config.typingPauseSec),
            repeating: .never
        )
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            let elapsed = Date().timeIntervalSince(self.lastKeystrokeTime)
            if elapsed >= Double(self.config.typingPauseSec) && self.lastKeystrokeTime > Date.distantPast {
                self.onEvent?(.typingPause)
            }
        }
        timer.resume()
        self.typingPauseTimer = timer
    }

    // MARK: - Idle poll timer (polls CGEventSource for HID idle time)

    private func startIdlePollTimer() {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .default))
        // Poll every 5 seconds
        timer.schedule(deadline: .now() + .seconds(5), repeating: .seconds(5))
        timer.setEventHandler { [weak self] in
            guard let self else { return }

            let keyIdle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .keyDown
            )
            let clickIdle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .leftMouseDown
            )
            let moveIdle = CGEventSource.secondsSinceLastEventType(
                .combinedSessionState, eventType: .mouseMoved
            )

            // Any keyboard OR mouse activity (clicks AND movement) counts as active
            let effectiveIdle = min(keyIdle, min(clickIdle, moveIdle))
            let idleThreshold = Double(self.config.idleTimeoutMin * 60)

            if effectiveIdle >= idleThreshold {
                if !self.isIdle {
                    self.isIdle = true
                    self.onEvent?(.idleTimeout)
                }
            } else if self.isIdle {
                // Activity resumed — wake and trigger a capture
                self.isIdle = false
                self.onEvent?(.appSwitch)
            }
        }
        timer.resume()
        self.idlePollTimer = timer
    }

    // MARK: - Window title polling

    private func startWindowTitleTimer() {
        guard AXIsProcessTrusted() else {
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .default))
        timer.schedule(deadline: .now() + .seconds(2), repeating: .seconds(2))
        timer.setEventHandler { [weak self] in
            guard let self, !self.isIdle else { return }

            let currentTitle = self.getFocusedWindowTitle()
            if currentTitle != self.lastWindowTitle && self.lastWindowTitle != nil {
                self.onEvent?(.windowTitleChange)
            }
            self.lastWindowTitle = currentTitle
        }
        timer.resume()
        self.windowTitleTimer = timer
    }

    // MARK: - AX helpers

    private func getFocusedWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow
        ) == .success, let window = focusedWindow else {
            return nil
        }

        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &title
        ) == .success, let titleStr = title as? String else {
            return nil
        }

        return titleStr
    }
}
