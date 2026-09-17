import CoreGraphics
import Foundation

/// Why capture is being suppressed.
///
/// Measured 2026-09-17: `CGWindowListCreateImage` returns nil whenever the
/// display is asleep, so an unattended machine produced 232 failed captures per
/// hour for seven consecutive hours (1,622 in a row) and wrote zero rows — while
/// logging one error line per attempt. Checking for this up front turns a
/// failed capture into a deliberately skipped one.
enum CaptureSuspension: String {
    case displayAsleep = "display asleep"
    case screenLocked = "screen locked"
}

/// Display and session state, shared by `CaptureEngine` (to skip captures that
/// cannot succeed) and `InputMonitor` (to treat an absent user as idle).
///
/// Both queries fail safe — they report "active" when they cannot tell — so a
/// broken query degrades to the old behaviour rather than suppressing capture
/// entirely.
enum DisplayState {

    /// True when every online display is asleep.
    ///
    /// "Online" rather than "active" because a sleeping display may drop out of
    /// the active list; if even one online display is awake we are not suspended.
    static func allDisplaysAsleep() -> Bool {
        var count: UInt32 = 0
        guard CGGetOnlineDisplayList(0, nil, &count) == .success else { return false }
        guard count > 0 else { return true }   // no online display at all
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetOnlineDisplayList(count, &ids, &count) == .success else { return false }
        for index in 0..<Int(count) where CGDisplayIsAsleep(ids[index]) == 0 {
            return false
        }
        return true
    }

    /// True only when the session is explicitly reported locked. The key is
    /// absent in the normal unlocked state, so absence means "not locked".
    static func screenIsLocked() -> Bool {
        guard let session = CGSessionCopyCurrentDictionary() as? [String: Any],
              let locked = session["CGSSessionScreenIsLocked"] else { return false }
        if let value = locked as? Bool { return value }
        if let value = locked as? NSNumber { return value.boolValue }
        return false
    }

    /// The reason capture should be skipped, or nil when a user may be present.
    static func suspensionReason() -> CaptureSuspension? {
        if allDisplaysAsleep() { return .displayAsleep }
        if screenIsLocked() { return .screenLocked }
        return nil
    }
}
