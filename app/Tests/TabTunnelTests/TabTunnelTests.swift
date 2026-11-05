import Foundation
import XCTest
@testable import TabTunnelModel
@testable import TabTunnelNet
@testable import TabTunnelSafari

/// Repo-relative fixture folders (test/ and test/demo hold sample Safari databases).
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent()

func fixtureCopy(_ name: String) throws -> String {
    let src = repoRoot.appendingPathComponent(name).path
    let dst = NSTemporaryDirectory() + "tt-test-" + UUID().uuidString
    try FileManager.default.createDirectory(atPath: dst, withIntermediateDirectories: true)
    for f in try FileManager.default.contentsOfDirectory(atPath: src) where f.hasSuffix(".db") || f.hasSuffix("-wal") || f.hasSuffix("-shm") {
        try FileManager.default.copyItem(atPath: src + "/" + f, toPath: dst + "/" + f)
    }
    return dst
}

final class SafariTests: XCTestCase {
    func testReadsDemoFixture() throws {
        let engine = SafariEngine(paths: .fixture(try fixtureCopy("test/demo")))
        XCTAssertTrue(engine.refresh(force: true))
        let snap = try XCTUnwrap(engine.state.snapshot)
        XCTAssertNil(engine.state.status.problem)
        XCTAssertEqual(snap.devices.count, 2)
        XCTAssertEqual(snap.deviceTabCount, 7)
        XCTAssertEqual(snap.tabGroups.count, 12)
        XCTAssertEqual(snap.devices[0].kind, .phone) // newest device first
        XCTAssertTrue(snap.tabGroups[0].tabs.contains { $0.pinned == true })
    }

    func testUnchangedFilesDontRereadOrChangeRevision() throws {
        let engine = SafariEngine(paths: .fixture(try fixtureCopy("test/demo")))
        engine.refresh(force: true)
        let rev = engine.state.revision
        let updated = engine.state.snapshot?.updatedAt
        XCTAssertFalse(engine.refresh(), "nothing changed on disk, so nothing should be reported")
        XCTAssertFalse(engine.refresh(force: true), "a forced re-read of the same content is not a change")
        XCTAssertEqual(engine.state.revision, rev)
        XCTAssertEqual(engine.state.snapshot?.updatedAt, updated, "timestamps stay put so the ETag stays put")
    }

    func testTabGroupChangeIsNoticed() throws {
        let dir = try fixtureCopy("test/demo")
        let engine = SafariEngine(paths: .fixture(dir))
        engine.refresh(force: true)
        let before = try XCTUnwrap(engine.state.snapshot)
        let db = try openWritable(dir + "/SafariTabs.db")
        try exec(db, "UPDATE bookmarks SET title='Renamed group' WHERE id=(SELECT id FROM bookmarks WHERE type=1 AND subtype=0 AND parent IS NOT NULL ORDER BY order_index LIMIT 1)")
        sqlite3_close_v2(db)
        XCTAssertTrue(engine.refresh())
        XCTAssertNotEqual(engine.state.revision, before.contentHash)
        XCTAssertTrue(engine.state.snapshot!.tabGroups.contains { $0.title == "Renamed group" })
    }

    func testMissingDatabaseIsReported() {
        let engine = SafariEngine(paths: .fixture(NSTemporaryDirectory() + "tt-none-" + UUID().uuidString))
        engine.refresh(force: true)
        XCTAssertEqual(engine.state.status.problem, .noDatabase)
        XCTAssertNil(engine.state.snapshot)
    }

    func testUnsupportedSchemaIsReportedAndLastGoodKept() throws {
        let dir = try fixtureCopy("test/demo")
        let engine = SafariEngine(paths: .fixture(dir))
        engine.refresh(force: true)
        let db = try openWritable(dir + "/CloudTabs.db")
        try exec(db, "ALTER TABLE cloud_tabs RENAME TO cloud_tabs_v2")
        sqlite3_close_v2(db)
        XCTAssertTrue(engine.refresh())
        XCTAssertEqual(engine.state.status.problem, .unsupportedSchema)
        XCTAssertNotNil(engine.state.snapshot, "the last good tabs stay available")
    }

