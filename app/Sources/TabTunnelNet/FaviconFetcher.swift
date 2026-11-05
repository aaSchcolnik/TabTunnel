import Foundation
import Network

/// Finds a site's icon on the web when Safari's cache has none.
///
/// Privacy and safety fence (same as the Python relay):
/// - Only the site's home page and icon files are requested, never the page you had open (path, query), so a
///   site learns only that its own domain is open on this Mac. DuckDuckGo's and Google's icon services are the
///   last resort and learn only the domain.
/// - Every connection and redirect hop goes only to a public address (see `PublicAddress`). It connects to the
///   checked IP itself (TLS still verifies the real hostname), so DNS can't be swapped between check and use.
/// - http(s) on ports 80/443 only, 4 redirects, 4 s per connection, a 14 s budget per site, 1 MB per icon,
///   4 sites at once. Results (including misses) stay in memory only, at most 1000 sites.
public final class FaviconFetcher: @unchecked Sendable {
    public static let maxIconBytes = 1024 * 1024
    private let lock = NSLock()
    private var cache: [String: Data?] = [:]
    private var order: [String] = []
    private let slots = DispatchSemaphore(value: 4)
    private var inFlight: [String: [CheckedContinuation<Data?, Never>]] = [:]

    public init() {}

    public static func host(of url: String) -> String {
        guard let c = URLComponents(string: url), let s = c.scheme?.lowercased(), s == "http" || s == "https",
              let h = c.host?.lowercased(), !h.isEmpty else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    public func icon(forPage url: String) async -> Data? {
        let host = Self.host(of: url)
        guard !host.isEmpty, host.count < 254 else { return nil }
        // Cache lookup, leader election and waiter registration happen under one lock, so a follower can never
        // register after the leader has already finished (which would leave it waiting forever).
        enum Role { case hit(Data?), leader, follower }
        let role: Role = await withCheckedContinuation { (cont: CheckedContinuation<Role, Never>) in
            lock.lock()
            if let hit = cache[host] {
                lock.unlock()
                cont.resume(returning: .hit(hit))
            } else if inFlight[host] != nil {
                lock.unlock()
                cont.resume(returning: .follower)
            } else {
                inFlight[host] = []
                lock.unlock()
                cont.resume(returning: .leader)
            }
        }
        switch role {
        case .hit(let d): return d
        case .follower:
            return await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
                lock.lock()
                if let hit = cache[host] {
                    lock.unlock()
                    cont.resume(returning: hit)
                } else if inFlight[host] != nil {
                    inFlight[host]!.append(cont)
                    lock.unlock()
                } else {
                    lock.unlock()
                    cont.resume(returning: nil) // the leader finished without caching (shouldn't happen)
                }
            }
        case .leader: break
        }
        // Fetching blocks (DNS, sockets): it runs on GCD threads, never on Swift's cooperative pool.
        let data: Data? = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .utility).async { [self] in
                slots.wait()
                defer { slots.signal() }
                cont.resume(returning: fetchIcon(host: host))
            }
        }
        let waiters: [CheckedContinuation<Data?, Never>] = lock.withLock {
            cache[host] = .some(data)
            order.append(host)
            while order.count > 1000 { cache.removeValue(forKey: order.removeFirst()) }
            return inFlight.removeValue(forKey: host) ?? []
        }
        waiters.forEach { $0.resume(returning: data) }
        return data
    }

    // MARK: - fetching (blocking; runs on a detached task)

    struct NotAllowed: Error {}

    func fetchIcon(host: String) -> Data? {
        let deadline = Date().addingTimeInterval(14)
        var candidates: [String] = []
        var final: String?
        var roots = ["https://\(host)/"]
        if !host.hasPrefix("www.") { roots.append("https://www.\(host)/") }
        roots.append("http://\(host)/")
        for root in roots {
            guard let (status, url, html) = try? getFollow(root, deadline: deadline, limit: 400_000, truncate: true) else { continue }
            final = url
            if status == 200 {
                candidates += Self.iconLinks(html, base: url)
                break
            }
        }
        var origins: [String] = []
        for base in [final, "https://\(host)/"].compactMap({ $0 }) {
            if let c = URLComponents(string: base), let s = c.scheme, let h = c.host {
                let o = "\(s)://\(h)\(c.port.map { ":\($0)" } ?? "")/favicon.ico"
                if !origins.contains(o) { origins.append(o) }
            }
        }
        var tried = Set<String>()
        for url in Array(candidates.prefix(4)) + origins where !tried.contains(url) && Date() < deadline {
            tried.insert(url)
            if let (status, _, data) = try? getFollow(url, deadline: deadline, limit: Self.maxIconBytes),
               status == 200, ImageKind.sniff(data) != nil {
                return data
            }
        }
        // The icon services are fast; they get their own budget so a slow site can't starve them.
        let names = [host] + (host.hasPrefix("www.") ? [] : ["www." + host])
        let services = ["https://icons.duckduckgo.com/ip3/%@.ico", "https://www.google.com/s2/favicons?domain=%@&sz=64"]
        for service in services {
            for name in names {
                let q = name.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789.-")) ?? name
                if let (status, _, data) = try? getFollow(String(format: service, q), deadline: Date().addingTimeInterval(5), limit: Self.maxIconBytes),
                   status == 200, ImageKind.sniff(data) != nil {
                    return data
                }
            }
        }
        return nil
    }

    /// <link rel="icon" | "apple-touch-icon"> candidates, best fit for a 16-32 px slot at 2x first.
    static func iconLinks(_ html: Data, base: String) -> [String] {
        let text = String(decoding: html, as: UTF8.self)
        guard let tagRE = try? NSRegularExpression(pattern: "<link\\b[^>]*>", options: [.caseInsensitive]),
              let attrRE = try? NSRegularExpression(pattern: "([a-zA-Z_:-]+)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s\"'>]+)") else { return [] }
        var links: [(Int, String)] = []
        let ns = text as NSString
        for m in tagRE.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let tag = ns.substring(with: m.range)
            var attrs: [String: String] = [:]
            for a in attrRE.matches(in: tag, range: NSRange(location: 0, length: (tag as NSString).length)) {
                let k = (tag as NSString).substring(with: a.range(at: 1)).lowercased()
                var v = (tag as NSString).substring(with: a.range(at: 2))
                if v.hasPrefix("\"") || v.hasPrefix("'") { v = String(v.dropFirst().dropLast()) }
                if attrs[k] == nil { attrs[k] = v.replacingOccurrences(of: "&amp;", with: "&") }
            }
            let rel = (attrs["rel"] ?? "").lowercased().split(separator: " ").map(String.init)
            guard rel.contains("icon") || rel.contains("apple-touch-icon") || rel.contains("apple-touch-icon-precomposed") else { continue }
            var size = 0
            for sz in (attrs["sizes"] ?? "").lowercased().split(separator: " ") {
                if let x = sz.split(separator: "x").first, let n = Int(x) { size = max(size, n) }
            }
            if rel.contains(where: { $0.hasPrefix("apple-touch-icon") }) && size == 0 { size = 180 }
            let href = (attrs["href"] ?? "").trimmingCharacters(in: .whitespaces)
            guard !href.isEmpty, !href.lowercased().hasPrefix("data:"),
                  let abs = URL(string: href, relativeTo: URL(string: base))?.absoluteString else { continue }
            links.append((size, abs))
        }
        return links.enumerated().sorted { a, b in
            let fa = !(32...192).contains(a.element.0), fb = !(32...192).contains(b.element.0)
            if fa != fb { return !fa }
            if a.element.0 != b.element.0 { return a.element.0 > b.element.0 }
            return a.offset < b.offset
        }.map { $0.element.1 }
    }

    /// GET with up to 4 redirects; every hop must again be http(s) on a public address.
    func getFollow(_ start: String, deadline: Date, limit: Int, truncate: Bool = false) throws -> (Int, String, Data) {
        var url = start
        for _ in 0..<5 {
            let (status, location, body) = try pinnedGet(url, deadline: deadline, limit: limit, truncate: truncate)
            if [301, 302, 303, 307, 308].contains(status), let location,
               let next = URL(string: location, relativeTo: URL(string: url))?.absoluteString {
                url = next
                continue
            }
            return (status, url, body)
        }
        return (0, url, Data())
    }

    /// One GET to a public address only, no redirects.
    func pinnedGet(_ urlString: String, deadline: Date, limit: Int, truncate: Bool) throws -> (Int, String?, Data) {
        guard let c = URLComponents(string: urlString), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              c.user == nil, c.password == nil, let host = c.host?.lowercased(), !host.isEmpty else { throw NotAllowed() }
        let port = c.port ?? (scheme == "https" ? 443 : 80)
        guard port == 80 || port == 443 else { throw NotAllowed() }
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw NotAllowed() }
        let ip = try Self.publicIP(host)
        var path = c.percentEncodedPath.isEmpty ? "/" : c.percentEncodedPath
        if let q = c.percentEncodedQuery { path += "?" + q }
        let hostHeader = c.port.map { "\(host):\($0)" } ?? host
        let request = "GET \(path) HTTP/1.0\r\nHost: \(hostHeader)\r\nUser-Agent: Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)\r\n"
            + "Accept: text/html,image/*,*/*;q=0.8\r\nAccept-Encoding: identity\r\nConnection: close\r\n\r\n"
        let raw = try Self.exchange(ip: ip, port: UInt16(port), tlsName: scheme == "https" ? host : nil,
                                    request: Data(request.utf8), timeout: min(4, remaining), limit: limit + 64 * 1024)
        return try Self.parseResponse(raw, limit: limit, truncate: truncate)
    }

    /// Resolves `host` and returns one address, only if every address it resolves to is public.
    static func publicIP(_ host: String) throws -> String {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM, ai_protocol: 0,
                             ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0, let first = res else { throw NotAllowed() }
        defer { freeaddrinfo(res) }
        var ips: [String] = []
        var p: UnsafeMutablePointer<addrinfo>? = first
        while let ai = p {
            var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(ai.pointee.ai_addr, ai.pointee.ai_addrlen, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0 {
                ips.append(String(cString: buf))
            }
            p = ai.pointee.ai_next
        }
        ips = Array(Set(ips)).sorted()
        guard !ips.isEmpty, ips.allSatisfy(PublicAddress.isPublic) else { throw NotAllowed() }
        return ips[0]
    }

    /// Connects to `ip` (never re-resolving the name), sends `request`, reads until close or `limit`.
    static func exchange(ip: String, port: UInt16, tlsName: String?, request: Data, timeout: TimeInterval, limit: Int) throws -> Data {
        let params: NWParameters
        if let tlsName {
            let tls = NWProtocolTLS.Options()
            sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, tlsName)
            params = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        } else {
            params = .tcp
        }
        params.preferNoProxies = true
        let conn = NWConnection(host: NWEndpoint.Host(ip), port: NWEndpoint.Port(rawValue: port)!, using: params)
        let q = DispatchQueue(label: "dev.tabtunnel.favicon")
        let done = DispatchSemaphore(value: 0)
        var result = Data()
        var failed = false
        var finished = false
        func finish(_ fail: Bool) {
            q.async {
                guard !finished else { return }
                finished = true
                failed = fail
                conn.cancel()
                done.signal()
            }
        }
        func read() {
            conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                if let data { result.append(data) }
                if result.count > limit { return finish(false) }
                if complete { return finish(false) }
                if error != nil { return finish(result.isEmpty) }
                read()
            }
        }
        conn.stateUpdateHandler = { st in
            switch st {
            case .ready:
                conn.send(content: request, completion: .contentProcessed { e in e == nil ? read() : finish(true) })
            case .failed, .waiting: finish(true)
            default: break
            }
        }
        conn.start(queue: q)
        if done.wait(timeout: .now() + timeout) == .timedOut { finish(true); _ = done.wait(timeout: .now() + 1) }
        let (out, bad) = q.sync { (result, failed) }
        if bad { throw NotAllowed() }
        return out
    }

    static func parseResponse(_ raw: Data, limit: Int, truncate: Bool) throws -> (Int, String?, Data) {
        guard let end = raw.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: raw[raw.startIndex..<end.lowerBound], encoding: .isoLatin1) else { throw NotAllowed() }
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines[0].split(separator: " ")
        guard parts.count >= 2, let status = Int(parts[1]) else { throw NotAllowed() }
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        var body = status == 200 ? Data(raw[end.upperBound...]) : Data()
        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true { body = dechunk(body) }
        if body.count > limit {
            guard truncate else { throw NotAllowed() }
            body = body.prefix(limit) // HTML: the <link rel=icon> tags are near the top
        }
        return (status, headers["location"], body)
    }

    static func dechunk(_ data: Data) -> Data {
        var out = Data()
        var i = data.startIndex
        while i < data.endIndex {
            guard let lineEnd = data[i...].range(of: Data("\r\n".utf8)) else { break }
            let sizeText = String(decoding: data[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            // Sizes are checked against what's left before any addition, so a huge size can't overflow.
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16), size > 0,
                  size <= data.endIndex - lineEnd.upperBound else { break }
            let start = lineEnd.upperBound
            let stop = start + size
            out.append(data[start..<stop])
            i = data.endIndex - stop >= 2 ? stop + 2 : data.endIndex
        }
        return out
    }
}
