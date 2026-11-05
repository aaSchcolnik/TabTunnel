import Foundation

/// Identifiers shared by the app and the reader.
public enum TabTunnelIDs {
    public static let app = "dev.tabtunnel.TabTunnel"
    public static let reader = "dev.tabtunnel.TabTunnel.Reader"
    /// The reader's launchd label and Mach service (one job, one name).
    public static let readerService = "dev.tabtunnel.TabTunnel.Reader"
    public static let readerAppName = "TabTunnel Reader.app"
    /// Largest message either side accepts over XPC (a snapshot of thousands of tabs is well under this).
    public static let maxMessageBytes = 16 * 1024 * 1024
    public static let maxIconBytes = 1024 * 1024
}

/// Why the reader can't produce tabs right now. The app turns each into a message and a fix.
public enum ReaderProblem: String, Codable, Sendable {
    /// macOS denied access to Safari's folder: the reader lacks Full Disk Access.
    case noAccess
    /// No CloudTabs.db: Safari has never synced iCloud Tabs on this Mac.
    case noDatabase
    /// The database exists but doesn't look like what TabTunnel knows (a Safari update changed it).
    case unsupportedSchema
    /// Reading failed for another reason (busy, corrupt, disk error). Retried automatically.
    case readFailed
}

public struct ReaderStatus: Codable, Hashable, Sendable {
    public var problem: ReaderProblem?
    /// Short, non-identifying detail (no titles, URLs or hostnames), e.g. the missing table names.
    public var detail: String?
    /// Tab Groups failed to read but iCloud Tabs work; the groups shown are the last good copy.
    public var groupsError: String?
    /// Last time the reader read Safari's data successfully.
    public var lastRead: String?
    /// Last time the visible content changed.
    public var lastChange: String?
    /// Newest modification time of Safari's files (iCloud writes these when other devices sync).
    public var sourceModifiedAt: String?
    /// "direct" (live file read-only into memory) or "copy" (fallback through a private temp folder).
    public var readMethod: String?
    public var version: String

    public init(problem: ReaderProblem? = nil, detail: String? = nil, groupsError: String? = nil,
                lastRead: String? = nil, lastChange: String? = nil, sourceModifiedAt: String? = nil,
                version: String = TabTunnelVersion.string) {
        self.problem = problem
        self.detail = detail
        self.groupsError = groupsError
        self.lastRead = lastRead
        self.lastChange = lastChange
        self.sourceModifiedAt = sourceModifiedAt
        self.version = version
    }
}

/// Everything the reader tells the app. `snapshot` is the last good copy, kept even while there's a problem.
public struct ReaderState: Codable, Hashable, Sendable {
    public var status: ReaderStatus
    public var snapshot: Snapshot?
    /// `snapshot.contentHash`, sent so the app can skip decoding work when nothing changed.
    public var revision: String?

    public init(status: ReaderStatus, snapshot: Snapshot?) {
        self.status = status
        self.snapshot = snapshot
        self.revision = snapshot?.contentHash
    }

    public func encoded() -> Data { (try? JSONEncoder().encode(self)) ?? Data() }

    public static func decode(_ data: Data) -> ReaderState? {
        guard data.count <= TabTunnelIDs.maxMessageBytes else { return nil }
        return try? JSONDecoder().decode(ReaderState.self, from: data)
    }
}

public enum TabTunnelVersion {
    public static let string = "1.0.0"
}

/// What the app may ask the reader. Fixed operations only: no paths, SQL or commands ever cross this line.
@objc public protocol ReaderXPC {
    /// Subscribe: the reader replies with its current state now and pushes every later change to the
    /// connection's exported `ReaderClientXPC` object.
    func subscribe(reply: @escaping (Data) -> Void)
    /// Re-read Safari's data now (the "Check again" button), then reply with the state.
    func refresh(reply: @escaping (Data) -> Void)
    /// Safari's cached icon for a page shown in the current snapshot, as stored (PNG, ICO, TIFF...), or nil.
    func favicon(pageURL: String, reply: @escaping (Data?) -> Void)
}

/// What the reader pushes to the app.
@objc public protocol ReaderClientXPC {
    func stateChanged(_ state: Data)
}