    func testFaviconOnlyForKnownPages() throws {
        let engine = SafariEngine(paths: .fixture(try fixtureCopy("test/demo")))
        engine.refresh(force: true)
        XCTAssertNil(engine.favicon(forPage: "https://not-in-snapshot.example/"))
    }

    func testPositionKey() {
        XCTAssertLessThan(SafariData.positionKey(.number(1)), SafariData.positionKey(.number(2)))
        XCTAssertLessThan(SafariData.positionKey(.number(99)), SafariData.positionKey(.null)) // missing sorts last
        let json = #"{"sortValues":[{"changeID":1,"sortValue":10},{"changeID":3,"sortValue":5}]}"#
        XCTAssertEqual(SafariData.positionKey(.bytes(Data(json.utf8))), SafariData.positionKey(.number(5)), "latest changeID wins")
        // zlib-compressed JSON, as on macOS 26 (python: zlib.compress(json.dumps(...)))
        let compressed = Data(base64Encoded: "eJyrVirOLyoJS8wpTS1WslKIrlZKzkjMS0/1dAHyDHQUENJAvqG5paWBAUg0JbUsMznVMyU1ryQzLTO1CCipVKFUG1sLABPOGXI=")!
        XCTAssertEqual(SafariData.positionKey(.bytes(compressed)), SafariData.positionKey(.number(1_799_000)))
        XCTAssertEqual(SafariData.positionKey(.bytes(Data("garbage".utf8))).missing, 1)
    }

    func testDeviceKind() {
        XCTAssertEqual(SafariData.deviceKind("com.apple.iphone-15-pro", nil), .phone)
        XCTAssertEqual(SafariData.deviceKind(nil, "Alex's iPad Pro"), .tablet)
        XCTAssertEqual(SafariData.deviceKind(nil, "MacBook Air"), .laptop)
        XCTAssertEqual(SafariData.deviceKind(nil, "Studio Mac"), .desktop)
        XCTAssertEqual(SafariData.deviceKind(nil, "Pixel"), .unknown)
    }

    func testAppleTime() {
        XCTAssertEqual(SafariData.appleTime(0), "2001-01-01T00:00:00.000Z")
        XCTAssertNil(SafariData.appleTime(2e11))
        XCTAssertNil(SafariData.appleTime(nil))
    }

    func testWatcherFiresOnWrite() throws {
        let dir = try fixtureCopy("test/demo")
        let q = DispatchQueue(label: "test.watch")
        let fired = expectation(description: "change noticed")
        fired.assertForOverFulfill = false
        let w = ChangeWatcher(directories: [dir], fileNames: ["SafariTabs.db"], queue: q, debounce: 0.1, maxDelay: 0.5,
                              safetyInterval: 3600) { fired.fulfill() }
        w.start()
        XCTAssertTrue(w.isWatching)
        Thread.sleep(forTimeInterval: 0.3)
        let db = try openWritable(dir + "/SafariTabs.db")
        try exec(db, "UPDATE bookmarks SET title=title||'!' WHERE id=1")
        sqlite3_close_v2(db)
        wait(for: [fired], timeout: 5)
        withExtendedLifetime(w) {}
    }
}

import SQLite3

func openWritable(_ path: String) throws -> OpaquePointer {
    var db: OpaquePointer?
    guard sqlite3_open(path, &db) == SQLITE_OK, let db else { throw SQLiteError(description: "open") }
    return db
}

func exec(_ db: OpaquePointer, _ sql: String) throws {
    guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
        throw SQLiteError(description: String(cString: sqlite3_errmsg(db)))
    }
}

final class HTTPParserTests: XCTestCase {
    func parse(_ s: String) -> (HTTPRequest.ParseResult, HTTPRequest?) { HTTPRequest.parse(Data(s.utf8)) }

    func testParsesGet() {
        let (r, req) = parse("GET /favicon?url=https%3A%2F%2Fa.example%2F&x=1 HTTP/1.1\r\nHost: h:8787\r\nAuthorization: Bearer t\r\n\r\n")
        guard case .done = r, let req else { return XCTFail() }
        XCTAssertEqual(req.path, "/favicon")
        XCTAssertEqual(req.query("url"), "https://a.example/")
        XCTAssertEqual(req.headers["host"], "h:8787")
    }

