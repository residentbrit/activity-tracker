import Foundation
import Vision
import Cocoa

/// AX-first, OCR-fallback text extraction (D3).
/// Accessibility tree is fast, free, resolution-independent.
/// Vision OCR only fires when AX comes back empty.
actor TextExtractor {

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
        // Use the requested app when available (tier1 polling may capture non-frontmost windows).
        let app: NSRunningApplication?
        if let bundleID {
            app = NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == bundleID }
                ?? NSWorkspace.shared.frontmostApplication
        } else {
            app = NSWorkspace.shared.frontmostApplication
        }

        guard let targetApp = app else { return nil }
        let appRef = AXUIElementCreateApplication(targetApp.processIdentifier)

        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow
        )
        guard windowResult == .success, let window = focusedWindow else { return nil }

        // Walk the AX tree with a hard timeout — a single hung AX call can block indefinitely
        return await withCheckedContinuation { continuation in
            let sem = DispatchSemaphore(value: 0)
            var result: String? = nil
            DispatchQueue.global(qos: .userInitiated).async {
                var allText: [String] = []
                self.collectAXText(from: window as! AXUIElement, into: &allText)
                result = allText.joined(separator: "\n")
                sem.signal()
            }
            // 3-second timeout: if AX hangs, return nil and fall through to OCR
            if sem.wait(timeout: .now() + 3) == .timedOut {
                log("[TextExtractor] AX extraction timed out — falling back to OCR\n")
                continuation.resume(returning: nil)
            } else {
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
        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, error in
                guard error == nil,
                      let observations = request.results as? [VNRecognizedTextObservation] else {
                    continuation.resume(returning: nil)
                    return
                }
                let text = observations.compactMap { $0.topCandidates(1).first?.string }
                    .joined(separator: "\n")
                continuation.resume(returning: text)
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            try? handler.perform([request])
        }
    }
}
