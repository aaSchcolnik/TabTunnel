import CryptoKit
import Foundation
import TabTunnelModel

/// What the server serves, provided by the app (from the reader) or by the dev tool (from fixtures).
public protocol RelayBackend: AnyObject, Sendable {
    /// The last good snapshot (nil if there has never been one) and the current problem, if any.
    func current() -> (snapshot: Snapshot?, error: String?)
    /// The page's icon: Safari's cache first, then (if enabled) fetched. (bytes, content type) or nil.
    func favicon(pageURL: String) async -> (Data, String)?
}

/// Which endpoint answered, for the activity indicator and the "connected browsers" list.
public enum RouteKind: String, Sendable {
    case tabs, feed, feedLink, favicon, health, rejectedHost, rejectedAuth, notFound, badRequest
}

/// The relay's HTTP API, kept compatible with the Python relay the extensions were built against:
///   GET /health                  -> {"ok": bool}               (no auth, no details)
///   GET /tabs (or /)             -> snapshot JSON; ETag + If-None-Match -> 304
///   GET /favicon?url=<page>      -> icon bytes or 404
///   GET /feeds/<group>/link      -> {"url"}: a per-group RSS address for Zen Live Folders
///   GET /feeds/<group>.rss?key=  -> RSS for one group; the key opens nothing else; ETag -> 304
/// Everything except /health and feeds needs "Authorization: Bearer <token>". The Host header must name this
/// relay (blocks DNS rebinding). No CORS headers: extensions with host permission don't need them, so web pages
/// can't read any response.
public final class Router: @unchecked Sendable {
    public struct Config: Sendable {
        public var token: String
        public var feedSecret: String
        public var allowedHosts: Set<String>

        public init(token: String, feedSecret: String, allowedHosts: Set<String>) {
            self.token = token
            self.feedSecret = feedSecret
            self.allowedHosts = allowedHosts
        }
    }

    private let lock = NSLock()
    private var _config: Config
    public var config: Config {
        get { lock.lock(); defer { lock.unlock() }; return _config }
        set { lock.lock(); _config = newValue; lock.unlock() }
    }
    private let backend: RelayBackend
    private var bodyCache: (etag: String, body: Data)?

    public init(config: Config, backend: RelayBackend) {
        _config = config
        self.backend = backend
    }