    func testNeedsMoreThenRejectsHuge() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nHost: x").0, .needMore)
        let huge = "GET / HTTP/1.1\r\nX: " + String(repeating: "a", count: 17000)
        XCTAssertEqual(parse(huge).0, .bad)
    }

    func testRejectsAmbiguousFraming() {
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n").0, .bad)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\nContent-Length: 5\r\n\r\n").0, .bad)
        XCTAssertEqual(parse("GET / HTTP/1.1\r\n folded\r\n\r\n").0, .bad)
        XCTAssertEqual(parse("GET  / HTTP/1.1\r\n\r\n").0, .bad)
        XCTAssertEqual(parse("GET http://x/ HTTP/1.1\r\n\r\n").0, .bad)
        XCTAssertEqual(parse("GET / HTTP/2\r\n\r\n").0, .bad)
    }

    func testPathTrailingSlash() {
        XCTAssertEqual(HTTPRequest(method: "GET", target: "/tabs/", headers: [:]).path, "/tabs")
        XCTAssertEqual(HTTPRequest(method: "GET", target: "/", headers: [:]).path, "/")
    }
}

final class FakeBackend: RelayBackend, @unchecked Sendable {
    var snapshot: Snapshot?
    var error: String?
    init(_ s: Snapshot?, _ e: String? = nil) { snapshot = s; error = e }
    func current() -> (snapshot: Snapshot?, error: String?) { (snapshot, error) }
    func favicon(pageURL: String) async -> (Data, String)? { nil }
}

final class RouterTests: XCTestCase {
    let token = String(repeating: "t", count: 64)
    let snap = Snapshot(updatedAt: "2026-01-01T00:00:00.000Z", sourceModifiedAt: "2026-01-01T00:00:00.000Z",
                        devices: [Device(name: "iPhone", kind: .phone, lastModified: nil, tabs: [Tab(title: "A & B <x>", url: "https://a.example/")])],
                        tabGroups: [TabGroup(id: "G 1/ü", title: "Group", tabs: [Tab(id: "u1", title: "T", url: "https://b.example/")])])

    func router(_ backend: RelayBackend) -> Router {
        Router(config: .init(token: token, feedSecret: "secret", allowedHosts: Router.allowedHosts(bind: "100.64.0.5", port: 8787, names: ["mac.tail.ts.net"])),
               backend: backend)
    }

    func get(_ r: Router, _ target: String, host: String = "100.64.0.5:8787", auth: Bool = true, extra: [String: String] = [:]) async -> HTTPResponse {
        var h = ["host": host]
        if auth { h["authorization"] = "Bearer " + token }
        h.merge(extra) { $1 }
        return await r.handle(HTTPRequest(method: "GET", target: target, headers: h)).0
    }

    func testHostAllowList() async {
        let r = router(FakeBackend(snap))
        let ok = await get(r, "/tabs", host: "mac.tail.ts.net:8787")
        XCTAssertEqual(ok.status, 200)
        let trailingDot = await get(r, "/tabs", host: "mac.tail.ts.net.")
        XCTAssertEqual(trailingDot.status, 200)
        let rebinding = await get(r, "/tabs", host: "evil.example:8787")
        XCTAssertEqual(rebinding.status, 421)
        let missing = await r.handle(HTTPRequest(method: "GET", target: "/health", headers: [:])).0
        XCTAssertEqual(missing.status, 421)
    }

