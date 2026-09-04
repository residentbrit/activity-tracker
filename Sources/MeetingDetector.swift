import Foundation
import Cocoa
import CoreAudio
import CoreGraphics

/// Detects active meetings.
///
/// Primary signal: a configured meeting app (Teams/Zoom/Slack) is actively
/// using the microphone — the same signal behind the macOS menu-bar orange
/// dot. This is independent of which app is frontmost, so it survives
/// clicking around during a call. Fallback: frontmost-app + window-title
/// heuristics (covers muted stretches while a meeting app is focused, and
/// Slack huddles).
struct MeetingDetector {
    private let config: Config

    init(config: Config) {
        self.config = config
    }

    /// Returns true if a meeting appears to be active right now (start trigger).
    func isMeetingActive() -> Bool {
        if isMeetingAppUsingMicrophone() {
            return true
        }

        // Fallback: frontmost app is a meeting app (or has a huddle title).
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            return false
        }
        if config.meetingBundleIDs.contains(bundleID) {
            // For Slack specifically: also check window title for "huddle"
            if bundleID == "com.tinyspeck.slackmacgap" {
                return hasMeetingWindowTitle()
            }
            // Teams and Zoom — assume active if the app is frontmost
            return true
        }

        // Window-title pattern match for browser-based or other edge cases
        return hasMeetingWindowTitle()
    }

    /// True if any configured meeting app is currently holding the microphone.
    ///
    /// Matches sub-bundles too (e.g. `com.microsoft.teams2.helper` counts as
    /// Teams), because the process that actually opens the mic may be a helper.
    func isMeetingAppUsingMicrophone() -> Bool {
        let micUsers = Self.bundleIDsUsingMicrophone()
        return micUsers.contains { bid in
            config.meetingBundleIDs.contains { meeting in
                bid == meeting || bid.hasPrefix(meeting + ".")
            }
        }
    }

    /// Returns the meeting app bundle ID for DB storage, preferring whichever
    /// meeting app is actually using the mic over the frontmost app.
    func currentMeetingApp() -> String? {
        let micUsers = Self.bundleIDsUsingMicrophone()
        for meeting in config.meetingBundleIDs {
            if micUsers.contains(where: { $0 == meeting || $0.hasPrefix(meeting + ".") }) {
                return meeting
            }
        }
        return NSWorkspace.shared.frontmostApplication?.bundleIdentifier
    }

    private func hasMeetingWindowTitle() -> Bool {
        guard AXIsProcessTrusted() else { return false }
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

    // MARK: - Meeting window tracking (CGWindowList)

    /// Identity of the meeting window to track across polls.
    struct MeetingWindowRef {
        let title: String
        let windowNumber: CGWindowID
    }

    /// The frontmost on-screen **call** window owned by the meeting app, or nil
    /// if none is identifiable yet. Snapshot at meeting start so we can watch
    /// for it to disappear later. Main/app windows (e.g. "Calendar | Microsoft
    /// Teams") are skipped — they persist after the call ends and would make
    /// the meeting never end.
    func frontmostMeetingWindow(for bundleID: String) -> MeetingWindowRef? {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map { $0.processIdentifier })
        guard !pids.isEmpty else { return nil }

        // On-screen list is ordered front-to-back; first non-base match is the
        // app's frontmost call window.
        for info in Self.windowList(onScreenOnly: true) {
            guard let pid = Self.ownerPID(info), pids.contains(pid) else { continue }
            let title = Self.windowTitle(info)
            if isBaseWindowTitle(title, for: bundleID) { continue }
            return MeetingWindowRef(
                title: title,
                windowNumber: Self.windowNumber(info)
            )
        }
        return nil
    }

    /// True while a window matching the snapshot (same owner + title, or same
    /// window number) is still present. Uses the full window list so minimized
    /// windows still count as "the meeting is open".
    func windowStillPresent(_ ref: MeetingWindowRef, for bundleID: String) -> Bool {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .map { $0.processIdentifier })
        guard !pids.isEmpty else { return false }

        for info in Self.windowList(onScreenOnly: false) {
            guard let pid = Self.ownerPID(info), pids.contains(pid) else { continue }
            if Self.windowNumber(info) == ref.windowNumber {
                return true
            }
            if !ref.title.isEmpty && Self.windowTitle(info) == ref.title {
                return true
            }
        }
        return false
    }

    /// True if the window title is the meeting app's base/main window (which
    /// stays open after a call) rather than a call window (which closes).
    private func isBaseWindowTitle(_ title: String, for bundleID: String) -> Bool {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return true }
        let lower = t.lowercased()
        switch bundleID {
        case "com.microsoft.teams", "com.microsoft.teams2":
            return t == "Microsoft Teams" || t.hasSuffix("| Microsoft Teams")
        case "us.zoom.xos":
            return t == "Zoom Workplace" || lower == "zoom.us" || t == "Zoom"
        case "com.tinyspeck.slackmacgap":
            return t == "Slack" || t.hasSuffix("| Slack")
        default:
            return t == (NSWorkspace.shared.frontmostApplication?.localizedName ?? "")
        }
    }

    private static func windowList(onScreenOnly: Bool) -> [[String: Any]] {
        var options: CGWindowListOption = [.excludeDesktopElements]
        options.insert(onScreenOnly ? .optionOnScreenOnly : .optionAll)
        return (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
    }

    private static func ownerPID(_ info: [String: Any]) -> pid_t? {
        (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value
    }

    private static func windowTitle(_ info: [String: Any]) -> String {
        info[kCGWindowName as String] as? String ?? ""
    }

    private static func windowNumber(_ info: [String: Any]) -> CGWindowID {
        CGWindowID((info[kCGWindowNumber as String] as? NSNumber)?.uint32Value ?? 0)
    }

    // MARK: - CoreAudio mic-usage enumeration

    /// Bundle IDs of processes with an active input (microphone) stream.
    ///
    /// Enumerates HAL client process objects (public CoreAudio API), filters to
    /// those with an active input stream, and resolves each PID to a bundle ID
    /// via NSRunningApplication. Observing usage requires no TCC mic permission
    /// (only capturing does).
    private static func bundleIDsUsingMicrophone() -> Set<String> {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var processes = [AudioObjectID](repeating: kAudioObjectUnknown, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &processes
        ) == noErr else { return [] }

        var result = Set<String>()
        for process in processes {
            guard isRunningInput(process),
                  let bundleID = bundleIdentifier(for: process) else { continue }
            result.insert(bundleID)
        }
        return result
    }

    /// True if the process currently has an active input (mic) stream.
    private static func isRunningInput(_ process: AudioObjectID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &value) == noErr else {
            return false
        }
        return value != 0
    }

    /// Bundle ID for a process object, resolved via its PID.
    private static func bundleIdentifier(for process: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(process, &addr, 0, nil, &size, &pid) == noErr else {
            return nil
        }
        return NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }
}
