import Foundation
import TabTunnelModel

/// The app's side of the XPC link to TabTunnel Reader. Reconnects on its own when the reader restarts
/// (launchd relaunches it on demand) and backs off while it can't be reached.
final class ReaderClient: NSObject, ReaderClientXPC, @unchecked Sendable {
    enum Link: Equatable {
        case connecting
        case connected
        /// The reader couldn't be reached. `reason` is shown in the status view.
        case unavailable(String)
    }

    /// Both called on the main queue.
    var onState: (ReaderState) -> Void = { _ in }
    var onLink: (Link) -> Void = { _ in }

    private var connection: NSXPCConnection?
    private var retryDelay: Double = 1
    private var generation = 0
    private var stopped = false
    /// The generation whose subscribe call was answered by a reader that passed the code-signing check. Tab URLs
    /// (favicon requests) are only sent on such a connection.
    private var verifiedGeneration = -1

    func connect() {
        dispatchPrecondition(condition: .onQueue(.main))
        stopped = false
        connection?.invalidate()
        generation += 1
        let gen = generation
        guard let requirement = CodeSigning.requirement(forPeer: TabTunnelIDs.reader) else {
            onLink(.unavailable("This copy of TabTunnel isn't signed, so it can't talk to TabTunnel Reader."))
            return
        }
        onLink(.connecting)
        let c = NSXPCConnection(machServiceName: TabTunnelIDs.readerService, options: [])
        c.setCodeSigningRequirement(requirement)
        c.remoteObjectInterface = NSXPCInterface(with: ReaderXPC.self)
        c.exportedInterface = NSXPCInterface(with: ReaderClientXPC.self)
        c.exportedObject = self
        // Interrupted: the reader exited (idle, crash, or restart after an access change). Resubscribe.
        c.interruptionHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, gen == self.generation, !self.stopped else { return }
                self.onLink(.connecting)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.subscribe(gen) }
            }
        }
        c.invalidationHandler = { [weak self] in
            DispatchQueue.main.async {
                guard let self, gen == self.generation, !self.stopped else { return }
                self.onLink(.unavailable("TabTunnel Reader isn't running."))
                self.scheduleRetry()
            }
        }
        connection = c
        c.resume()
        subscribe(gen)
    }

    func stop() {
        stopped = true
        connection?.invalidate()
        connection = nil
    }

    private func scheduleRetry() {
        let delay = retryDelay
        retryDelay = min(retryDelay * 2, 30)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.connect()
        }
    }

    private func proxy(_ gen: Int) -> ReaderXPC? {
        connection?.remoteObjectProxyWithErrorHandler { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.onLink(.unavailable("TabTunnel Reader isn't responding."))
            }
        } as? ReaderXPC
    }

    private func subscribe(_ gen: Int) {
        var answered = false
        proxy(gen)?.subscribe { [weak self] data in
            DispatchQueue.main.async {
                answered = true
                guard let self, gen == self.generation, let state = ReaderState.decode(data) else { return }
                self.verifiedGeneration = gen
                self.retryDelay = 1
                self.onLink(.connected)
                self.onState(state)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self, !answered, gen == self.generation, !self.stopped else { return }
            self.onLink(.unavailable("TabTunnel Reader isn't responding."))
            self.scheduleRetry()
        }
    }

    /// Re-read Safari's data now.
    func refresh() {
        let gen = generation
        proxy(gen)?.refresh { [weak self] data in
            DispatchQueue.main.async {
                guard let self, gen == self.generation, let state = ReaderState.decode(data) else { return }
                self.onState(state)
            }
        }
    }

    /// Safari's cached icon bytes for a page in the current snapshot.
    func favicon(_ pageURL: String) async -> Data? {
        let p: ReaderXPC? = await MainActor.run { verifiedGeneration == generation ? proxy(generation) : nil }
        guard let p else { return nil }
        return await withCheckedContinuation { cont in
            var resumed = false
            let lock = NSLock()
            func finish(_ d: Data?) {
                lock.lock(); defer { lock.unlock() }
                if !resumed { resumed = true; cont.resume(returning: d) }
            }
            p.favicon(pageURL: pageURL) { d in finish(d.flatMap { $0.count <= TabTunnelIDs.maxIconBytes * 4 ? $0 : nil }) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5) { finish(nil) }
        }
    }

    // ReaderClientXPC: pushed by the reader when something changed.
    func stateChanged(_ state: Data) {
        guard let s = ReaderState.decode(state) else { return }
        DispatchQueue.main.async { [weak self] in self?.onState(s) }
    }
}
