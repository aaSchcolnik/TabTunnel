import AppKit
import Combine
import ServiceManagement
import TabTunnelModel
import TabTunnelNet

/// A browser (or Zen Live Folder) that fetched from the relay recently. Memory only.
struct RelayClient: Identifiable, Equatable {
    var id: String
    var ip: String
    var kind: String
    var name: String?
    var lastSeen: Date
    var requests: Int
    var bytes: Int
    var lastStatus: Int
}

/// One thing that’s wrong, with what to do about it.
struct Issue: Identifiable, Equatable {
    enum Severity: Int, Comparable {
        case attention = 1, problem = 2
        static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    enum Action: Equatable, Hashable {
        case openFullDiskAccess, revealReader, checkAgain, openSafari, keepSafariOpen, openICloudSettings, openTailscale
        case openSharingSettings, copyDiagnostics, openSetup, reopenApp, openFirewallSettings

        var label: String {
            switch self {
            case .openFullDiskAccess: return "Open Full Disk Access"
            case .revealReader: return "Show TabTunnel Reader"
            case .checkAgain: return "Check Again"
            case .openSafari: return "Open Safari"
            case .keepSafariOpen: return "Open and Keep Open"
            case .openICloudSettings: return "Open iCloud Settings"
            case .openTailscale: return "Open Tailscale"
            case .openFirewallSettings: return "Open Firewall Settings"
            case .openSharingSettings: return "Sharing Settings"
            case .copyDiagnostics: return "Copy Diagnostics"
            case .openSetup: return "Setup Guide"
            case .reopenApp: return "Reopen TabTunnel"
            }
        }
    }

    var id: String
    var severity: Severity
    var title: String
    var detail: String
    var actions: [Action]
}

/// The overall state, for the menu bar icon and the window header.
struct Health: Equatable {
    enum Level { case starting, ok, attention, problem }
    var level: Level
    var headline: String
    var detail: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var reader: ReaderState?
    @Published private(set) var readerLink: ReaderClient.Link = .connecting
    @Published private(set) var relay: RelayService.Status = .off
    @Published private(set) var clients: [RelayClient] = []
    @Published private(set) var lastActivity: Date?
    @Published private(set) var safariRunning = false
    @Published private(set) var safariGaveUp = false
    @Published private(set) var loginItem: SMAppService.Status = .notRegistered
    @Published private(set) var bytesSent = 0
    @Published private(set) var notModified = 0
    @Published private(set) var busy: String?
    /// A one-off message after an action (new token made, feed links reset...), with optional follow-up action.
    @Published var notice: Notice?
    /// The token or feed secret couldn't be read from or saved to the keychain.
    @Published private(set) var secretsError: String?

    struct Notice: Equatable {
        var title: String
        var detail: String
        var action: Issue.Action?
        var isError = false
    }
    @Published var settings = Settings.load() {
        didSet {
            guard settings != oldValue else { return }
            settings.save()
            apply(old: oldValue)
        }
    }

    let readerClient = ReaderClient()
    let relayService = RelayService()
    let safari = SafariKeeper()
    let startedAt = Date()
    private(set) var token = ""
    private(set) var feedSecret = ""
    private var peerNames: [String: String] = [:]
    private var tick: Timer?

    /// `live: false` (the debug gallery) touches nothing outside the process: no secrets, no settings.
    /// False for the debug gallery: settings changes never reach the server, Safari or the keychain.
    private let live: Bool

    init(live: Bool = true) {
        self.live = live
        guard live else {
            settings = Settings()
            return
        }
        do {
            token = try Secrets.load("token")
            feedSecret = try Secrets.load("feed_secret")
        } catch {
            // Without a stored token the server refuses every request (it never runs with an unsaved one).
            secretsError = error.localizedDescription
        }

        readerClient.onState = { [weak self] s in self?.readerStateChanged(s) }
        readerClient.onLink = { [weak self] l in
            self?.readerLink = l
            self?.pushToServer() // browsers see "stale" as soon as the reader is lost, not a stale "ok"
        }
        relayService.box.reader = readerClient
        relayService.onStatus = { [weak self] s in self?.relay = s }
        relayService.onEvent = { [weak self] e in self?.served(e) }
        safari.onChange = { [weak self] in
            guard let self else { return }
            self.safariRunning = self.safari.isRunning
            self.safariGaveUp = self.safari.gaveUp
        }
        loginItem = SMAppService.mainApp.status
    }

