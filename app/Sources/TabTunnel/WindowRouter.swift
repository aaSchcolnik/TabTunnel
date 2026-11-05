import AppKit
import SwiftUI

/// Opens the Settings and Setup Guide windows (one of each). The app has no Dock icon, so it activates itself
/// when a window opens.
@MainActor
final class WindowRouter: NSObject, ObservableObject, NSWindowDelegate {
    static let shared = WindowRouter()
    weak var model: AppModel?
    @Published var settingsTab: SettingsTab = .general
    private var settingsWindow: NSWindow?
    private var settingsTabs: SettingsTabsController?
    private var setupWindow: NSWindow?
    private var mainWindow: NSWindow?
    /// Set while quitting, so closing windows then doesn't count as the user dismissing them.
    var terminating = false

    func showSettings(tab: SettingsTab) {
        guard let model else { return }
        settingsTab = tab
        if settingsWindow == nil {
            let tabs = SettingsTabsController()
            tabs.tabStyle = .toolbar
            for t in SettingsTab.allCases {
                let host = NSHostingController(rootView: t.pane(model))
                host.sizingOptions = [.preferredContentSize]
                let item = NSTabViewItem(viewController: host)
                item.label = t.title
                item.image = NSImage(systemSymbolName: t.symbol, accessibilityDescription: t.title)
                tabs.addTabViewItem(item)
            }
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.delegate = self
            settingsWindow = w
            settingsTabs = tabs
        }
        settingsTabs?.selectedTabViewItemIndex = SettingsTab.allCases.firstIndex(of: tab) ?? 0
        settingsTabs?.fitWindow()
        settingsWindow?.center()
        present(settingsWindow!)
    }

    func showSetup() {
        guard let model else { return }
        if setupWindow == nil {
            let view = SetupView(model: model) { [weak self] in
                model.settings.setupDone = true
                self?.setupWindow?.close()
            }
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = "TabTunnel Setup"
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            setupWindow = w
        }
        present(setupWindow!)
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
        // Nothing pre-focused: a stray keystroke must not replace a field's contents (e.g. the port).
        w.makeFirstResponder(nil)
    }

    /// TabTunnel in an ordinary window: used when the menu bar icon can't be seen.
    func showMain(_ content: () -> AnyView) {
        if mainWindow == nil {
            let w = NSWindow(contentViewController: NSHostingController(rootView: content()))
            w.title = "TabTunnel"
            w.styleMask = [.titled, .closable, .miniaturizable]
            w.isReleasedWhenClosed = false
            w.center()
            mainWindow = w
        }
        present(mainWindow!)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the guide (Close, Done or the close button) means the user has seen it; quitting doesn't.
        if (notification.object as? NSWindow) === setupWindow, !terminating { model?.settings.setupDone = true }
    }
}

/// Native toolbar tabs for Settings. The window takes each pane's height (keeping its top edge in place) and its
/// title.
final class SettingsTabsController: NSTabViewController {
    override func tabView(_ tabView: NSTabView, didSelect item: NSTabViewItem?) {
        super.tabView(tabView, didSelect: item)
        fitWindow()
        view.window?.makeFirstResponder(nil) // a pane never opens with a field focused and its text selected
    }

    func fitWindow() {
        guard let item = tabViewItems[safe: selectedTabViewItemIndex], let view = item.viewController?.view,
              let window = view.window ?? self.view.window else { return }
        window.title = item.label
        let size = view.fittingSize
        guard size.height > 0 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        let frame = window.frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - size.height,
                                                            width: max(size.width, 540), height: size.height))
        window.setFrame(frame, display: true, animate: window.isVisible && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
