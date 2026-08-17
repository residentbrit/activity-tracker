import Foundation
import Vision
import Cocoa

/// AX-first, OCR-fallback text extraction (D3).
/// Accessibility tree is fast, free, resolution-independent.
/// Vision OCR only fires when AX comes back empty.
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
    /// the Vision framework does its own internal scheduling).
    private static let ocrGate = DispatchSemaphore(value: 2)

    struct ExtractionResult {
        let text: String
        let source: SourceType
    }

    enum SourceType: String, Codable {
        case accessibility
        case ocr
    }

    /// Extract text from the current screen context.
    /// `bundleID` optionally scopes which app to query via AX.
    func extract(from image: CGImage, bundleID: String?) async -> ExtractionResult {
        // 1. Try accessibility tree first
        if let axText = await extractViaAX(bundleID: bundleID), !axText.isEmpty {
            return ExtractionResult(text: axText, source: .accessibility)
        }

        // 2. Fall back to OCR
        if let ocrText = await extractViaOCR(image: image) {
            return ExtractionResult(text: ocrText, source: .ocr)
        }

        // Nothing found
        return ExtractionResult(text: "", source: .accessibility)
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

    private func extractViaOCR(image: CGImage) async -> String? {
        // Bound concurrent Vision requests to avoid piling up blocked threads.
        guard Self.ocrGate.wait(timeout: .now()) == .success else {
            return nil
        }

        // sem.wait() runs on the utility pool to avoid blocking Swift
        // concurrency threads or the contended user-initiated pool.
        return await withCheckedContinuation { continuation in
            let sem = DispatchSemaphore(value: 0)
            var ocrResult: String? = nil
            Self.ocrQueue.async {
                defer { Self.ocrGate.signal() }
                let request = VNRecognizeTextRequest { request, error in
                    if error == nil,
                       let observations = request.results as? [VNRecognizedTextObservation] {
                        ocrResult = observations.compactMap { $0.topCandidates(1).first?.string }
                            .joined(separator: "\n")
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
                    log("[TextExtractor] OCR timed out\n")
                }
                continuation.resume(returning: ocrResult)
            }
        }
    }
}
