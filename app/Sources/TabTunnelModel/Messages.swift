import Foundation

public extension ReaderProblem {
    /// One sentence for the extensions (served as `error`) and the app.
    var message: String {
        switch self {
        case .noAccess:
            return "TabTunnel Reader doesn't have Full Disk Access, so it can't read Safari's tabs."
        case .noDatabase:
            return "Safari hasn't synced any iCloud Tabs to this Mac yet."
        case .unsupportedSchema:
            return "A Safari update changed how it stores tabs, and this version of TabTunnel can't read them."
        case .readFailed:
            return "TabTunnel couldn't read Safari's tabs. It will try again."
        }
    }
}
