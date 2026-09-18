import Foundation
import Vision
import Cocoa

/// AX-first text extraction with Vision OCR as either fallback or companion
/// (D3, extended 2026-09-17).
///
/// The accessibility tree is fast, free and resolution-independent, but in
/// browsers and Electron apps it returns only the window/tab title — measured
/// 311 chars for LibreWolf against 4,284 from OCR of the same capture. So OCR
/// is not merely a fallback: with `ocrEveryCapture` both run and both are kept.
///
/// Not an actor — extractions run concurrently on GCD threads, one per capture.
final class TextExtractor: Sendable {

    /// Dedicated serial queue for AX extraction. An AX call blocked in
    /// window-server IPC cannot be cancelled; running all AX work on one queue
    /// bounds the damage to a single stuck thread instead of one per capture.
    private static let axQueue = DispatchQueue(
        label: "activity-tracker.ax", qos: .userInitiated)

    /// Held while the AX worker is busy. Acquired non-blockingly: if a previous
    /// AX extraction is still stuck, we skip AX and fall back to OCR instead of
    /// piling up another blocked GCD thread (which eventually exhausts the
    /// global thread pool and stalls the whole capture pipeline).
    private static let axGate = DispatchSemaphore(value: 1)

    /// Dedicated concurrent queue for OCR (Vision). Vision requests are bounded
    /// but still CPU-heavy; capping concurrency avoids thread-pool exhaustion.
    private static let ocrQueue = DispatchQueue(
        label: "activity-tracker.ocr", qos: .userInitiated, attributes: .concurrent)

    /// Bounds concurrent Vision requests (they can each block a thread while
    /// the Vision framework does its own internal scheduling). Per-instance so
    /// the width is tunable via `ocrConcurrency` without an edit.
    private let ocrGate: DispatchSemaphore

    private let config: Config

    init(config: Config) {
        self.config = config
        self.ocrGate = DispatchSemaphore(value: max(1, config.ocrConcurrency))
    }

    struct ExtractionResult {
        let text: String
        let source: SourceType
    }

    /// How an OCR attempt ended.
    ///
    /// `noText` and `unavailable` must never be conflated: the old code returned
    /// nil for both, which is how captures that lost content ended up stored
    /// identically to captures that genuinely had none.
    enum OCRResult {
        case text(String)
        /// Vision ran to completion and found no text.
        case noText
        /// Vision never got a slot, or exceeded its timeout.
        case unavailable
    }

    /// What the captured image covers.
    ///
    /// This decides whether OCR text belonging to other windows is kept. A
    /// full-desktop capture that keeps everything produces one blob whose row
    /// metadata names a single app — measured 2026-09-18: a capture labelled
    /// "Slack" also contained a VS Code file tree, an Oracle SQL*Plus banner and
    /// a Gmail newsletter, six sources under one label.
    enum CaptureScope {
        /// The image is the whole desktop; text is grouped by window and only the
        /// window this capture is about is kept.
        case screen
        /// The image is a single window, so all recognised text belongs to it.
        case window
    }

    enum SourceType: String, Codable {
        /// AX text only — OCR either was not run or added nothing.
        case accessibility
        /// OCR text only (AX returned nothing).
        case ocr
        /// Both produced text; both are stored, AX first.
        case accessibilityAndOCR = "accessibility+ocr"
        /// Both ran and neither found text. A genuinely blank capture.
        case none
        /// AX was empty and OCR never ran — the only case where a capture is
        /// missing content it should have had. Should be ~0 in a healthy run.
        case ocrUnavailable = "ocr_unavailable"
    }

    /// Extract text from the current screen context.
    /// `bundleID` optionally scopes which app to query via AX.
    /// `scope` says what the image covers, which decides whether OCR text from
    /// other windows is discarded — see `CaptureScope`.
    func extract(from image: CGImage, bundleID: String?, scope: CaptureScope) async -> ExtractionResult {
        let axText = await extractViaAX(bundleID: bundleID) ?? ""

        // With ocrEveryCapture off this is the original AX-first behaviour: OCR
        // only fires when AX came back empty.
        if !config.ocrEveryCapture, !axText.isEmpty {
            return ExtractionResult(text: axText, source: .accessibility)
        }

        switch await extractViaOCR(image: image, scope: scope, bundleID: bundleID) {
        case .text(let ocrText):
            guard !axText.isEmpty else {
                return ExtractionResult(text: ocrText, source: .ocr)
            }
            // Keep both. AX carries structure (app, window and tab titles), OCR
            // carries rendered content; in a browser AX is ~311 chars of tab
            // title against ~4,300 of page text, so discarding either loses signal.
            return ExtractionResult(
                text: axText + "\n" + ocrText,
                source: .accessibilityAndOCR
            )

        case .noText:
            return axText.isEmpty
                ? ExtractionResult(text: "", source: .none)
                : ExtractionResult(text: axText, source: .accessibility)

        case .unavailable:
            // AX covers it, so nothing is lost; the loss is only real when AX
            // was empty too, which is the case worth counting.
            return axText.isEmpty
                ? ExtractionResult(text: "", source: .ocrUnavailable)
                : ExtractionResult(text: axText, source: .accessibility)
        }
    }