    func testAuth() async {
        let r = router(FakeBackend(snap))
        let none = await get(r, "/tabs", auth: false)
        XCTAssertEqual(none.status, 401)
        let wrong = await get(r, "/tabs", auth: false, extra: ["authorization": "Bearer nope"])
        XCTAssertEqual(wrong.status, 401)
        let health = await get(r, "/health", auth: false)
        XCTAssertEqual(String(decoding: health.body, as: UTF8.self), #"{"ok":true}"#)
        XCTAssertNil(health.header("Access-Control-Allow-Origin"), "no CORS: web pages can't read responses")
    }

    func testETagAnd304() async {
        let r = router(FakeBackend(snap))
        let first = await get(r, "/tabs")
        let etag = try! XCTUnwrap(first.header("ETag"))
        let again = await get(r, "/tabs", extra: ["if-none-match": etag])
        XCTAssertEqual(again.status, 304)
        XCTAssertTrue(again.body.isEmpty)
        let weak = await get(r, "/tabs", extra: ["if-none-match": "W/" + etag])
        XCTAssertEqual(weak.status, 304)
        let unauth = await get(r, "/tabs", auth: false, extra: ["if-none-match": etag])
        XCTAssertEqual(unauth.status, 401, "a 304 never confirms anything without the token")
    }

    func testStaleAndUnavailable() async {
        let stale = await get(router(FakeBackend(snap, "reader down")), "/tabs")
        let obj = try! JSONSerialization.jsonObject(with: stale.body) as! [String: Any]
        XCTAssertEqual(obj["stale"] as? Bool, true)
        XCTAssertEqual(obj["error"] as? String, "reader down")
        XCTAssertTrue(stale.header("ETag")!.contains("-stale"))
        let none = await get(router(FakeBackend(nil, "no access")), "/tabs")
        XCTAssertEqual(none.status, 503)
        let health = await get(router(FakeBackend(snap, "x")), "/health", auth: false)
        XCTAssertEqual(String(decoding: health.body, as: UTF8.self), #"{"ok":false}"#)
    }

    func testFeeds() async {
        let r = router(FakeBackend(snap))
        let link = await get(r, "/feeds/G%201%2F%C3%BC/link")
        let url = (try! JSONSerialization.jsonObject(with: link.body) as! [String: String])["url"]!
        XCTAssertTrue(url.hasPrefix("http://100.64.0.5:8787/feeds/G%201%2F%C3%BC.rss?key="), url)
        let path = String(url.dropFirst("http://100.64.0.5:8787".count))
        let rss = await get(r, path, auth: false)
        XCTAssertEqual(rss.status, 200)
        XCTAssertTrue(String(decoding: rss.body, as: UTF8.self).contains("<guid isPermaLink=\"false\">u1|https://b.example/</guid>"))
        let wrongKey = await get(r, String(path.dropLast(4)) + "0000", auth: false)
        XCTAssertEqual(wrongKey.status, 401)
        let otherGroup = await get(r, "/feeds/other.rss?key=" + Router.feedKey(secret: "secret", group: "G 1/ü"), auth: false)
        XCTAssertEqual(otherGroup.status, 401, "a feed key opens only its own group")
        let etag = rss.header("ETag")!
        let cached = await get(r, path, auth: false, extra: ["if-none-match": etag])
        XCTAssertEqual(cached.status, 304)
    }

    func testFeedKeyMatchesPython() {
        // python3 -c 'import hmac,hashlib;print(hmac.new(b"secret",b"feed:G1",hashlib.sha256).hexdigest()[:32])'
        XCTAssertEqual(Router.feedKey(secret: "secret", group: "G1"), "2a4fc3851f15938b2e4c53cc79199762")
    }

    func testRSSEscapesAndStripsControlCharacters() {
        let g = TabGroup(id: "g", title: "A & <B>", tabs: [Tab(id: nil, title: "bad\u{01}title", url: "https://x.example/?a=1&b=2")])
        let xml = String(decoding: RSS.feed(for: g, baseURL: "http://h", date: Date(timeIntervalSince1970: 0)), as: UTF8.self)
        XCTAssertTrue(xml.contains("<title>A &amp; &lt;B&gt;</title>"))
        XCTAssertTrue(xml.contains("<title>badtitle</title>"))
        XCTAssertTrue(xml.contains("?a=1&amp;b=2"))
        XCTAssertTrue(xml.contains("Thu, 01 Jan 1970 00:00:00 GMT"))
    }

    func testMethodAndUnknownPath() async {
        let r = router(FakeBackend(snap))
        let post = await r.handle(HTTPRequest(method: "POST", target: "/tabs", headers: ["host": "100.64.0.5"])).0
        XCTAssertEqual(post.status, 405)
        let nope = await get(r, "/schema")
        XCTAssertEqual(nope.status, 404, "no debug endpoints in the app")
    }
}

final class PublicAddressTests: XCTestCase {
    func testBlocksPrivateRanges() {
        for ip in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.255", "192.168.1.1", "100.64.0.1", "100.127.255.255",
                   "169.254.169.254", "0.0.0.0", "224.0.0.1", "255.255.255.255", "192.0.2.1", "198.18.0.1",
                   "::1", "::", "fe80::1", "fc00::1", "fd12::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:10.0.0.1",
                   "2001:db8::1", "2002:7f00:1::1", "64:ff9b::7f00:1", "not an ip"] {
            XCTAssertFalse(PublicAddress.isPublic(ip), ip)
        }
    }

    func testAllowsPublic() {
        for ip in ["1.1.1.1", "8.8.8.8", "172.32.0.1", "100.128.0.1", "2606:4700:4700::1111", "2a00:1450:4001::200e"] {
            XCTAssertTrue(PublicAddress.isPublic(ip), ip)
        }
    }

    func testFetcherRefusesPrivateAndOddURLs() {
        let f = FaviconFetcher()
        let deadline = Date().addingTimeInterval(5)
        for url in ["http://127.0.0.1/", "http://localhost/", "file:///etc/passwd", "http://user:pw@example.com/",
                    "http://example.com:8080/", "ftp://example.com/", "http://[::1]/", "http://169.254.169.254/latest/meta-data"] {
            XCTAssertThrowsError(try f.pinnedGet(url, deadline: deadline, limit: 1000, truncate: false), url)
        }
    }

    func testIconLinkParsing() {
        let html = Data(#"<link rel="icon" href="/a.png" sizes="16x16"><LINK REL='apple-touch-icon' HREF='b.png'><link rel=icon href="data:x"><link rel="shortcut icon" href="/c.ico" sizes="48x48">"#.utf8)
        let links = FaviconFetcher.iconLinks(html, base: "https://x.example/page/")
        XCTAssertEqual(links, ["https://x.example/page/b.png", "https://x.example/c.ico", "https://x.example/a.png"])
    }

    func testDechunk() {
        XCTAssertEqual(FaviconFetcher.dechunk(Data("4\r\nWiki\r\n5\r\npedia\r\n0\r\n\r\n".utf8)), Data("Wikipedia".utf8))
    }
}

final class SnapshotTests: XCTestCase {
    func testContentHashIgnoresReadTimes() {
        let a = Snapshot(updatedAt: "2026-01-01T00:00:00Z", sourceModifiedAt: "x", devices: [], tabGroups: [])
        let b = Snapshot(updatedAt: "2027-01-01T00:00:00Z", sourceModifiedAt: "y", devices: [], tabGroups: [])
        XCTAssertEqual(a.contentHash, b.contentHash)
    }

    func testContentHashRoundsLastActiveToMinute() {
        func s(_ t: String) -> Snapshot {
            Snapshot(updatedAt: "", sourceModifiedAt: nil, devices: [Device(name: "d", kind: .phone, lastModified: t, tabs: [])], tabGroups: [])
        }
        XCTAssertEqual(s("2026-01-01T10:00:05.000Z").contentHash, s("2026-01-01T10:00:55.000Z").contentHash)
        XCTAssertNotEqual(s("2026-01-01T10:00:05.000Z").contentHash, s("2026-01-01T10:01:05.000Z").contentHash)
    }

    func testReaderStateRejectsHugeMessages() {
        XCTAssertNil(ReaderState.decode(Data(count: TabTunnelIDs.maxMessageBytes + 1)))
    }

    func testImageKind() {
        XCTAssertEqual(ImageKind.sniff(Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), "image/png")
        XCTAssertEqual(ImageKind.sniff(Data("  <svg xmlns=".utf8)), "image/svg+xml")
        XCTAssertNil(ImageKind.sniff(Data("<html>".utf8)))
        XCTAssertNil(ImageKind.forBrowsers(Data("<html>".utf8)))
    }
}

final class SecurityRegressionTests: XCTestCase {
    /// NWListener.newConnectionLimit counts down forever; the server once stopped answering after 32 connections.
    func testServerKeepsAnsweringAfterManyConnections() throws {
        let snap = Snapshot(updatedAt: "2026-01-01T00:00:00.000Z", sourceModifiedAt: nil, devices: [], tabGroups: [])
        let port = UInt16.random(in: 20000...40000)
        let router = Router(config: .init(token: String(repeating: "t", count: 64), feedSecret: "s",
                                          allowedHosts: Router.allowedHosts(bind: "127.0.0.1", port: Int(port), names: [])),
                            backend: FakeBackend(snap))
        let ready = expectation(description: "ready")
        let server = HTTPServer(router: router, onEvent: { _ in }, onState: { if $0 == .ready { ready.fulfill() } })
        server.start(host: "127.0.0.1", port: port)
        wait(for: [ready], timeout: 5)
        for i in 0..<45 {
            var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/health")!)
            req.timeoutInterval = 3
            let done = expectation(description: "request \(i)")
            var status = 0
            URLSession.shared.dataTask(with: req) { _, r, _ in
                status = (r as? HTTPURLResponse)?.statusCode ?? 0
                done.fulfill()
            }.resume()
            wait(for: [done], timeout: 5)
            XCTAssertEqual(status, 200, "request \(i)")
        }
        server.stop()
    }

    func testDechunkRejectsOverflowingSize() {
        XCTAssertEqual(FaviconFetcher.dechunk(Data("7fffffffffffffff\r\nx\r\n".utf8)), Data())
        XCTAssertEqual(FaviconFetcher.dechunk(Data("ffffffffffffffffff\r\nx\r\n".utf8)), Data())
        XCTAssertEqual(FaviconFetcher.dechunk(Data("5\r\nab".utf8)), Data()) // truncated chunk
    }

    func testStaleETagDependsOnError() async {
        let snap = Snapshot(updatedAt: "x", sourceModifiedAt: nil, devices: [], tabGroups: [])
        func etag(_ err: String) async -> String? {
            let r = Router(config: .init(token: "tok", feedSecret: "", allowedHosts: ["h"]), backend: FakeBackend(snap, err))
            return await r.handle(HTTPRequest(method: "GET", target: "/tabs", headers: ["host": "h", "authorization": "Bearer tok"])).0.header("ETag")
        }
        let a = await etag("reader down"), b = await etag("no access")
        XCTAssertNotEqual(a, b)
    }

    func testDeadlineGivesUp() async {
        let start = Date()
        let r: Int? = await Router.withDeadline(0.2) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return 1
        }
        XCTAssertNil(r)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testReadsLiveDatabaseWithoutCopying() throws {
        let dir = try fixtureCopy("test/demo")
        _ = try SafariData.loadPrivate(dir + "/CloudTabs.db")
        XCTAssertEqual(SafariData.lastMethod, .direct, "no temporary copy of Safari's data")
        let leftovers = (try FileManager.default.contentsOfDirectory(atPath: SafariData.realTemp)).filter { $0.hasPrefix("tabtunnel-") }
        XCTAssertTrue(leftovers.isEmpty)
    }

    func testReaderUsesRealHome() {
        XCTAssertEqual(SafariData.realHome, NSHomeDirectory())
    }
}

final class TailscaleListenTests: XCTestCase {
    /// NWListener never received connections on the utun address; the server must answer there.
    func testServerAnswersOnTailscaleAddress() throws {
        guard let ip = Tailscale.ipv4() else { throw XCTSkip("Tailscale isn't connected on this Mac") }
        let port = UInt16.random(in: 40001...50000)
        let router = Router(config: .init(token: "t", feedSecret: "", allowedHosts: Router.allowedHosts(bind: ip, port: Int(port), names: [])),
                            backend: FakeBackend(nil))
        let ready = expectation(description: "ready")
        let server = HTTPServer(router: router, onEvent: { _ in }, onState: { if $0 == .ready { ready.fulfill() } })
        server.start(host: ip, port: port)
        wait(for: [ready], timeout: 5)
        var req = URLRequest(url: URL(string: "http://\(ip):\(port)/health")!)
        req.timeoutInterval = 4
        let done = expectation(description: "answered")
        var status = 0
        URLSession.shared.dataTask(with: req) { _, r, _ in status = (r as? HTTPURLResponse)?.statusCode ?? 0; done.fulfill() }.resume()
        wait(for: [done], timeout: 6)
        XCTAssertEqual(status, 200)
        server.stop()
    }
}
