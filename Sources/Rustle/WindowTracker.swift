import AppKit

/// A normal app window on screen, in Cocoa global coordinates (origin at the bottom-left of the primary display).
struct TrackedWindow {
    let id: Int
    let frame: CGRect
}

/// Polls the window server for the frames of on-screen app windows, front to back.
/// Window bounds are available without Screen Recording permission (only titles need it).
@MainActor
final class WindowTracker {
    static let interval: TimeInterval = 0.1

    var onUpdate: (([TrackedWindow]) -> Void)?

    private var timer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer.tolerance = Self.interval * 0.2
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        poll()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func poll() {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let primary = NSScreen.screens.first else { return }
        let primaryHeight = primary.frame.height
        var windows: [TrackedWindow] = []
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0.05,
                  let id = entry[kCGWindowNumber as String] as? Int,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary),
                  bounds.width >= 100, bounds.height >= 50 else { continue }
            let frame = CGRect(x: bounds.minX, y: primaryHeight - bounds.maxY, width: bounds.width, height: bounds.height)
            windows.append(TrackedWindow(id: id, frame: frame))
        }
        onUpdate?(windows)
    }
}