    #if DEBUG
    /// Gallery only: put the model in a given state.
    func debugSet(reader: ReaderState?, link: ReaderClient.Link, relay: RelayService.Status, clients: [RelayClient] = [],
                  safariRunning: Bool = true, bytes: Int = 0, notModified: Int = 0,
                  login: SMAppService.Status = .enabled) {
        self.reader = reader
        self.readerLink = link
        self.relay = relay
        self.clients = clients
        self.safariRunning = safariRunning
        self.bytesSent = bytes
        self.notModified = notModified
        self.loginItem = login
    }
    #endif

    func start() {
        safari.keepOpen = settings.keepSafariOpen
        safari.start()
        safariRunning = safari.isRunning
        Task.detached(priority: .userInitiated) {
            _ = ReaderAgent.ensureInstalled()
            await MainActor.run { self.readerClient.connect() }
        }
        relayService.configure(settings: settings, token: token, feedSecret: feedSecret)
        pushToServer()
        // After sleep iCloud catches up in a burst; ask for a fresh read and re-check the network.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.readerClient.refresh()
                self?.relayService.retry()
            }
        }
        // Relative times ("2 min ago") only need a slow tick, and only while a window shows them.
        tick = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.objectWillChange.send() }
        }
        tick?.tolerance = 10
    }

    private func apply(old: Settings) {
        guard live else { return }
        if settings.keepSafariOpen != old.keepSafariOpen { safari.keepOpen = settings.keepSafariOpen }
        relayService.configure(settings: settings, token: token, feedSecret: feedSecret)
        pushToServer()
    }

    private func readerStateChanged(_ s: ReaderState) {
        reader = s
        pushToServer()
    }

    private var serverError: String? {
        if case .unavailable(let why) = readerLink { return why }
        return reader?.status.problem?.message
    }

    private func pushToServer() {
        relayService.box.update(snapshot: reader?.snapshot, error: serverError, fetchFavicons: settings.fetchFavicons)
    }

    // MARK: - activity

    private func served(_ e: HTTPServer.Event) {
        bytesSent += e.bytes
        guard e.kind == .tabs || e.kind == .feed || e.kind == .feedLink else { return }
        guard e.status == 200 || e.status == 304 else { return }
        if e.status == 304 { notModified += 1 }
        if e.kind == .tabs || e.kind == .feed { lastActivity = Date() }
        let kind: String
        if let c = e.client?.lowercased() {
            kind = c.hasPrefix("firefox") ? "Firefox extension" : c.hasPrefix("chromium") ? "Chromium extension" : "Extension"
        } else if e.kind == .feed {
            kind = "Zen Live Folder"
        } else {
            kind = "Extension"
        }
        let id = e.remoteIP + "|" + kind
        if let i = clients.firstIndex(where: { $0.id == id }) {
            clients[i].lastSeen = Date()
            clients[i].requests += 1
            clients[i].bytes += e.bytes
            clients[i].lastStatus = e.status
        } else {
            clients.append(RelayClient(id: id, ip: e.remoteIP, kind: kind, name: peerNames[e.remoteIP], lastSeen: Date(),
                                       requests: 1, bytes: e.bytes, lastStatus: e.status))
            if peerNames[e.remoteIP] == nil { lookUpPeer(e.remoteIP) }
        }
        clients.sort { $0.lastSeen > $1.lastSeen }
    }

    private func lookUpPeer(_ ip: String) {
        Task.detached(priority: .utility) {
            let name = Tailscale.peerName(ip)
            await MainActor.run {
                guard let name else { return }
                self.peerNames[ip] = name
                for i in self.clients.indices where self.clients[i].ip == ip { self.clients[i].name = name }
            }
        }
    }

    // MARK: - health

    var snapshot: Snapshot? { reader?.snapshot }

    var issues: [Issue] {
        var out: [Issue] = []
        switch readerLink {
        case .unavailable(let why):
            _ = why
            out.append(Issue(id: "reader", severity: .problem, title: "TabTunnel Reader isn’t running",
                             detail: "TabTunnel can’t reach the helper that reads Safari. It keeps trying by itself. "
                                 + "If this doesn’t clear up in a minute, reopen TabTunnel: it reinstalls the helper.",
                             actions: [.reopenApp, .openSetup]))
        default: break
        }
        if let st = reader?.status, readerLink == .connected {
            switch st.problem {
            case .noAccess:
                out.append(Issue(id: "access", severity: .problem, title: "Allow access to Safari’s tabs",
                                 detail: "Click Open Full Disk Access, drag TabTunnel Reader from the Finder window into the list, "
                                     + "and turn it on. It reads only Safari’s tab and icon databases and has no network access.",
                                 actions: [.openFullDiskAccess, .openSetup]))
            case .noDatabase:
                out.append(Issue(id: "nodb", severity: .problem, title: "No iCloud Tabs on this Mac yet",
                                 detail: "Turn on Safari in System Settings › your name › iCloud, then open Safari once. "
                                     + "Tabs appear after iCloud syncs.",
                                 actions: [.openICloudSettings, .openSafari, .checkAgain]))
            case .unsupportedSchema:
                out.append(Issue(id: "schema", severity: .problem, title: "Safari changed how it stores tabs",
                                 detail: "A Safari update changed the private database TabTunnel reads, so TabTunnel needs an update "
                                     + "for this version of Safari. "
                                     + (reader?.snapshot != nil ? "You’re seeing the last tabs it could read. " : "")
                                     + "Copy Diagnostics makes a report for the developer: \(AppModel.diagnosticsPrivacy)",
                                 actions: [.copyDiagnostics]))
            case .readFailed:
                out.append(Issue(id: "read", severity: .attention, title: "Couldn’t read Safari’s tabs just now",
                                 detail: "TabTunnel will try again when Safari next saves its tabs.",
                                 actions: [.checkAgain]))
            case nil: break
            }
            if st.groupsError != nil {
                out.append(Issue(id: "groups", severity: .attention, title: "Tab Groups couldn’t be read",
                                 detail: "Tabs from your devices are current. Tab Groups show the last copy TabTunnel could read.",
                                 actions: [.checkAgain]))
            }
        }
        if !safariRunning {
            if !settings.keepSafariOpen {
                out.append(Issue(id: "safari", severity: .attention, title: "Safari is closed",
                                 detail: "Tabs from your iPhone and iPad only reach this Mac while Safari is open.",
                                 actions: [.openSafari, .keepSafariOpen]))
            } else if safariGaveUp {
                out.append(Issue(id: "safari", severity: .attention, title: "Safari won’t stay open",
                                 detail: "TabTunnel couldn’t reopen Safari. Tabs from your other devices won’t update until it’s open.",
                                 actions: [.openSafari]))
            }
        }
        if settings.sharing {
            switch relay {
            case .noTailscale:
                out.append(Issue(id: "tailscale", severity: .attention, title: "Tailscale isn’t connected",
                                 detail: "Your tabs still show here, but browsers on your other computers can’t reach this Mac.",
                                 actions: [.openTailscale]))
            case .portInUse(let p):
                out.append(Issue(id: "port", severity: .problem, title: "Port \(p) is already in use",
                                 detail: "Another program is using port \(p), so browsers can’t connect. Choose another port in Sharing settings.",
                                 actions: [.openSharingSettings]))
            case .unreachable:
                // Attention, not a problem: tabs still show here; only sharing is affected (like "Tailscale isn't connected").
                out.append(Issue(id: "blocked", severity: .attention, title: "Browsers can’t reach TabTunnel",
                                 detail: AppModel.firewallHelp(port: settings.port),
                                 actions: [.openFirewallSettings, .checkAgain]))
            case .failed:
                out.append(Issue(id: "server", severity: .attention, title: "Sharing couldn’t start",
                                 detail: "TabTunnel couldn’t open its address for your browsers. It retries automatically; click Check Again to retry now.",
                                 actions: [.checkAgain, .openSharingSettings]))
            default: break
            }
        }
        if let err = secretsError {
            out.append(Issue(id: "secrets", severity: .problem, title: "TabTunnel can’t use your keychain",
                             detail: "It stores its access token there, and couldn’t (\(err)). Sharing is off until it can. "
                                 + "Open Keychain Access to unlock your login keychain, then quit and reopen TabTunnel.",
                             actions: []))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    var health: Health {
        let issues = self.issues
        if readerLink == .connecting && reader == nil {
            return Health(level: .starting, headline: "Starting…", detail: "Getting your tabs from Safari")
        }
        if let first = issues.first {
            let more = issues.count > 1 ? "\(issues.count - 1) more \(issues.count == 2 ? "issue" : "issues")" : nil
            let context: String?
            if first.id == "schema" || first.id == "reader" {
                context = snapshot != nil ? "Showing the last tabs it could read" : "Tabs can’t be shown until this is fixed"
            } else {
                context = statusLine ?? (first.severity == .problem ? "Tabs can’t be shown until this is fixed" : nil)
            }
            return Health(level: first.severity == .problem ? .problem : .attention, headline: first.title,
                          detail: [context, more].compactMap { $0 }.joined(separator: " · "))
        }
        if case .ready = relay {
            return Health(level: .ok, headline: "Sharing your Safari tabs", detail: statusLine ?? "")
        }
        if case .starting = relay {
            return Health(level: .ok, headline: "Showing your Safari tabs", detail: "Starting sharing…")
        }
        return Health(level: .ok, headline: "Showing your Safari tabs",
                      detail: settings.sharing ? (statusLine ?? "") : "Sharing with other computers is off")
    }

    /// "112 tabs · updated 3 min ago · 1 browser"
    var statusLine: String? {
        guard let snap = snapshot else { return nil }
        var parts = ["\(snap.deviceTabCount + snap.groupTabCount) tabs", "changed \(RelativeTime.string(ISO.date(snap.updatedAt)))"]
        let active = activeClients.count
        var sharingUp = false
        switch relay {
        case .ready, .unreachable: sharingUp = true // listening (a firewall may block it, but browsers may still get through)
        default: break
        }
        if settings.sharing, sharingUp {
            // Says exactly what it counts, so it agrees with the Browsers list on the Status page.
            if active > 0 {
                parts.append(active == 1 ? "1 browser active" : "\(active) browsers active")
            } else {
                parts.append(clients.isEmpty ? "no browsers yet" : "no browser in the last 10 min")
            }
        }
        return parts.joined(separator: " · ")
    }

    /// Clients seen in the last 10 minutes (Helium checks every 2 minutes).
    var activeClients: [RelayClient] { clients.filter { Date().timeIntervalSince($0.lastSeen) < 600 } }

    // MARK: - actions

    func perform(_ action: Issue.Action) {
        switch action {
        case .openFullDiskAccess:
            // Open the list and show the Reader in Finder, ready to drag in.
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                NSWorkspace.shared.activateFileViewerSelecting([ReaderAgent.readerApp])
            }
        case .revealReader:
            NSWorkspace.shared.activateFileViewerSelecting([ReaderAgent.readerApp])
        case .checkAgain:
            if case .unavailable = readerLink { readerClient.connect() } else { readerClient.refresh() }
            relayService.retry()
            relayService.selfCheck()
        case .openSafari:
            safari.openVisible()
        case .keepSafariOpen:
            settings.keepSafariOpen = true
        case .openICloudSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.systempreferences.AppleIDSettings")!)
        case .openTailscale:
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macos")
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "io.tailscale.ipn.macsys") {
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                NSWorkspace.shared.open(URL(string: "https://tailscale.com/download/mac")!)
            }
        case .openFirewallSettings:
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension?Firewall")!)
        case .openSharingSettings:
            WindowRouter.shared.showSettings(tab: .sharing)
        case .copyDiagnostics:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(diagnostics(), forType: .string)
            announce("Diagnostics copied")
        case .reopenApp:
            // Start a fresh copy, then quit this one; the new one reinstalls and reconnects the Reader.
            let config = NSWorkspace.OpenConfiguration()
            config.createsNewApplicationInstance = true
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, _ in
                DispatchQueue.main.async { NSApp.terminate(nil) }
            }
        case .openSetup:
            WindowRouter.shared.showSetup()
        }
    }

    func rotateToken() {
        do {
            token = try Secrets.rotate("token")
            relayService.configure(settings: settings, token: token, feedSecret: feedSecret)
            notice = Notice(title: "New token made", detail: "Paste it into each browser’s TabTunnel settings. The old one no longer works.")
        } catch {
            notice = Notice(title: "Couldn’t make a new token", detail: "The current token still works. (\(error.localizedDescription))", isError: true)
        }
    }

    func rotateFeeds() {
        do {
            feedSecret = try Secrets.rotate("feed_secret")
            relayService.configure(settings: settings, token: token, feedSecret: feedSecret)
            notice = Notice(title: "Feed links reset", detail: "Copy new links from the extension for each Zen Live Folder.")
        } catch {
            notice = Notice(title: "Couldn’t reset feed links", detail: "The current links still work. (\(error.localizedDescription))", isError: true)
        }
    }

    func copyToken() { Secrets.copyConcealed(token) }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("TabTunnel: login item change failed: \(error.localizedDescription)")
        }
        loginItem = SMAppService.mainApp.status
    }

    func refreshLoginItem() { loginItem = SMAppService.mainApp.status }

    /// The firewall advice, shared by the Status card and the Setup Guide. Firewalls (macOS, Little Snitch) allow
    /// apps, not ports, so it names the app; the port is just for reference.
    static func firewallHelp(port: Int) -> String {
        "Something on this Mac may be blocking browsers, such as the macOS firewall, Little Snitch or a VPN filter. "
            + "Allow incoming connections for TabTunnel (it listens on port \(port)), then click Check Again."
    }

    /// One sentence, used wherever diagnostics are offered.
    static let diagnosticsPrivacy = "it has no tab titles, addresses, hostnames or tokens."

    /// A redacted report for bug reports: states and counts only (no titles, URLs, hostnames or secrets).
    func diagnostics() -> String {
        let st = reader?.status
        var lines = [
            "TabTunnel \(TabTunnelVersion.string), macOS \(ProcessInfo.processInfo.operatingSystemVersionString)",
            "Reader link: \(String(describing: readerLink))",
            "Reader problem: \(st?.problem?.rawValue ?? "none") \(st?.detail ?? "")",
            "Reader version: \(st?.version ?? "?")",
            "Tab Groups error: \(st?.groupsError ?? "none")",
            "Last read: \(st?.lastRead ?? "never"), last change: \(st?.lastChange ?? "never")",
            "Devices: \(snapshot?.devices.count ?? 0), device tabs: \(snapshot?.deviceTabCount ?? 0), "
                + "groups: \(snapshot?.tabGroups.count ?? 0), group tabs: \(snapshot?.groupTabCount ?? 0)",
            "Safari running: \(safariRunning), keep open: \(settings.keepSafariOpen), gave up: \(safariGaveUp)",
            "Sharing: \(settings.sharing), status: \(relayStatusText), port: \(settings.port)",
            "Favicon fetching: \(settings.fetchFavicons)",
            "Clients (10 min): \(activeClients.count), bytes sent: \(bytesSent), not-modified: \(notModified)",
            "Login item: \(loginItem.rawValue)",
        ]
        if st?.problem == .unsupportedSchema { lines.append("Schema detail: \(st?.detail ?? "")") }
        return lines.joined(separator: "\n")
    }

    var relayStatusText: String {
        switch relay {
        case .off: return "off"
        case .noTailscale: return "no Tailscale address"
        case .starting: return "starting"
        case .ready: return "ready"
        case .unreachable: return "listening but unreachable"
        case .portInUse(let p): return "port \(p) in use"
        case .failed(let m): return "failed: \(m)"
        }
    }
}

enum RelativeTime {
    static func string(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let s = now.timeIntervalSince(date)
        if s < 45 { return "just now" }
        let m = Int((s / 60).rounded())
        if m < 60 { return "\(m) min ago" }
        let h = Int((s / 3600).rounded())
        if h < 36 { return "\(h) h ago" }
        return "\(Int((s / 86400).rounded())) d ago"
    }
}