    public static func allowedHosts(bind: String, port: Int, names: [String]) -> Set<String> {
        var all = Set([bind.lowercased()] + names.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) }
            .filter { !$0.isEmpty })
        if ["127.0.0.1", "::1", "localhost"].contains(bind) { all.formUnion(["127.0.0.1", "localhost", "::1"]) }
        var out = Set<String>()
        for n in all {
            out.insert(n)
            out.insert("\(n):\(port)")
            if n.contains(":") && !n.hasPrefix("[") { out.insert("[\(n)]:\(port)"); out.insert("[\(n)]") }
        }
        return out
    }

    public func handle(_ req: HTTPRequest) async -> (HTTPResponse, RouteKind) {
        let cfg = config
        guard req.method == "GET" || req.method == "HEAD" else {
            var r = HTTPResponse.json(405, ["error": "method not allowed"])
            r.headers.append(("Allow", "GET"))
            return (r, .badRequest)
        }
        var (response, kind) = await route(req, cfg)
        if req.method == "HEAD" { response.body = Data() }
        return (response, kind)
    }

    private func route(_ req: HTTPRequest, _ cfg: Config) async -> (HTTPResponse, RouteKind) {
        let host = (req.headers["host"] ?? "").lowercased()
        var trimmedHost = host
        while trimmedHost.hasSuffix(".") { trimmedHost.removeLast() }
        guard cfg.allowedHosts.contains(host) || cfg.allowedHosts.contains(trimmedHost) else {
            return (.json(421, ["error": "wrong host"]), .rejectedHost)
        }
        let path = req.path

        if path == "/health" {
            let (snap, error) = backend.current()
            return (.json(200, ["ok": snap != nil && error == nil]), .health)
        }

        // Zen Live Folders can't send headers: feeds take a per-group key that opens nothing else.
        if path.hasPrefix("/feeds/") && path.hasSuffix(".rss") {
            let gid = String(path.dropFirst("/feeds/".count).dropLast(".rss".count)).removingPercentEncoding ?? ""
            let key = req.query("key") ?? ""
            guard !cfg.feedSecret.isEmpty, !key.isEmpty, constantTimeEqual(key, Self.feedKey(secret: cfg.feedSecret, group: gid)) else {
                return (.json(401, ["error": "missing or wrong feed key"]), .rejectedAuth)
            }
            let (snap, _) = backend.current()
            guard let group = snap?.tabGroups.first(where: { $0.id == gid }) else {
                return (.json(404, ["error": "no such tab group"]), .feed)
            }
            let date = ISO.date(snap?.sourceModifiedAt) ?? ISO.date(snap?.updatedAt) ?? Date()
            let body = RSS.feed(for: group, baseURL: "http://\(host)", date: date)
            let etag = "\"" + SHA256.hash(data: body).prefix(12).map { String(format: "%02x", $0) }.joined() + "\""
            if matches(req.headers["if-none-match"], etag) {
                return (HTTPResponse(status: 304, headers: [("ETag", etag)], cache: "no-cache"), .feed)
            }
            return (HTTPResponse(status: 200, contentType: "text/xml; charset=utf-8", body: body,
                                 headers: [("ETag", etag)], cache: "no-cache"), .feed)
        }

        guard bearerOK(req.headers["authorization"], cfg.token) else {
            return (.json(401, ["error": "missing or wrong token"]), .rejectedAuth)
        }

        if path == "/" || path == "/tabs" {
            let (snap, error) = backend.current()
            guard let snap else {
                return (.json(503, ["error": error ?? "TabTunnel isn't ready yet."]), .tabs)
            }
            // Authenticated first, then conditional: a 304 never confirms anything to a stranger.
            // The error text is part of the version: a different problem is a different response.
            let staleTag = error.map { "-stale-" + SHA256.hash(data: Data($0.utf8)).prefix(4).map { String(format: "%02x", $0) }.joined() } ?? ""
            let etag = "\"\(snap.contentHash)\(staleTag)\""
            if matches(req.headers["if-none-match"], etag) {
                return (HTTPResponse(status: 304, headers: [("ETag", etag)], cache: "no-cache"), .tabs)
            }
            return (HTTPResponse(status: 200, contentType: "application/json; charset=utf-8",
                                 body: body(for: snap, error: error, etag: etag), headers: [("ETag", etag)], cache: "no-cache"), .tabs)
        }

        if path.hasPrefix("/feeds/") && path.hasSuffix("/link") {
            let gid = String(path.dropFirst("/feeds/".count).dropLast("/link".count)).removingPercentEncoding ?? ""
            guard !cfg.feedSecret.isEmpty else {
                return (.json(503, ["error": "Feeds are not set up. Open TabTunnel's settings."]), .feedLink)
            }
            let url = "http://\(host)/feeds/\(Self.quote(gid)).rss?key=\(Self.feedKey(secret: cfg.feedSecret, group: gid))"
            return (.json(200, ["url": url]), .feedLink)
        }

        if path == "/favicon" {
            let page = req.query("url") ?? ""
            // Answer within the connection's 10 s: a slow site gets a 404 now, and the lookup finishes into the
            // fetcher's cache for the next request.
            guard let (data, type) = await Self.withDeadline(8, { await self.backend.favicon(pageURL: page) }) ?? nil else {
                return (HTTPResponse(status: 404, contentType: "text/plain"), .favicon)
            }
            return (HTTPResponse(status: 200, contentType: type, body: data, cache: "private, no-store"), .favicon)
        }

        return (.json(404, ["error": "not found"]), .notFound)
    }

    /// Runs `work`, giving up (nil) after `seconds`. The work itself keeps running (a favicon lookup finishes
    /// into the cache); only the wait ends.
    static func withDeadline<T: Sendable>(_ seconds: Double, _ work: @escaping @Sendable () async -> T) async -> T? {
        return await withCheckedContinuation { (cont: CheckedContinuation<T?, Never>) in
            let once = OnceFlag()
            Task {
                let value = await work()
                if once.claim() { cont.resume(returning: value) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                if once.claim() { cont.resume(returning: nil) }
            }
        }
    }

    private func body(for snap: Snapshot, error: String?, etag: String) -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let c = bodyCache, c.etag == etag { return c.body }
        var data = (try? JSONEncoder.wire.encode(snap)) ?? Data("{}".utf8)
        if let error, var obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] {
            obj["stale"] = true
            obj["error"] = error
            data = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? data
        }
        bodyCache = (etag, data)
        return data
    }

    private func matches(_ header: String?, _ etag: String) -> Bool {
        guard let header else { return false }
        return header.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "W/", with: "") == etag }
    }

    private func bearerOK(_ header: String?, _ token: String) -> Bool {
        guard !token.isEmpty, let header, header.hasPrefix("Bearer ") else { return false }
        return constantTimeEqual(String(header.dropFirst(7)), token)
    }

    /// Per-group feed key: HMAC-SHA256(feed_secret, "feed:" + group id), first 32 hex characters.
    /// Same derivation as the Python relay, so existing Zen Live Folder URLs keep working.
    public static func feedKey(secret: String, group: String) -> String {
        let mac = HMAC<SHA256>.authenticationCode(for: Data(("feed:" + group).utf8), using: SymmetricKey(data: Data(secret.utf8)))
        return String(mac.map { String(format: "%02x", $0) }.joined().prefix(32))
    }

    /// Python's urllib.parse.quote(s, safe=""): everything but letters, digits and _.-~ is percent-encoded.
    static func quote(_ s: String) -> String {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_.-~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }
}

