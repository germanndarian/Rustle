import AppKit
import IOKit.ps

/// Tracks when the leaves should rest (screen asleep, locked, screensaver)
/// and when they should spend less (on battery or in Low Power Mode).
@MainActor
final class PowerMonitor {
    var onChange: (() -> Void)?

    private(set) var isSuspended = false
    private(set) var savesPower = false

    private var screensAsleep = false
    private var sessionInactive = false
    private var locked = false
    private var screensaver = false
    private var timer: Timer?

    init() {
        let workspace = NSWorkspace.shared.notificationCenter
        observe(workspace, NSWorkspace.screensDidSleepNotification) { $0.screensAsleep = true }
        observe(workspace, NSWorkspace.screensDidWakeNotification) { $0.screensAsleep = false }
        observe(workspace, NSWorkspace.sessionDidResignActiveNotification) { $0.sessionInactive = true }
        observe(workspace, NSWorkspace.sessionDidBecomeActiveNotification) { $0.sessionInactive = false }

        let distributed = DistributedNotificationCenter.default()
        observe(distributed, Notification.Name("com.apple.screenIsLocked")) { $0.locked = true }
        observe(distributed, Notification.Name("com.apple.screenIsUnlocked")) { $0.locked = false }
        observe(distributed, Notification.Name("com.apple.screensaver.didstart")) { $0.screensaver = true }
        observe(distributed, Notification.Name("com.apple.screensaver.didstop")) { $0.screensaver = false }

        observe(NotificationCenter.default, Notification.Name.NSProcessInfoPowerStateDidChange) { _ in }

        // Power source changes are rare; a slow poll is enough and avoids a run-loop source.
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        update()
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, _ change: @escaping (PowerMonitor) -> Void) {
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                change(self)
                self.update()
            }
        }
    }

    private func update() {
        let suspended = screensAsleep || sessionInactive || locked || screensaver
        let saving = ProcessInfo.processInfo.isLowPowerModeEnabled || Self.onBattery()
        guard suspended != isSuspended || saving != savesPower else { return }
        isSuspended = suspended
        savesPower = saving
        onChange?()
    }

    private static func onBattery() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return false }
        return (type as String) == "Battery Power"
    }
}
