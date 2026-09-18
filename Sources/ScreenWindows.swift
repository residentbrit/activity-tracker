import Cocoa
import CoreGraphics

/// An on-screen window, described in screen *points* with a top-left origin —
/// the same coordinate space `CGWindowListCopyWindowInfo` reports and that
/// `CGWindowListCreateImage` captures.
struct ScreenWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let bundleID: String?
    let appName: String
    let bounds: CGRect
}

enum ScreenWindows {

    /// Layer-0 windows currently on screen, **front-to-back**.
    ///
    /// The z-order is what makes occlusion fall out for free: the first window
    /// whose bounds contain a point is the topmost visible window at that point,
    /// so no image analysis is needed to work out who owns a region of pixels.
    ///
    /// macOS composites each window's frame as a **separate** WindowServer layer
    /// literally named `borders`, sitting *in front of* the window it belongs to
    /// and about 12pt larger on every side. Left in, it wins every containment
    /// test and the whole screen is attributed to "borders" — observed on
    /// 2026-09-18. Requiring the owner to be a real running application drops
    /// that layer and the other system layers with it.
    static func onScreen() -> [ScreenWindow] {
        guard let infoList = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)
                as? [[String: Any]] else { return [] }

        var windows: [ScreenWindow] = []
        for info in infoList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let rawBounds = info[kCGWindowBounds as String] as? [String: CGFloat] else { continue }

            let appName = (info[kCGWindowOwnerName as String] as? String) ?? ""
            if appName == "borders" { continue }
            guard let running = NSRunningApplication(processIdentifier: pid) else { continue }

            let bounds = CGRect(x: rawBounds["X"] ?? 0, y: rawBounds["Y"] ?? 0,
                                width: rawBounds["Width"] ?? 0, height: rawBounds["Height"] ?? 0)
            guard bounds.width > 200, bounds.height > 100 else { continue }

            windows.append(ScreenWindow(
                windowID: id,
                pid: pid,
                bundleID: running.bundleIdentifier,
                appName: appName,
                bounds: bounds
            ))
        }
        return windows
    }

    /// The union of every active display, in points.
    ///
    /// The scale between this and a captured image is not 1: `bestResolution`
    /// returns roughly 2× the logical size on this machine (a 3840-point-wide
    /// display captures as 7816px), which is what converts a Vision bounding box
    /// into window-list coordinates.
    static func desktopBoundsInPoints() -> CGRect {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return .zero }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return .zero }

        var union = CGRect.null
        for index in 0..<Int(count) {
            union = union.union(CGDisplayBounds(ids[index]))
        }
        return union.isNull ? .zero : union
    }
}
