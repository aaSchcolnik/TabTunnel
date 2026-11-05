import Foundation
import Network
import TabTunnelModel
import TabTunnelNet

/// Thread-safe holder for what the HTTP server serves.
final class RelayBox: RelayBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: Snapshot?
    private var error: String?
    private var fetchFavicons = false
    let fetcher = FaviconFetcher()
    weak var reader: ReaderClient?

    func update(snapshot: Snapshot?, error: String?, fetchFavicons: Bool) {
        lock.withLock {
            self.snapshot = snapshot
            self.error = error
            self.fetchFavicons = fetchFavicons
        }
    }

    func current() -> (snapshot: Snapshot?, error: String?) { lock.withLock { (snapshot, error) } }

    func favicon(pageURL: String) async -> (Data, String)? {
        let fetch = lock.withLock { fetchFavicons }
        if let d = await reader?.favicon(pageURL), let r = ImageKind.forBrowsers(d) { return r }
        guard fetch, let d = await fetcher.icon(forPage: pageURL) else { return nil }
        return ImageKind.forBrowsers(d)
    }
}

/// Runs the HTTP server on this Mac's Tailscale address and follows that address as it comes and goes.
@MainActor
final class RelayService {
    enum Status: Equatable {
        /// Sharing is turned off in Settings.
        case off
        /// No Tailscale address on this Mac.
        case noTailscale
        case starting
        case ready(url: String)
        /// Listening, but a request to its own address got no answer: something on this Mac (a firewall such as
        /// Little Snitch, a VPN filter) is blocking connections.
        case unreachable(url: String)
        case portInUse(Int)
        case failed(String)
    }

    let box = RelayBox()
    private(set) var router: Router!
    private var server: HTTPServer!
    private let monitor = NWPathMonitor()
    private var settings = Settings()
    private var token = ""
    private var feedSecret = ""
    private(set) var bindIP: String?
    private(set) var dnsName: String?
    private var lastServerState: HTTPServer.State = .stopped
    var onStatus: (Status) -> Void = { _ in }
    var onEvent: (HTTPServer.Event) -> Void = { _ in }
    private(set) var status: Status = .off { didSet { if status != oldValue { onStatus(status) } } }

    init() {
        router = Router(config: .init(token: "", feedSecret: "", allowedHosts: []), backend: box)
        server = HTTPServer(router: router, onEvent: { [weak self] e in
            DispatchQueue.main.async { self?.onEvent(e) }
        }, onState: { [weak self] s in
            DispatchQueue.main.async { self?.serverStateChanged(s) }
        })
    }

    private var monitoring = false

    func configure(settings: Settings, token: String, feedSecret: String) {
        if !monitoring {
            monitoring = true
            monitor.pathUpdateHandler = { [weak self] _ in
                // Tailscale coming up, going down or changing address all show up as path changes.
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.reevaluate() }
            }
            monitor.start(queue: DispatchQueue(label: "dev.tabtunnel.path"))
        }
        let restart = settings.port != self.settings.port || settings.sharing != self.settings.sharing
        self.settings = settings
        self.token = token
        self.feedSecret = feedSecret
        updateRouter()
        reevaluate(force: restart)
    }

    var url: String? {
        guard let ip = bindIP else { return nil }
        return "http://\(dnsName ?? ip):\(settings.port)"
    }

    private func updateRouter() {
        guard monitoring else { return }
        guard let ip = bindIP else { return }
        let names = [dnsName].compactMap { $0 } + settings.extraHostnames
        router.config = .init(token: token, feedSecret: feedSecret,
                              allowedHosts: Router.allowedHosts(bind: ip, port: settings.port, names: names))
    }

    /// Re-checks the Tailscale address and (re)binds when it changed.
    func reevaluate(force: Bool = false) {
        guard monitoring else { return } // not configured yet (or the debug gallery)
        guard settings.sharing else {
            if bindIP != nil || status != .off { server.stop() }
            bindIP = nil
            status = .off
            return
        }
        guard let ip = Tailscale.ipv4() else {
            if bindIP != nil { server.stop() }
            bindIP = nil
            status = .noTailscale
            return
        }
        // Same address and the listener is up or coming up: nothing to do. Failed states (port in use, address
        // gone, other errors) are retried on every network change and by `scheduleRetry`.
        if ip == bindIP && !force && (lastServerState == .ready || lastServerState == .starting) {
            if case .unreachable = status { selfCheck() }
            return
        }
        bindIP = ip
        updateRouter()
        status = .starting
        server.start(host: ip, port: UInt16(settings.port))
        Task.detached(priority: .utility) { [weak self] in
            let name = Tailscale.reverseName(ip) ?? Tailscale.dnsNameFromCLI()
            await MainActor.run {
                guard let self, self.bindIP == ip else { return }
                self.dnsName = name
                self.updateRouter()
                if case .ready = self.status, let url = self.url { self.status = .ready(url: url) }
                if case .unreachable = self.status, let url = self.url { self.status = .unreachable(url: url) }
            }
        }
    }

    private func serverStateChanged(_ s: HTTPServer.State) {
        lastServerState = s
        guard settings.sharing else { return }
        switch s {
        case .ready:
            retryDelay = 5
            status = .ready(url: url ?? "")
            selfCheck()
        case .starting: status = .starting
        case .portInUse:
            status = .portInUse(settings.port)
            scheduleRetry()
        case .addressUnavailable:
            status = .noTailscale
            scheduleRetry()
        case .failed(let m):
            status = .failed(m)
            scheduleRetry()
        case .stopped: break
        }
    }

    /// Asks its own /health over the Tailscale address, the way a browser would, so a blocked port shows up in
    /// Status instead of only in the browser. Runs when sharing starts and on "Check Again".
    func selfCheck() {
        guard let ip = bindIP, let url = URL(string: "http://\(ip):\(settings.port)/health") else { return }
        let shown = self.url ?? ""
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 4)
        req.httpMethod = "GET"
        let session = URLSession(configuration: .ephemeral)
        session.dataTask(with: req) { [weak self] _, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            DispatchQueue.main.async {
                guard let self, self.bindIP == ip else { return }
                switch self.status {
                case .ready, .unreachable: self.status = ok ? .ready(url: self.url ?? shown) : .unreachable(url: self.url ?? shown)
                default: break
                }
            }
        }.resume()
        session.finishTasksAndInvalidate()
    }

    /// Try again after something outside changed (port freed, network back).
    func retry() {
        retryDelay = 5
        reevaluate(force: true)
    }

    private var retryDelay: Double = 5
    private var retryPending = false

    /// After a failure, try again with backoff (5 s, 10 s, ... up to 5 min), in case the port is freed or the
    /// address comes back without a network change.
    private func scheduleRetry() {
        guard !retryPending else { return }
        retryPending = true
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 300)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryPending = false
            switch self.status {
            case .portInUse, .failed, .noTailscale: self.reevaluate(force: true)
            default: self.retryDelay = 5
            }
        }
    }
}
