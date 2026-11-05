// TabTunnel Reader: the only part of TabTunnel that holds Full Disk Access.
//
// It reads Safari's synced tabs (CloudTabs.db), Tab Groups (SafariTabs.db) and favicon cache, and answers
// TabTunnel.app over XPC. It has no network code (it doesn't link TabTunnelNet), runs no other programs,
// accepts no paths or queries, and only talks to TabTunnel.app signed the same way: same Apple team, or for
// self-signed release builds the same certificate (checked by the system on every
// connection). launchd starts it on demand when the app connects; it exits when no app has been connected
// for a minute, so quitting TabTunnel stops everything.
import Foundation
import os
import TabTunnelModel
import TabTunnelSafari

let log = Logger(subsystem: "dev.tabtunnel", category: "reader")
let queue = DispatchQueue(label: "dev.tabtunnel.reader.engine", qos: .utility)
let engine = SafariEngine(paths: .live)

/// Connected apps (normally one). Touched only on `queue`.
var subscribers: [ObjectIdentifier: NSXPCConnection] = [:]
var lastSubscriberLeft = Date()

func broadcast() {
    let data = engine.state.encoded()
    for c in subscribers.values {
        (c.remoteObjectProxyWithErrorHandler { _ in } as? ReaderClientXPC)?.stateChanged(data)
    }
}

func logState() {
    let s = engine.state
    if let p = s.status.problem {
        log.error("problem: \(p.rawValue, privacy: .public)")
    } else if let snap = s.snapshot {
        log.info("read \(snap.devices.count) devices, \(snap.deviceTabCount) tabs, \(snap.tabGroups.count) groups (\(snap.groupTabCount) tabs)")
    }
}

final class Service: NSObject, ReaderXPC {
    weak var connection: NSXPCConnection?

    init(connection: NSXPCConnection) { self.connection = connection }

    func subscribe(reply: @escaping (Data) -> Void) {
        queue.async {
            if let c = self.connection { subscribers[ObjectIdentifier(c)] = c }
            if engine.refresh() { logState() }
            reply(engine.state.encoded())
        }
    }

    func refresh(reply: @escaping (Data) -> Void) {
        queue.async {
            let hadNoAccess = engine.state.status.problem == .noAccess
            if engine.refresh(force: true) { logState() }
            reply(engine.state.encoded())
            broadcast()
            // macOS may only apply a new Full Disk Access grant to a fresh process. If access is still missing,
            // exit; launchd starts a new reader the next time the app connects (it reconnects at once).
            if hadNoAccess && engine.state.status.problem == .noAccess {
                queue.asyncAfter(deadline: .now() + 0.3) { exit(0) }
            }
        }
    }

    func favicon(pageURL: String, reply: @escaping (Data?) -> Void) {
        guard pageURL.utf8.count <= 8192 else { return reply(nil) }
        queue.async { reply(engine.favicon(forPage: pageURL)) }
    }
}

final class ListenerDelegate: NSObject, NSXPCListenerDelegate {
    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection c: NSXPCConnection) -> Bool {
        c.exportedInterface = NSXPCInterface(with: ReaderXPC.self)
        c.remoteObjectInterface = NSXPCInterface(with: ReaderClientXPC.self)
        c.exportedObject = Service(connection: c)
        let id = ObjectIdentifier(c)
        c.invalidationHandler = {
            queue.async {
                subscribers.removeValue(forKey: id)
                if subscribers.isEmpty { lastSubscriberLeft = Date() }
            }
        }
        c.resume()
        return true
    }
}

guard let requirement = CodeSigning.requirement(forPeer: TabTunnelIDs.app) else {
    // An unsigned or ad-hoc build can't prove who is calling, so it serves no one.
    log.fault("refusing to run: this build isn't signed with a certificate")
    exit(78)
}
let listener = NSXPCListener(machServiceName: TabTunnelIDs.readerService)
listener.setConnectionCodeSigningRequirement(requirement)
let delegate = ListenerDelegate()
listener.delegate = delegate

// Leftovers from a reader killed mid-copy (only the fallback read path makes copies).
queue.sync { SafariData.sweepLeftovers() }
// Quit cleanly: SIGTERM waits for the current read on the engine queue, so a copy is never left behind.
signal(SIGTERM, SIG_IGN)
let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
term.setEventHandler { exit(0) }
term.resume()

// Nothing is read until an app that passed the code-signing check subscribes: looking up the Mach service
// (which makes launchd start this process) gets an outsider nothing.
let watcher = ChangeWatcher(directories: engine.watchedDirectories, fileNames: ["CloudTabs.db", "SafariTabs.db"], queue: queue) {
    guard !subscribers.isEmpty else { return }
    if engine.refresh() {
        logState()
        broadcast()
    }
}
watcher.start()

// Exit when idle: no app connected for 60 s. launchd relaunches on the next connection.
let idle = DispatchSource.makeTimerSource(queue: queue)
idle.schedule(deadline: .now() + 30, repeating: 30, leeway: .seconds(5))
idle.setEventHandler {
    if subscribers.isEmpty && Date().timeIntervalSince(lastSubscriberLeft) > 60 {
        log.info("no app connected; exiting until needed")
        exit(0)
    }
}
idle.resume()

listener.resume()
log.info("reader \(TabTunnelVersion.string, privacy: .public) ready")
dispatchMain()
