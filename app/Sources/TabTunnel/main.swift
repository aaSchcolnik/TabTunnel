// TabTunnel: shows your Safari tabs (iCloud Tabs and Tab Groups) in the menu bar and shares them with the
// TabTunnel browser extensions over Tailscale. This process has the UI and the network server and no Full Disk
// Access; Safari's data comes from TabTunnel Reader over XPC.
import AppKit
import TabTunnelModel

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel!
    var statusItem: StatusItemController!

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        let args = CommandLine.arguments
        if let i = args.firstIndex(of: "--gallery"), args.count > i + 2 {
            Gallery.run(fixture: args[i + 1], out: args[i + 2])
            return
        }
        if let i = args.firstIndex(of: "--show-settings"), args.count > i + 1 {
            // Debug: open the real Settings window (native toolbar) on a preview model, for review captures.
            let preview = AppModel(live: false)
            model = preview
            WindowRouter.shared.model = preview
            WindowRouter.shared.showSettings(tab: SettingsTab(rawValue: args[i + 1]) ?? .general)
            return
        }
        #endif
        // One copy at a time: a second launch just opens the first one's window.
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? TabTunnelIDs.app)
            .filter { $0.processIdentifier != getpid() }
        if let other = others.first {
            other.activate()
            NSApp.terminate(nil)
            return
        }
        model = AppModel()
        WindowRouter.shared.model = model
        statusItem = StatusItemController(model: model)
        model.start()
        if !model.settings.setupDone {
            WindowRouter.shared.showSetup()
        }
    }

    /// Opening the app again (Finder, Spotlight) while it runs shows TabTunnel: as the popover if the menu bar
    /// icon is visible, or in a window if the menu bar is too full (or the notch hides it).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        statusItem?.showFromReopen()
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        WindowRouter.shared.terminating = true
        return .terminateNow
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
