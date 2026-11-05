import Foundation

/// A small HTTP/1.0 server on one address: at most 32 connections at once, one request per connection,
/// 10 s per connection, 16 KB of headers, GET only.
///
/// It uses a plain BSD socket with GCD, not Network.framework: an `NWListener` bound to the Tailscale (utun)
/// address never receives connections, while a BSD socket on the same address does.
public final class HTTPServer: @unchecked Sendable {
    public struct Event: Sendable {
        public var kind: RouteKind
        public var status: Int
        public var bytes: Int
        public var remoteIP: String
        /// The extension's self-description ("chromium/2.1.0"), from X-TabTunnel-Client, if sent.
        public var client: String?
        public var userAgent: String?
    }

    public enum State: Equatable, Sendable {
        case stopped
        case starting
        case ready
        /// The port is taken by another program.
        case portInUse
        /// The address isn't on this Mac (Tailscale disconnected or its address changed).
        case addressUnavailable
        case failed(String)
    }

    private let router: Router
    private let queue = DispatchQueue(label: "dev.tabtunnel.http")
    private let workers = DispatchQueue(label: "dev.tabtunnel.http.conn", attributes: .concurrent)
    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?
    /// Open client sockets (touched only on `queue`). Shut down when sharing stops or restarts.
    private var clients: Set<Int32> = []
    /// Bumped on every start/stop, so a reply computed for an old server is never sent.
    private var generation = 0
    private let maxConnections = 32
    private let connectionTimeout: Double = 10
    private let onEvent: @Sendable (Event) -> Void
    private let onState: @Sendable (State) -> Void
    public private(set) var host: String?
    public private(set) var port: UInt16 = 0

    public init(router: Router, onEvent: @escaping @Sendable (Event) -> Void, onState: @escaping @Sendable (State) -> Void) {
        self.router = router
        self.onEvent = onEvent
        self.onState = onState
    }

    public func start(host: String, port: UInt16) {
        queue.async { self._start(host: host, port: port) }
    }

    public func stop() {
        queue.async {
            self.closeListener()
            self.host = nil
            self.onState(.stopped)
        }
    }

    private func closeListener() {
        generation += 1
        source?.cancel() // the cancel handler closes the listening socket
        source = nil
        listenFD = -1
        for fd in clients { shutdown(fd, SHUT_RDWR) } // their workers notice and close them
        clients.removeAll()
    }

    private func _start(host: String, port: UInt16) {
        closeListener()
        self.host = host
        self.port = port
        onState(.starting)
        let v6 = host.contains(":")
        let fd = socket(v6 ? AF_INET6 : AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { return onState(.failed("socket: \(errno)")) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        let rc: Int32
        if v6 {
            var a = sockaddr_in6()
            a.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            a.sin6_family = sa_family_t(AF_INET6)
            a.sin6_port = port.bigEndian
            guard inet_pton(AF_INET6, host, &a.sin6_addr) == 1 else { close(fd); return onState(.failed("bad address")) }
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        } else {
            var a = sockaddr_in()
            a.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            a.sin_family = sa_family_t(AF_INET)
            a.sin_port = port.bigEndian
            guard inet_pton(AF_INET, host, &a.sin_addr) == 1 else { close(fd); return onState(.failed("bad address")) }
            rc = withUnsafePointer(to: &a) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        }
        if rc != 0 {
            let e = errno
            close(fd)
            if e == EADDRINUSE { return onState(.portInUse) }
            if e == EADDRNOTAVAIL { return onState(.addressUnavailable) }
            return onState(.failed("bind: \(String(cString: strerror(e)))"))
        }
        guard listen(fd, 16) == 0 else {
            close(fd)
            return onState(.failed("listen: \(errno)"))
        }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        src.setEventHandler { [weak self] in self?.acceptAll(fd) }
        src.setCancelHandler { close(fd) }
        listenFD = fd
        source = src
        src.resume()
        onState(.ready)
    }

    private func acceptAll(_ lfd: Int32) {
        while true {
            var storage = sockaddr_storage()
            var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let c = withUnsafeMutablePointer(to: &storage) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(lfd, $0, &len) }
            }
            guard c >= 0 else { return } // EAGAIN: nothing more to accept
            guard clients.count < maxConnections else { close(c); continue }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            _ = fcntl(c, F_SETFL, fcntl(c, F_GETFL) & ~O_NONBLOCK)
            var tv = timeval(tv_sec: 2, tv_usec: 0) // per read/write; the whole connection gets `connectionTimeout`
            setsockopt(c, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            setsockopt(c, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            clients.insert(c)
            let ip = Self.ipString(&storage)
            let gen = generation
            workers.async { [weak self] in self?.serve(c, ip: ip, generation: gen) }
        }
    }

    private func finish(_ fd: Int32) {
        queue.async {
            self.clients.remove(fd)
            close(fd)
        }
    }

    /// Reads one request (blocking, on a worker thread), routes it, writes the response, closes.
    private func serve(_ fd: Int32, ip: String, generation gen: Int) {
        let deadline = Date().addingTimeInterval(connectionTimeout)
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        var request: HTTPRequest?
        while Date() < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
            if n <= 0 { return finish(fd) }
            buffer.append(contentsOf: chunk[0..<n])
            let (result, req) = HTTPRequest.parse(buffer)
            switch result {
            case .needMore: continue
            case .bad:
                let r = HTTPResponse.json(buffer.count > HTTPRequest.maxHeaderBytes ? 431 : 400, ["error": "bad request"])
                writeAll(fd, r.serialized(), deadline: deadline)
                return finish(fd)
            case .done:
                request = req
            }
            break
        }
        guard let request else { return finish(fd) } // too slow: dropped
        Task {
            let (response, kind) = await self.router.handle(request)
            let out = response.serialized()
            self.workers.async {
                let current = self.queue.sync { gen == self.generation && self.clients.contains(fd) }
                guard current else { return self.finish(fd) } // sharing stopped or restarted meanwhile
                self.writeAll(fd, out, deadline: deadline.addingTimeInterval(2))
                self.finish(fd)
                self.onEvent(Event(kind: kind, status: response.status, bytes: out.count, remoteIP: ip,
                                   client: request.headers["x-tabtunnel-client"].map { String($0.prefix(40)) },
                                   userAgent: request.headers["user-agent"].map { String($0.prefix(200)) }))
            }
        }
    }

    private func writeAll(_ fd: Int32, _ data: Data, deadline: Date) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count && Date() < deadline {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 && (errno == EAGAIN || errno == EINTR) { continue }
                if n <= 0 { return }
                off += n
            }
        }
    }

    private static func ipString(_ s: inout sockaddr_storage) -> String {
        var buf = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let len = socklen_t(s.ss_len)
        let ok = withUnsafePointer(to: &s) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getnameinfo($0, len, &buf, socklen_t(buf.count), nil, 0, NI_NUMERICHOST) == 0
            }
        }
        return ok ? String(cString: buf) : "?"
    }
}
