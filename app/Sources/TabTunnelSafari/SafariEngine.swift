import Foundation
import TabTunnelModel

/// Holds the last good snapshot and turns Safari's files into `ReaderState`. Not thread-safe: the reader
/// drives it from one serial queue.
public final class SafariEngine {
    public let paths: SafariPaths
    public let favicons: SafariFaviconCache
    public private(set) var state: ReaderState
    private var signature: FileSignature?
    private var knownURLs: Set<String> = []

    public init(paths: SafariPaths) {
        self.paths = paths
        self.favicons = SafariFaviconCache(dirs: paths.faviconDirs)
        self.state = ReaderState(status: ReaderStatus(problem: .readFailed, detail: "not read yet"), snapshot: nil)
    }

    /// The files whose changes matter, for the watcher.
    public var watchedDirectories: [String] { paths.safariDirs }

    /// Reads Safari's data if its files changed (or `force`). Returns true when the state changed
    /// (new content or a different problem), which is when the app should hear about it.
    @discardableResult
    public func refresh(force: Bool = false, now: Date = Date()) -> Bool {
        let old = state
        let cloudTabs: String
        do {
            guard let p = try SafariData.findCloudTabs(paths) else { return fail(.noDatabase, now: now, old: old) }
            cloudTabs = p
        } catch let e as ReadError {
            return fail(e, now: now, old: old)
        } catch {
            return fail(.failed("find"), now: now, old: old)
        }
        let groupsPath = (cloudTabs as NSString).deletingLastPathComponent + "/SafariTabs.db"
        let sig: FileSignature
        do {
            sig = try FileSignature.of([cloudTabs, groupsPath])
        } catch let e as ReadError {
            return fail(e, now: now, old: old)
        } catch {
            return fail(.failed("stat"), now: now, old: old)
        }
        // Nothing changed on disk and the last read was complete: nothing to do. (A failed Tab Groups read is
        // retried on the next check even if the files didn't change.)
        if !force, sig == signature, state.snapshot != nil, state.status.problem == nil, state.status.groupsError == nil {
            return false
        }

        let devices: [Device]
        do {
            devices = try SafariData.readDevices(SafariData.loadPrivate(cloudTabs))
        } catch let e as ReadError {
            return fail(e, now: now, old: old)
        } catch {
            return fail(.failed("CloudTabs.db: \(error)"), now: now, old: old)
        }
        var groups: [TabGroup] = []
        var groupsError: String?
        if FileManager.default.fileExists(atPath: groupsPath) {
            do {
                groups = try SafariData.readTabGroups(SafariData.loadPrivate(groupsPath))
            } catch {
                // Tab Groups are optional; iCloud Tabs still work. Keep showing the last good groups.
                groupsError = "Tab Groups couldn't be read"
                groups = state.snapshot?.tabGroups ?? []
            }
        }
        let mtimes = [cloudTabs, groupsPath, cloudTabs + "-wal", groupsPath + "-wal"].compactMap { p -> Date? in
            (try? FileManager.default.attributesOfItem(atPath: p))?[.modificationDate] as? Date
        }
        let sourceModified = mtimes.max().map(ISO.string)
        var snapshot = Snapshot(updatedAt: ISO.string(now), sourceModifiedAt: sourceModified, devices: devices,
                                tabGroups: groups, tabGroupsError: groupsError)
        if let previous = state.snapshot, previous.contentHash == snapshot.contentHash {
            snapshot = previous // same content: keep its timestamps, so its ETag and "updated" time stay put
        }
        signature = sig
        knownURLs = Set(snapshot.devices.flatMap { $0.tabs.map(\.url) } + snapshot.tabGroups.flatMap { $0.tabs.map(\.url) })
        let changed = snapshot.contentHash != state.snapshot?.contentHash || state.snapshot == nil
        let status = ReaderStatus(problem: nil, detail: nil, groupsError: groupsError, lastRead: ISO.string(now),
                                  lastChange: changed ? ISO.string(now) : (state.status.lastChange ?? ISO.string(now)),
                                  sourceModifiedAt: sourceModified)
        var withMethod = status
        withMethod.readMethod = SafariData.lastMethod.rawValue
        state = ReaderState(status: withMethod, snapshot: snapshot)
        return changed || old.status.problem != nil || old.status.groupsError != groupsError
            || old.status.sourceModifiedAt != sourceModified
    }

    private func fail(_ e: ReadError, now: Date, old: ReaderState) -> Bool {
        var status = state.status
        status.problem = e.problem
        status.detail = e.detail
        if e.problem == .noAccess { signature = nil }
        state = ReaderState(status: status, snapshot: state.snapshot)
        return old.status.problem != status.problem || old.status.detail != status.detail
    }

    /// Safari's cached icon, only for pages in the current snapshot.
    public func favicon(forPage url: String) -> Data? {
        guard knownURLs.contains(url) else { return nil }
        return favicons.icon(forPage: url)
    }
}