    // MARK: - Accessibility (AXUIElement)

    private func extractViaAX(bundleID: String?) async -> String? {
        // Circuit breaker: if the AX worker is still busy (a previous call is
        // stuck in window-server IPC), skip AX and fall back to OCR instead of
        // piling up another blocked thread.
        guard Self.axGate.wait(timeout: .now()) == .success else {
            return nil
        }

        let app: NSRunningApplication?
        if let bundleID {
            app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
                ?? NSWorkspace.shared.frontmostApplication
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }
        guard let targetApp = app else {
            Self.axGate.signal()
            return nil
        }
        let pid = targetApp.processIdentifier

        // Run ALL AX calls on the dedicated AX thread — any AX call can block
        // indefinitely. The timeout waiter runs on the utility pool (never on
        // the contended user-initiated pool).
        return await withCheckedContinuation { continuation in
            let sem = DispatchSemaphore(value: 0)
            var result: String? = nil

            Self.axQueue.async {
                defer { Self.axGate.signal() }
                let appRef = AXUIElementCreateApplication(pid)
                var focusedWindow: CFTypeRef?
                guard AXUIElementCopyAttributeValue(appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow) == .success,
                      let window = focusedWindow else {
                    result = nil
                    sem.signal()
                    return
                }
                var allText: [String] = []
                self.collectAXText(from: window as! AXUIElement, into: &allText)
                result = allText.joined(separator: "\n")
                sem.signal()
            }

            DispatchQueue.global(qos: .utility).async {
                if sem.wait(timeout: .now() + 3) == .timedOut {
                    log("[TextExtractor] AX extraction timed out — falling back to OCR\n")
                }
                continuation.resume(returning: result)
            }
        }
    }

