import AppKit

/// iCloud only brings other devices' tabs to this Mac while Safari is running. If the user wants, TabTunnel
/// reopens Safari hidden (no window, no focus change) a little while after it quits.
@MainActor
final class SafariKeeper {
    static let bundleID = "com.apple.Safari"
    private(set) var isRunning = false
    /// Reopening failed repeatedly; TabTunnel stops trying and asks the user instead.
    private(set) var gaveUp = false
    var keepOpen = true {
        didSet {
            if keepOpen {
                gaveUp = false
                failures = 0
                scheduleRelaunch(after: 2)
            } else {
                pending?.cancel() // turning it off also cancels a reopen that was already scheduled
                pending = nil
            }
        }
    }
    /// When TabTunnel last reopened Safari; a Safari that quits again within 2 minutes counts as a failure.
    private var lastAutoLaunch: Date?
    var onChange: () -> Void = {}
    private var failures = 0
    private var pending: DispatchWorkItem?

    func start() {
        isRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated {
                self?.isRunning = true
                self?.onChange()
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard (n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.bundleID else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isRunning = false
                // Safari quit right after TabTunnel reopened it (crashing, or the user really wants it closed):
                // after three of those, stop and ask instead of reopening it forever.
                if let t = self.lastAutoLaunch, Date().timeIntervalSince(t) < 120 {
                    self.failures += 1
                    if self.failures >= 3 { self.gaveUp = true }
                }
                self.onChange()
                self.scheduleRelaunch(after: 60)
            }
        }
        if !isRunning { scheduleRelaunch(after: 5) }
    }

    private func scheduleRelaunch(after seconds: Double) {
        pending?.cancel()
        guard keepOpen, !isRunning, !gaveUp else { return }
        let item = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.openHidden() } }
        pending = item
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: item)
    }

    /// Opens Safari without a window or focus change.
    func openHidden() {
        guard keepOpen, !gaveUp, !isRunning, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.hides = true
        config.addsToRecentItems = false
        lastAutoLaunch = Date()
        NSWorkspace.shared.openApplication(at: url, configuration: config) { [weak self] app, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if app == nil {
                    self.failures += 1
                    if self.failures >= 3 { self.gaveUp = true; self.onChange() } else { self.scheduleRelaunch(after: 60) }
                }
            }
        }
    }

    /// Opens Safari normally (the "Open Safari" button).
    func openVisible() {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else { return }
        gaveUp = false
        failures = 0
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
    }
}