func constantTimeEqual(_ a: String, _ b: String) -> Bool {
    let x = Array(a.utf8), y = Array(b.utf8)
    var diff = UInt8(x.count == y.count ? 0 : 1)
    for i in 0..<max(x.count, y.count) {
        diff |= (i < x.count ? x[i] : 0) ^ (i < y.count ? y[i] : 0)
    }
    return diff == 0
}

enum RSS {
    private static func escape(_ s: String) -> String {
        // XML 1.0 forbids most control characters outright; then escape like xml.sax.saxutils.escape.
        let cleaned = String(String.UnicodeScalarView(s.unicodeScalars.filter { u in
            let v = u.value
            return !((v <= 0x08) || v == 0x0b || v == 0x0c || (v >= 0x0e && v <= 0x1f) || v == 0xfffe || v == 0xffff)
        }))
        return cleaned.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    static func rfc822(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f.string(from: date)
    }

    /// RSS 2.0 for one tab group, shaped for Zen's RSS Live Folders (each item needs a link and a date).
    /// Navigating a Safari tab changes its URL; the guid is uuid+url so Zen swaps that tab.
    static func feed(for group: TabGroup, baseURL: String, date: Date) -> Data {
        let d = rfc822(date)
        var items = ""
        for t in group.tabs {
            let guid = "\(t.id ?? "")|\(t.url)"
            items += "<item><title>\(escape(t.title))</title><link>\(escape(t.url))</link>"
                + "<guid isPermaLink=\"false\">\(escape(guid))</guid><pubDate>\(d)</pubDate></item>"
        }
        let xml = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<rss version=\"2.0\"><channel>"
            + "<title>\(escape(group.title))</title><link>\(escape(baseURL))</link>"
            + "<description>Safari tab group \(escape(group.title))</description><lastBuildDate>\(d)</lastBuildDate>\(items)"
            + "</channel></rss>\n"
        return Data(xml.utf8)
    }
}

/// True exactly once, from any thread.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool { lock.withLock { if done { return false }; done = true; return true } }
}