    /// Iterative AX tree walk — avoids stack overflow on GCD threads.
    /// Stops early once collected text exceeds the cap to avoid blocking on huge documents.
    private func collectAXText(from root: AXUIElement, into result: inout [String]) {
        var stack: [AXUIElement] = [root]
        var totalChars = 0
        let charCap = 8000

        while let element = stack.popLast() {
            if totalChars >= charCap { break }

            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
               let text = value as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let chunk = String(text.prefix(charCap - totalChars))
                result.append(chunk)
                totalChars += chunk.count
            }

            if totalChars >= charCap { break }

            var title: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXTitleAttribute as CFString, &title) == .success,
               let titleStr = title as? String, !titleStr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let chunk = String(titleStr.prefix(charCap - totalChars))
                result.append(chunk)
                totalChars += chunk.count
            }

            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) == .success,
               let childArray = children as? [AXUIElement] {
                stack.append(contentsOf: childArray.reversed())
            }
        }
    }

    // MARK: - Vision OCR

    /// OCR `image`, waiting up to `ocrWaitSec` for a slot rather than giving up
    /// immediately.
    ///
    /// The original code acquired the gate with `timeout: .now()` and returned
    /// nil on failure, so any burst silently discarded OCR work and stored the
    /// capture with empty text. Measured 2026-09-17: 26% of captures arrive in
    /// bursts exceeding a 2-wide gate, but the excess backlog is single digits
    /// draining in seconds — so waiting absorbs it, and only sustained overload
    /// reaches the deadline.
    private func extractViaOCR(image: CGImage, scope: CaptureScope, bundleID: String?) async -> OCRResult {
        guard await acquireOCRSlot() else {
            log("[TextExtractor] OCR unavailable — no slot within \(config.ocrWaitSec)s\n")
            return .unavailable
        }

        let imageSize = CGSize(width: image.width, height: image.height)
        let capturedScope = scope
        let capturedBundleID = bundleID

        // sem.wait() runs on the utility pool to avoid blocking Swift
        // concurrency threads or the contended user-initiated pool.
        return await withCheckedContinuation { continuation in
            let sem = DispatchSemaphore(value: 0)
            var ocrResult: OCRResult = .noText
            Self.ocrQueue.async {
                defer { self.ocrGate.signal() }
                let request = VNRecognizeTextRequest { request, error in
                    if error == nil,
                       let observations = request.results as? [VNRecognizedTextObservation] {
                        let text = Self.keepWindowText(
                            observations: observations,
                            imageSize: imageSize,
                            scope: capturedScope,
                            bundleID: capturedBundleID
                        )
                        ocrResult = text.isEmpty ? .noText : .text(text)
                    }
                    sem.signal()
                }
                request.recognitionLevel = .accurate
                request.usesLanguageCorrection = true
                let handler = VNImageRequestHandler(cgImage: image, options: [:])
                try? handler.perform([request])
            }
            DispatchQueue.global(qos: .utility).async {
                if sem.wait(timeout: .now() + 8) == .timedOut {
                    // The waiter gives up, but Vision keeps running and holds
                    // its gate slot until it returns — so a genuinely hung
                    // request permanently costs throughput. Logged loudly
                    // because two of these silently halve the drain rate.
                    log("[TextExtractor] OCR timed out\n")
                    continuation.resume(returning: .unavailable)
                } else {
                    continuation.resume(returning: ocrResult)
                }
            }
        }
    }

    /// Keep only the recognised text belonging to the window this capture is
    /// about, preserving the order Vision reported it in.
    ///
    /// Grouping is exact and free. The window list carries rectangles and a
    /// front-to-back z-order, so "topmost window containing this box" resolves
    /// ownership including occlusion — no image analysis needed, and it yields
    /// the owning app's *name*, which edge detection could never produce.
    ///
    /// This replaces joining every observation with newlines in Vision's
    /// detection order, which for a multi-column screen interleaves unrelated
    /// columns and for a full-desktop capture mixes every visible app together.
    private static func keepWindowText(
        observations: [VNRecognizedTextObservation],
        imageSize: CGSize,
        scope: CaptureScope,
        bundleID: String?
    ) -> String {
        // Vision boxes are normalised with a bottom-left origin; the window list
        // uses top-left points, so flip y and scale out of backing pixels.
        let desktop = ScreenWindows.desktopBoundsInPoints()
        let scale = desktop.width > 0 ? imageSize.width / desktop.width : 1

        var entries: [(text: String, centre: CGPoint)] = []
        for observation in observations {
            guard let text = observation.topCandidates(1).first?.string else { continue }
            let box = observation.boundingBox
            let x = (box.minX + box.width / 2) * imageSize.width / scale
            let y = (1 - (box.minY + box.height / 2)) * imageSize.height / scale
            entries.append((text, CGPoint(x: x + desktop.minX, y: y + desktop.minY)))
        }

        // A single-window capture *is* the window, so every observation belongs
        // to it and the screen-space geometry above would be meaningless.
        guard scope == .screen else { return entries.map(\.text).joined(separator: "\n") }

        let windows = ScreenWindows.onScreen()
        guard !windows.isEmpty else { return entries.map(\.text).joined(separator: "\n") }

        // Prefer the frontmost window of the app this capture is about, so the
        // text matches the row's app_name; otherwise the frontmost window.
        let target = bundleID.flatMap { id in windows.first { $0.bundleID == id } } ?? windows[0]
        return entries
            .filter { target.bounds.contains($0.centre) }
            .map(\.text)
            .joined(separator: "\n")
    }

    /// Take an OCR slot, yielding between attempts instead of blocking a thread
    /// for the whole wait.
    private func acquireOCRSlot() async -> Bool {
        if tryAcquireOCRSlot() { return true }
        let deadline = Date().addingTimeInterval(max(0, config.ocrWaitSec))
        while Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            if tryAcquireOCRSlot() { return true }
        }
        return false
    }

    /// Non-blocking try-acquire. Kept in a synchronous function because
    /// `DispatchSemaphore.wait` is flagged in async contexts even with a zero
    /// timeout, where it provably cannot block — and that warning is an error
    /// under the Swift 6 language mode.
    private func tryAcquireOCRSlot() -> Bool {
        ocrGate.wait(timeout: .now()) == .success
    }
}
