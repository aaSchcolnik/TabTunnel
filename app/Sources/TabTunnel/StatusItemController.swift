import AppKit
import Combine
import SwiftUI

/// The menu bar icon and its popover.
///
/// The icon’s shape tells the state, so it reads without color (all template images):
///   checkmark cloud = working · arrow-up cloud (briefly) = a browser just fetched tabs ·
///   exclamation cloud = needs attention · slashed cloud = not working · circular-arrow cloud = starting.
@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let popover = NSPopover()
    private let model: AppModel
    let favicons = FaviconStore()
    let popoverState = PopoverState()
    private var cancellables: Set<AnyCancellable> = []
    private var activityUntil: Date?
    private var activityTimer: Timer?
    private var lastRevision: String?
    private var lastActivitySeen: Date?

    init(model: AppModel) {
        self.model = model
        super.init()
        favicons.model = model
        popover.behavior = .transient
        popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        popover.delegate = self
        let root = PopoverView(model: model, favicons: favicons, state: popoverState) { [weak self] in self?.closePopover() }
        let host = NSHostingController(rootView: root)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        if let button = item.button {
            button.target = self
            button.action = #selector(clicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.setAccessibilityTitle("TabTunnel")
        }
        model.objectWillChange
            .debounce(for: .milliseconds(50), scheduler: RunLoop.main)
            .sink { [weak self] in self?.modelChanged() }
            .store(in: &cancellables)
        modelChanged()
    }

    private func modelChanged() {
        // A browser just fetched tabs: show the upload cloud for 1.5 s (bursts extend it; no animation).
        if let last = model.lastActivity, last != lastActivitySeen {
            lastActivitySeen = last
            activityUntil = Date().addingTimeInterval(1.5)
            activityTimer?.invalidate()
            activityTimer = Timer.scheduledTimer(withTimeInterval: 1.6, repeats: false) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateIcon() }
            }
        }
        let rev = model.reader?.revision
        if rev != lastRevision {
            lastRevision = rev
            favicons.retryMisses()
        }
        updateIcon()
    }

    private func updateIcon() {
        let health = model.health
        let active = activityUntil.map { Date() < $0 } ?? false
        let symbol = active && health.level == .ok ? "icloud.and.arrow.up" : health.level.symbol
        item.button?.image = Self.icon(symbol, description: "TabTunnel: \(health.level.spoken)")
        item.button?.toolTip = "TabTunnel: \(health.headline)" + (health.detail.isEmpty ? "" : "\n\(health.detail)")
        item.button?.setAccessibilityValue("\(health.level.spoken). \(health.headline)")
    }

    /// A menu bar glyph drawn centered on one fixed canvas, so every state sits at the same height and width
    /// (the symbols' own bounds differ: the upload cloud is taller than the others).
    static func icon(_ symbol: String, description: String) -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
        let glyph = NSImage(systemSymbolName: symbol, accessibilityDescription: description)?.withSymbolConfiguration(config)
            ?? NSImage(systemSymbolName: "icloud", accessibilityDescription: description)!
        let canvas = NSSize(width: 22, height: 18)
        let image = NSImage(size: canvas, flipped: false) { rect in
            let g = glyph.size
            glyph.draw(in: NSRect(x: (rect.width - g.width) / 2, y: (rect.height - g.height) / 2, width: g.width, height: g.height))
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = description
        return image
    }

    @objc private func clicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp || NSApp.currentEvent?.modifierFlags.contains(.control) == true {
            showMenu()
            return
        }
        togglePopover()
    }

    func togglePopover() {
        if popover.isShown { closePopover() } else { showPopover() }
    }

    func showPopover(page: PopoverPage? = nil) {
        guard let button = item.button else { return }
        if let page { popoverState.page = page }
        if !model.settings.showTabs { popoverState.page = .status }
        // Problems first: if nothing can be shown, open on Status.
        if model.snapshot == nil, model.issues.contains(where: { $0.severity == .problem }) { popoverState.page = .status }
        model.refreshLoginItem()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        popoverState.openCount += 1
    }

    /// Reopened from Finder or Spotlight. If the icon is hidden (a full menu bar, or behind the notch), a popover
    /// would point at nothing, so TabTunnel opens in a window instead.
    func showFromReopen() {
        let visible = item.isVisible && (item.button?.window?.occlusionState.contains(.visible) ?? false)
            && (item.button?.window?.frame.minX ?? -1) >= 0
        if visible {
            showPopover()
            return
        }
        WindowRouter.shared.showMain { [unowned self] in
            AnyView(PopoverView(model: model, favicons: favicons, state: popoverState, close: {
                NSApp.keyWindow?.performClose(nil)
            }))
        }
    }

    func closePopover() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        popoverState.query = ""
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open TabTunnel", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Status", action: #selector(openStatus), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Setup Guide…", action: #selector(openSetup), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit TabTunnel", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        item.menu = menu
        item.button?.performClick(nil)
        item.menu = nil
    }

    @objc private func openFromMenu() { showPopover() }
    @objc private func openStatus() { showPopover(page: .status) }
    @objc private func openSettings() { WindowRouter.shared.showSettings(tab: .general) }
    @objc private func openSetup() { WindowRouter.shared.showSetup() }
}
