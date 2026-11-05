import CoreServices
import Foundation

/// Calls `onChange` (on `queue`) shortly after Safari writes to its databases, instead of polling.
///
/// FSEvents watches the folders (SQLite deletes and recreates the WAL, so watching single files would miss
/// writes). Bursts are coalesced: `debounce` after the last event, but never later than `maxDelay` after the
/// first one while writes keep coming. Dropped events, a root change or a wake trigger a full re-read.
/// A slow safety check (`safetyInterval`; the engine only stat()s the files and re-reads nothing unless they
/// changed) covers anything FSEvents misses.
public final class ChangeWatcher {
    private let directories: [String]
    private let names: [String]
    private let queue: DispatchQueue
    private let onChange: () -> Void
    private let debounce: TimeInterval
    private let maxDelay: TimeInterval
    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var firstPending: Date?
    private var safety: DispatchSourceTimer?

    public init(directories: [String], fileNames: [String], queue: DispatchQueue, debounce: TimeInterval = 0.3,
                maxDelay: TimeInterval = 2, safetyInterval: TimeInterval = 60, onChange: @escaping () -> Void) {
        self.directories = directories
        self.names = fileNames
        self.queue = queue
        self.onChange = onChange
        self.debounce = debounce
        self.maxDelay = maxDelay
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + safetyInterval, repeating: safetyInterval, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.onChange() }
        safety = t
    }

    public func start() {
        // FSEvents reports real paths, so watch the real ones (e.g. /var is a link to /private/var).
        let existing = directories.filter { FileManager.default.fileExists(atPath: $0) }
            .map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, count, paths, flags, _ in
            guard let info else { return }
            let me = Unmanaged<ChangeWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            var relevant = false
            for i in 0..<count {
                let f = Int(flags[i])
                if f & (kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagUserDropped
                        | kFSEventStreamEventFlagKernelDropped | kFSEventStreamEventFlagRootChanged) != 0 {
                    relevant = true
                    break
                }
                let name = (list.count > i ? list[i] : "") as NSString
                if me.names.contains(where: { name.lastPathComponent.hasPrefix($0) }) {
                    relevant = true
                    break
                }
            }
            if relevant { me.schedule() }
        }
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer
                           | kFSEventStreamCreateFlagWatchRoot | kFSEventStreamCreateFlagUseCFTypes)
        if !existing.isEmpty,
           let s = FSEventStreamCreate(nil, callback, &ctx, existing as CFArray,
                                       FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.1, flags) {
            FSEventStreamSetDispatchQueue(s, queue)
            FSEventStreamStart(s)
            stream = s
        }
        safety?.resume()
    }

    /// Re-read soon (the app calls this after the Mac wakes, when iCloud catches up in a burst).
    public func poke() { queue.async { self.schedule() } }

    /// Whether FSEvents is running (false when no Safari folder existed at start; the safety check still runs).
    public var isWatching: Bool { stream != nil }

    private func schedule() {
        let now = Date()
        if firstPending == nil { firstPending = now }
        pending?.cancel()
        let waited = now.timeIntervalSince(firstPending!)
        let delay = max(0, min(debounce, maxDelay - waited))
        let item = DispatchWorkItem { [weak self] in
            self?.firstPending = nil
            self?.onChange()
        }
        pending = item
        queue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
        safety?.cancel()
    }
}
