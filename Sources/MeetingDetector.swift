import Foundation
import Cocoa

/// Detects active meetings by matching frontmost app bundle ID against
/// the configured list, plus window-title patterns for Slack huddles (D15).
struct MeetingDetector {
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    /// Returns true if the frontmost app appears to be in a meeting.
    func isMeetingActive() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return false
        }

        // Direct bundle ID match (Teams desktop, Zoom desktop)
        if config.meetingBundleIDs.contains(bundleID) {
            // For Slack specifically: also check window title for "huddle"
            if bundleID == "com.tinyspeck.slackmacgap" {
                return hasMeetingWindowTitle()
            }
            // Teams and Zoom — assume active if the app is frontmost
            return true
        }

        // Window-title pattern match for browser-based or other edge cases
        if hasMeetingWindowTitle() {
            return true
        }

        return false
    }

    /// Returns the meeting app name for DB storage.
    func currentMeetingApp() -> String? {
        NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func hasMeetingWindowTitle() -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication else { return false }
        let appRef = AXUIElementCreateApplication(app.processIdentifier)

        var focusedWindow: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            appRef, kAXFocusedWindowAttribute as CFString, &focusedWindow
        ) == .success, let window = focusedWindow else { return false }

        var title: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            window as! AXUIElement, kAXTitleAttribute as CFString, &title
        ) == .success, let titleStr = title as? String else { return false }

        // Match against configured patterns (e.g. "huddle" for Slack)
        let lowercased = titleStr.lowercased()
        return config.meetingWindowTitlePatterns.contains { pattern in
            lowercased.contains(pattern.lowercased())
        }
    }
}
