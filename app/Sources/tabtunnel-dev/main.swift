// Development tool, never bundled with the app.
//
//   tabtunnel-dev dump  <fixture dir>                     print what /tabs would serve (compat tests)
//   tabtunnel-dev serve <fixture dir> <port> <token> [feed secret]
//                                                         serve fixtures on 127.0.0.1 with the app's server,
//                                                         re-reading on file changes (tools/e2e_groups.mjs)
import Foundation
import TabTunnelModel
import TabTunnelNet
import TabTunnelSafari

let args = CommandLine.arguments
guard args.count >= 3 else {
    FileHandle.standardError.write(Data("usage: tabtunnel-dev dump <dir> | serve <dir> <port> <token> [feed secret]\n".utf8))
    exit(2)
}
let engine = SafariEngine(paths: .fixture(args[2]))
let queue = DispatchQueue(label: "dev.engine")

if args[1] == "dump" {
    engine.refresh(force: true)
    if let snap = engine.state.snapshot {
        let e = JSONEncoder.wire
        e.outputFormatting.insert(.prettyPrinted)
        e.outputFormatting.insert(.sortedKeys)
        print(String(decoding: try! e.encode(snap), as: UTF8.self))
        exit(0)
    }
    FileHandle.standardError.write(Data("error: \(engine.state.status.problem?.rawValue ?? "?") \(engine.state.status.detail ?? "")\n".utf8))
    exit(1)
}

guard args[1] == "serve", args.count >= 5, let port = UInt16(args[3]) else { exit(2) }
setlinebuf(stdout)

final class DevBackend: RelayBackend, @unchecked Sendable {
    let fetcher = FaviconFetcher()
    func current() -> (snapshot: Snapshot?, error: String?) {
        queue.sync { (engine.state.snapshot, engine.state.status.problem?.message) }
    }
    func favicon(pageURL: String) async -> (Data, String)? {
        if let d = queue.sync(execute: { engine.favicon(forPage: pageURL) }), let r = ImageKind.forBrowsers(d) { return r }
        if ProcessInfo.processInfo.environment["TABTUNNEL_FETCH_FAVICONS"] == "1", let d = await fetcher.icon(forPage: pageURL) {
            return ImageKind.forBrowsers(d)
        }
        return nil
    }
}

_ = queue.sync { engine.refresh(force: true) }
let watcher = ChangeWatcher(directories: [args[2]], fileNames: ["CloudTabs.db", "SafariTabs.db"], queue: queue) {
    if engine.refresh() { print("changed: \(engine.state.revision ?? "-")") }
}
watcher.start()
let router = Router(config: .init(token: args[4], feedSecret: args.count > 5 ? args[5] : "dev-feed-secret",
                                  allowedHosts: Router.allowedHosts(bind: "127.0.0.1", port: Int(port), names: [])),
                    backend: DevBackend())
let server = HTTPServer(router: router, onEvent: { e in
    print("\(e.kind.rawValue) \(e.status) \(e.bytes)B \(e.client ?? "-")")
}, onState: { s in print("server: \(s)") })
server.start(host: "127.0.0.1", port: port)
dispatchMain()
