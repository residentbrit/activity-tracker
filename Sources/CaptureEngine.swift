import Foundation
import ScreenCaptureKit
import Cocoa

/// Manages screen capture lifecycle. Event-driven + heartbeat (D2).
/// Capture runs at native resolution. Writes screenshot to DB immediately,
/// then hands off extraction to a low-priority background queue.
actor CaptureEngine {
    private var config: Config
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
    private var tier1Task: Task<Void, Never>?
    private var retentionTask: Task<Void, Never>?
    private var lastTypingTime = Date.distantPast
    private var lastCaptureHash: String?
    private var inputMonitor: InputMonitor?

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

    func applyConfig(_ newConfig: Config) {
        config = newConfig
        restartTimers()
    }

    func run() async {
        let monitor = InputMonitor(config: config)
        monitor.onEvent = { [weak self] event in
            guard let self else { return }
            Task { await self.handleEvent(event) }
        }
        monitor.start()
        self.inputMonitor = monitor  // keep alive
        log("[CaptureEngine] monitor started\n")

        startTimers()

        // run() returns — tasks keep running in background
    }

    private func startTimers() {
        heartbeatTask?.cancel()
        tier1Task?.cancel()
        retentionTask?.cancel()

        heartbeatTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let heartbeatIntervalSec = max(5, await self.config.heartbeatIntervalSec)
                try? await Task.sleep(for: .seconds(heartbeatIntervalSec))
                await self.fireHeartbeat()
            }
        }

        tier1Task = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.runTier1PollingCycle()
                let pollInterval = max(1, await self.config.tier1PollIntervalSec)
                try? await Task.sleep(for: .seconds(pollInterval))
            }
        }

        retentionTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let retentionHours = max(1, await self.config.screenshotRetentionHours)
                do {
                    try await self.eventStore.purgeOldScreenshots(retentionHours: retentionHours)
                } catch {
                    log("[CaptureEngine] screenshot purge failed: \(error)")
                }
                try? await Task.sleep(for: .seconds(3600))
            }
        }
    }

    private func restartTimers() {
        startTimers()
    }

    private func fireHeartbeat() async {
        if !isIdle {
            log("[CaptureEngine] heartbeat firing\n")
            await capture(trigger: "heartbeat")
        }
    }

    private func handleEvent(_ event: InputMonitor.Event) async {
        log("[CaptureEngine] received event: \(event)\n")
        if isIdle && event != .appSwitch { return }
        switch event {
        case .appSwitch:
            await capture(trigger: "app_switch")
            isIdle = false
        case .windowTitleChange:
            await capture(trigger: "window_title_change")
        case .typingPause:
            await capture(trigger: "typing_pause")
        case .idleTimeout:
            isIdle = true
            await closeCurrentSession()
        }
    }

    private func capture(trigger: String) async {
        log("[CaptureEngine] capture(\(trigger)) starting\n")

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
        // 1. Extract text — AX first, OCR fallback
        let result = await extractor.extract(from: image, bundleID: bundleID)
        let text = result.text
        let sourceType = result.source.rawValue

        // 2. Dedup + text diffing
        let dedupKey = text.simpleHash()
        if dedupKey == lastCaptureHash {
            try? await eventStore.insertEvent(
                id: eventId, sessionId: sessionId, capturedAt: capturedAt,
                trigger: trigger, appBundleID: bundleID, appName: appName,
                windowTitle: windowTitle, activeFilePath: nil,
                sourceType: sourceType, textContent: text,
                embedding: nil, dedupKey: dedupKey, isDuplicate: true
            )
            // Still save screenshot for deduplicated events
            if let pngData = image.pngData() {
                do {
                    try await eventStore.saveScreenshot(eventId: eventId, imageData: pngData)
                } catch {
                    log("[CaptureEngine] screenshot save failed: \(error)\n")
                }
            }
            return
        }
        lastCaptureHash = dedupKey

        // 3. Diff against previous capture for this app
        let textToEmbed: String
        let appKey = bundleID ?? "unknown"
        let newLines = Set(text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })

        if let previousLines = previousTextByApp[appKey] {
            let diffLines = newLines.subtracting(previousLines)
            if diffLines.isEmpty {
                textToEmbed = text
            } else {
                textToEmbed = diffLines.sorted().joined(separator: "\n")
            }
        } else {
            textToEmbed = text
        }
        previousTextByApp[appKey] = newLines

        // 4. Save event immediately (embedding is async, don't block the queue)
        let filePath = extractFilePath(from: windowTitle, axText: text)
        log("[CaptureEngine] storing event \(trigger) \(sourceType) text:\(text.count)c\n")

        try? await eventStore.insertEvent(
            id: eventId, sessionId: sessionId, capturedAt: capturedAt,
            trigger: trigger, appBundleID: bundleID, appName: appName,
            windowTitle: windowTitle, activeFilePath: filePath,
            sourceType: sourceType, textContent: text,
            embedding: nil, dedupKey: dedupKey, isDuplicate: false
        )

        // 5. Save screenshot AFTER event exists
        if let pngData = image.pngData() {
            try? await eventStore.saveScreenshot(eventId: eventId, imageData: pngData)
        }

        // 6. Embed asynchronously on a low-priority queue — never blocks capture
        let textToEmbedCopy = textToEmbed
        extractionQueue.async { [self] in
            Task {
                let emb = await embedder.embed(textToEmbedCopy)
                if let emb {
                    try? await eventStore.updateEmbedding(eventId: eventId, embedding: emb)
                }
            }
        }
    }

    // MARK: - Screen capture

    private func captureScreen() async -> CGImage? {
        guard CGPreflightScreenCaptureAccess() else {
            log("[CaptureEngine] ⚠️ Screen Recording permission not granted — cannot capture\n")
            return nil
        }
        // CGDisplayCreateImage is unreliable in daemon context; use CGWindowListCreateImage instead
        let image = CGWindowListCreateImage(.null, .optionOnScreenOnly, kCGNullWindowID, .bestResolution)
        if image == nil {
            log("[CaptureEngine] ⚠️ captureScreen: CGWindowListCreateImage returned nil\n")
        }
        return image
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
                log("[CaptureEngine] heartbeat firing\n")
                await capture(trigger: "heartbeat")
            }
        }
    }

    // MARK: - Helpers

    private func resetIdleTimer() {
        // Idle timeout tracked by InputMonitor
    }

    // MARK: - Tier 1 per-window polling

    /// Single cycle of tier 1 polling — called from detached task.
    private func runTier1PollingCycle() async {
        if !isIdle {
            await pollTier1Windows()
        }
    }

    private func pollTier1Windows() async {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            log("[CaptureEngine] tier1: no window list\n")
            return
        }

        let tier1Set = Set(config.tier1BundleIDs)
        var found = 0
        var captured = 0

        for windowInfo in windowList {
            guard let pid = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let windowID = windowInfo[kCGWindowNumber as String] as? CGWindowID,
                  let bundleID = bundleIDForPID(pid) else {
                continue
            }
            guard tier1Set.contains(bundleID) else { continue }
            found += 1

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
            captured += 1
        }
        if found > 0 || captured > 0 {
            log("[CaptureEngine] tier1 poll: \(found) windows, \(captured) captures\n")
        }
    }

    /// Returns true if the window's content has changed since last poll.
    /// Uses lightweight thumbnail pixel hashing to avoid expensive AX-tree walks
    /// that can starve the actor and block normal capture triggers.
    private func windowContentChanged(windowID: CGWindowID, bundleID: String, pid: pid_t) async -> Bool {
        // Pixel-diff: capture tiny thumbnail, hash it
        let newHash = pixelHashForWindow(windowID: windowID)

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

    /// Iterative AX tree walk — no recursion, safe on small GCD stacks.
    private func collectAXText(from root: AXUIElement, into result: inout [String]) {
        var stack: [AXUIElement] = [root]

        while let element = stack.popLast() {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append(text)
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let kids = children as? [AXUIElement] {
                // Push in reverse so first child is processed first
                stack.append(contentsOf: kids.reversed())
            }
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
