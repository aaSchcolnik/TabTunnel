import Foundation

/// User preferences, stored in UserDefaults. Secrets are not here (see `Secrets`).
struct Settings: Equatable {
    enum TextSize: String, CaseIterable, Identifiable {
        case standard, large
        var id: String { rawValue }
        var label: String { self == .standard ? "Standard" : "Large" }
    }

    /// Show the tab list in the menu bar window. Off: the window only shows status ("status-only mode").
    var showTabs = true
    /// Serve the extensions over Tailscale.
    var sharing = true
    var port = 8787
    /// Look up icons on the web when Safari's cache has none (sites learn their own domain is open here).
    var fetchFavicons = false
    /// Reopen Safari hidden when it quits, so iCloud Tabs keep syncing.
    var keepSafariOpen = true
    var textSize: TextSize = .standard
    /// Extra names the relay answers to, besides its address and MagicDNS name.
    var extraHostnames: [String] = []
    var setupDone = false

    private static let d = UserDefaults.standard

    static func load() -> Settings {
        var s = Settings()
        if d.object(forKey: "showTabs") != nil { s.showTabs = d.bool(forKey: "showTabs") }
        if d.object(forKey: "sharing") != nil { s.sharing = d.bool(forKey: "sharing") }
        if let p = d.object(forKey: "port") as? Int, (1024...65535).contains(p) { s.port = p }
        s.fetchFavicons = d.bool(forKey: "fetchFavicons")
        if d.object(forKey: "keepSafariOpen") != nil { s.keepSafariOpen = d.bool(forKey: "keepSafariOpen") }
        s.textSize = TextSize(rawValue: d.string(forKey: "textSize") ?? "") ?? .standard
        s.extraHostnames = d.stringArray(forKey: "extraHostnames") ?? []
        s.setupDone = d.bool(forKey: "setupDone")
        return s
    }

    func save() {
        let d = Self.d
        d.set(showTabs, forKey: "showTabs")
        d.set(sharing, forKey: "sharing")
        d.set(port, forKey: "port")
        d.set(fetchFavicons, forKey: "fetchFavicons")
        d.set(keepSafariOpen, forKey: "keepSafariOpen")
        d.set(textSize.rawValue, forKey: "textSize")
        d.set(extraHostnames, forKey: "extraHostnames")
        d.set(setupDone, forKey: "setupDone")
    }
}
