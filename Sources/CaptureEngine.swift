import Foundation
import ScreenCaptureKit
import Cocoa

/// Manages screen capture lifecycle. Event-driven + heartbeat (D2).
/// Capture runs at native resolution. Writes screenshot to DB immediately,
/// then hands off extraction to a low-priority background queue.
actor CaptureEngine {
    private let config: Config
    private let db: Database
    private let eventStore: EventStore
    private let extractor: TextExtractor
    private let embedder: Embedder

    // Low-priority serial queue — extraction never competes with user work
    private let extractionQueue: DispatchQueue = .init(
        label: "activity-tracker.extraction",
        qos: .background
    )

    private var currentSession: Session?
    private var isIdle = false
    private var heartbeatTask: Task<Void, Never>?
    private var lastTypingTime = Date.distantPast
    private var lastCaptureHash: String?

    // Per-app text diffing: keyed by bundleID, stores last capture's text lines
    private var previousTextByApp: [String: Set<String>] = [:]

    // Per-window change tracking for tier 1 polling
    private var windowHashes: [CGWindowID: String] = [:]           // pixel or text hash
    private var windowPreviousText: [CGWindowID: Set<String>] = [:] // for text diffing per window

    // AX-opaque apps that need pixel-diff instead of text-hash change detection
    private let axOpaqueBundleIDs: Set<String> = [
        "com.google.Chrome",
        "io.gitlab.librewolf-community",
        "org.mozilla.firefox",
        "com.microsoft.VSCode",   // editor pane is opaque
    ]

    init(config: Config, database: Database) {
        self.config = config
        self.db = database
        self.eventStore = EventStore(database: database)
        self.extractor = TextExtractor()
        self.embedder = Embedder(config: config)
    }

    func run() async {
        let inputMonitor = InputMonitor(config: config)
        inputMonitor.start()
        fputs("[CaptureEngine] monitor started, entering event loop…\n", stderr)

        heartbeatTask = Task { await runHeartbeat() }

        // Start tier 1 per-window polling (faster cadence for key apps)
        let tier1Task = Task { await runTier1Polling() }

        // Main event loop
        fputs("[CaptureEngine] waiting for first event…\n", stderr)
        for await event in inputMonitor.events {
            if isIdle && event != .appSwitch {
                continue
            }

            switch event {
            case .appSwitch:
                await capture(trigger: "app_switch")
                isIdle = false
                resetIdleTimer()

            case .windowTitleChange:
                await capture(trigger: "window_title_change")

            case .typingPause:
                await capture(trigger: "typing_pause")

            case .idleTimeout:
                isIdle = true
                await closeCurrentSession()
            }
        }

        tier1Task.cancel()
    }

    private func capture(trigger: String) async {
        // Ensure session exists
        if currentSession == nil {
            await startNewSession()
        }

        guard let session = currentSession else { return }

        // 1. Capture screenshot at native resolution
        guard let image = await captureScreen() else { return }

        // 2. Write to DB immediately (fast — don't block on extraction)
        let eventId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        // 3. Gather structured metadata synchronously (fast)
        let appInfo = NSWorkspace.shared.frontmostApplication
        let bundleID = appInfo?.bundleIdentifier
        let appName = appInfo?.localizedName
        let windowTitle = getFrontWindowTitle()

        // 4. Hand off to background queue for extraction + embedding
        extractionQueue.async { [self] in
            Task {
                await processEvent(
                    eventId: eventId,
                    sessionId: session.id,
                    capturedAt: now,
                    trigger: trigger,
                    bundleID: bundleID,
                    appName: appName,
                    windowTitle: windowTitle,
                    image: image
                )
            }
        }
    }

    private func processEvent(
        eventId: String, sessionId: String, capturedAt: String,
        trigger: String, bundleID: String?, appName: String?, windowTitle: String?,
        image: CGImage
    ) async {
        // Save screenshot blob immediately
        if let pngData = image.pngData() {
            try? await eventStore.saveScreenshot(eventId: eventId, imageData: pngData)
        }

        // Extract text — AX first, OCR fallback
        let result = await extractor.extract(from: image, bundleID: bundleID)
        let text = result.text
        let sourceType = result.source.rawValue

        // Dedup + text diffing
        let dedupKey = text.simpleHash()
        if dedupKey == lastCaptureHash {
            try? await eventStore.insertEvent(
                id: eventId, sessionId: sessionId, capturedAt: capturedAt,
                trigger: trigger, appBundleID: bundleID, appName: appName,
                windowTitle: windowTitle, activeFilePath: nil,
                sourceType: sourceType, textContent: text,
                embedding: nil, dedupKey: dedupKey, isDuplicate: true
            )
            return
        }
        lastCaptureHash = dedupKey

        // Diff against previous capture for this app — embed only new lines
        let textToEmbed: String
        let appKey = bundleID ?? "unknown"
        let newLines = Set(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })

        if let previousLines = previousTextByApp[appKey] {
            let diffLines = newLines.subtracting(previousLines)
            if diffLines.isEmpty {
                // Text changed but no new lines (e.g. reordering) — embed the full text
                textToEmbed = text
            } else {
                textToEmbed = diffLines.sorted().joined(separator: "\n")
            }
        } else {
            textToEmbed = text
        }
        previousTextByApp[appKey] = newLines

        // Embed only the diff (or full text if first capture for this app)
        let embedding = await embedder.embed(textToEmbed)

        let filePath = extractFilePath(from: windowTitle, axText: text)

        try? await eventStore.insertEvent(
            id: eventId, sessionId: sessionId, capturedAt: capturedAt,
            trigger: trigger, appBundleID: bundleID, appName: appName,
            windowTitle: windowTitle, activeFilePath: filePath,
            sourceType: sourceType, textContent: text,
            embedding: embedding, dedupKey: dedupKey, isDuplicate: false
        )
    }

    // MARK: - Screen capture

    private func captureScreen() async -> CGImage? {
        // CGDisplayCreateImage may crash (SIGBUS) on Intel Macs without
        // Screen Recording permission. Check access first.
        guard CGPreflightScreenCaptureAccess() else {
            fputs("[CaptureEngine] ⚠️ Screen Recording permission not granted — cannot capture\n", stderr)
            return nil
        }
        let displayID = CGMainDisplayID()
        return CGDisplayCreateImage(displayID)
    }

    // MARK: - Sessions

    private func startNewSession() async {
        let session = Session(
            id: UUID().uuidString,
            machineId: Host.current().localizedName ?? "unknown",
            startedAt: ISO8601DateFormatter().string(from: Date()),
            endedAt: nil,
            timezone: TimeZone.current.identifier
        )
        try? await eventStore.insertSession(session)
        currentSession = session
    }

    private func closeCurrentSession() async {
        guard var session = currentSession else { return }
        session.endedAt = ISO8601DateFormatter().string(from: Date())
        try? await eventStore.updateSession(session)
        currentSession = nil
    }

    // MARK: - Heartbeat

    private func runHeartbeat() async {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(config.heartbeatIntervalSec))
            if !isIdle {
                await capture(trigger: "heartbeat")
            }
        }
    }

    // MARK: - Helpers

    private func resetIdleTimer() {
        // Idle timeout tracked by InputMonitor
    }

    // MARK: - Tier 1 per-window polling

    /// Polls visible windows of tier 1 apps every `tier1PollIntervalSec`.
    /// Uses text-hash for AX-capable apps, pixel-hash for AX-opaque ones.
    /// Fires a per-window capture only when content has changed.
    private func runTier1Polling() async {
        fputs("[CaptureEngine] tier1 polling started\n", stderr)
        while !Task.isCancelled {
            if !isIdle {
                await pollTier1Windows()
            }
            try? await Task.sleep(for: .seconds(config.tier1PollIntervalSec))
        }
    }

    private func pollTier1Windows() async {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            return
        }

        let tier1Set = Set(config.tier1BundleIDs)

        for windowInfo in windowList {
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let bundleID = bundleIDForPID(pid),
                  tier1Set.contains(bundleID) else {
                continue
            }

            // Skip tiny/occluded windows
            let bounds = windowInfo[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            let width = bounds["Width"] ?? 0
            let height = bounds["Height"] ?? 0
            guard width > 200 && height > 100 else { continue }

            // Check for content change
            let changed = await windowContentChanged(
                windowID: windowID, bundleID: bundleID, pid: pid
            )
            guard changed else { continue }

            // Capture this window
            let appName = appNameForPID(pid)
            let windowTitle = windowInfo[kCGWindowName as String] as? String
            await captureWindow(
                windowID: windowID,
                bundleID: bundleID,
                appName: appName,
                windowTitle: windowTitle ?? windowTitleViaAX(pid: pid)
            )
        }
    }

    /// Returns true if the window's content has changed since last poll.
    /// AX-capable: walks AX tree → hashes text. AX-opaque: captures thumbnail → hashes pixels.
    private func windowContentChanged(windowID: CGWindowID, bundleID: String, pid: pid_t) async -> Bool {
        let isOpaque = axOpaqueBundleIDs.contains(bundleID)

        let newHash: String?
        if isOpaque {
            // Pixel-diff: capture tiny thumbnail, hash it
            newHash = pixelHashForWindow(windowID: windowID)
        } else {
            // Text-diff: walk AX tree, hash the text
            newHash = axTextHashForPID(pid: pid)
        }

        guard let hash = newHash else { return false }

        let previous = windowHashes[windowID]
        windowHashes[windowID] = hash

        // No previous hash = first time seeing this window = capture it
        if previous == nil { return true }

        return hash != previous
    }

    /// Capture a specific window, extract text, embed, store.
    private func captureWindow(
        windowID: CGWindowID, bundleID: String, appName: String?, windowTitle: String?
    ) async {
        if currentSession == nil {
            await startNewSession()
        }
        guard let session = currentSession else { return }

        guard let image = CGWindowListCreateImage(
            .null, .optionOnScreenOnly, windowID, .bestResolution
        ) else { return }

        let eventId = UUID().uuidString
        let now = ISO8601DateFormatter().string(from: Date())

        // Hand off to background queue
        let sid = session.id
        extractionQueue.async { [self] in
            Task {
                await processEvent(
                    eventId: eventId,
                    sessionId: sid,
                    capturedAt: now,
                    trigger: "tier1_poll",
                    bundleID: bundleID,
                    appName: appName,
                    windowTitle: windowTitle,
                    image: image
                )
            }
        }
    }

    // MARK: - Per-window change detection helpers

    private func pixelHashForWindow(windowID: CGWindowID) -> String? {
        // Capture at 1/8th scale for fast hashing
        guard let image = CGWindowListCreateImage(
            .null, .optionOnScreenOnly, windowID, .nominalResolution
        ) else { return nil }

        let width = image.width
        let height = image.height
        let scale = max(1, min(width, height) / 128)  // ~128px thumbnail
        let thumbW = width / scale
        let thumbH = height / scale

        guard let context = CGContext(
            data: nil,
            width: thumbW, height: thumbH,
            bitsPerComponent: 8, bytesPerRow: thumbW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
        ) else { return nil }

        context.draw(image, in: CGRect(x: 0, y: 0, width: thumbW, height: thumbH))
        guard let data = context.data else { return nil }
        let byteCount = thumbW * thumbH * 4

        // Simple hash of pixel data
        var hash = 0
        let bytes = data.bindMemory(to: UInt8.self, capacity: byteCount)
        for i in stride(from: 0, to: byteCount, by: 16) {
            hash = hash &+ Int(bytes[i]) &* 31
        }
        return String(hash)
    }

    private func axTextHashForPID(pid: pid_t) -> String? {
        guard AXIsProcessTrusted() else { return nil }
        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
              let window = focusedWindow else { return nil }

        var allText: [String] = []
        collectAXText(from: window as! AXUIElement, into: &allText)
        let combined = allText.joined(separator: "\n")
        return combined.isEmpty ? nil : combined.simpleHash()
    }

    private func collectAXText(from element: AXUIElement, into result: inout [String]) {
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            result.append(text)
        }
        var children: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
           let kids = children as? [AXUIElement] {
            for child in kids { collectAXText(from: child, into: &result) }
        }
    }

    // MARK: - Process helpers

    private func bundleIDForPID(_ pid: pid_t) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.bundleIdentifier
    }

    private func appNameForPID(_ pid: pid_t) -> String? {
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier == pid }?.localizedName
    }

    private func windowTitleViaAX(pid: pid_t) -> String? {
        let appRef = AXUIElementCreateApplication(pid)
        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success else {
            return nil
        }
        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &title)
        return title as? String
    }

    private func getFrontWindowTitle() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        return windowTitleViaAX(pid: app.processIdentifier)
    }

    private func extractFilePath(from windowTitle: String?, axText: String?) -> String? {
        // Heuristic: look for path patterns in window title (e.g. "file.swift — project")
        guard let title = windowTitle else { return nil }
        // VS Code: "filename — project"
        if let dashRange = title.range(of: " — ") {
            let candidate = String(title[..<dashRange.lowerBound])
            if candidate.contains(".") || candidate.contains("/") {
                return candidate
            }
        }
        return nil
    }
}

// MARK: - Supporting types

struct Session: Codable {
    let id: String
    let machineId: String
    let startedAt: String
    var endedAt: String?
    let timezone: String
}

extension CGImage {
    func pngData() -> Data? {
        let rep = NSBitmapImageRep(cgImage: self)
        return rep.representation(using: .png, properties: [:])
    }
}

extension String {
    func simpleHash() -> String {
        var hasher = Hasher()
        hasher.combine(self)
        return String(hasher.finalize(), radix: 16)
    }
}
