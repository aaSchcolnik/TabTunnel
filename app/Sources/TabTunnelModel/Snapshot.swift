import CryptoKit
import Foundation

/// One tab. Device tabs have no `id`; Tab Group tabs carry Safari's stable `external_uuid`.
public struct Tab: Codable, Hashable, Sendable {
    public var id: String?
    public var title: String
    public var url: String
    public var pinned: Bool?

    public init(id: String? = nil, title: String, url: String, pinned: Bool? = nil) {
        self.id = id
        self.title = title
        self.url = url
        self.pinned = pinned
    }
}

public enum DeviceKind: String, Codable, Sendable {
    case phone, tablet, laptop, desktop, unknown
}

public struct Device: Codable, Hashable, Sendable {
    public var name: String
    public var kind: DeviceKind
    /// ISO 8601. The newest tab view on that device (Safari's own `last_modified` is rounded to whole days).
    public var lastModified: String?
    public var tabs: [Tab]

    public init(name: String, kind: DeviceKind, lastModified: String?, tabs: [Tab]) {
        self.name = name
        self.kind = kind
        self.lastModified = lastModified
        self.tabs = tabs
    }
}

public struct TabGroup: Codable, Hashable, Sendable {
    public var id: String
    public var title: String
    public var tabs: [Tab]

    public init(id: String, title: String, tabs: [Tab]) {
        self.id = id
        self.title = title
        self.tabs = tabs
    }
}

/// What `GET /tabs` serves. The JSON shape is the one the extensions already read (see webext/src/lib/ext.ts).
public struct Snapshot: Codable, Hashable, Sendable {
    /// When the content last changed (not when it was last read), so it matches the ETag.
    public var updatedAt: String
    /// Newest modification time of Safari's database files when the content last changed.
    public var sourceModifiedAt: String?
    public var devices: [Device]
    public var tabGroups: [TabGroup]
    public var tabGroupsError: String?

    public init(updatedAt: String, sourceModifiedAt: String?, devices: [Device], tabGroups: [TabGroup],
                tabGroupsError: String? = nil) {
        self.updatedAt = updatedAt
        self.sourceModifiedAt = sourceModifiedAt
        self.devices = devices
        self.tabGroups = tabGroups
        self.tabGroupsError = tabGroupsError
    }

    public var deviceTabCount: Int { devices.reduce(0) { $0 + $1.tabs.count } }
    public var groupTabCount: Int { tabGroups.reduce(0) { $0 + $1.tabs.count } }

    /// A hash of what a user can see: tabs, titles, URLs, order, device names and kinds, and each device's
    /// "last active" rounded to the minute. Timestamps of the read itself are left out, so re-reading an
    /// unchanged database never produces a new revision (and never costs the extensions a download).
    public var contentHash: String {
        struct Content: Encodable {
            let devices: [Device]
            let tabGroups: [TabGroup]
            let tabGroupsError: String?
        }
        let devices = self.devices.map { d -> Device in
            var d = d
            d.lastModified = d.lastModified.map { String($0.prefix(16)) } // yyyy-MM-ddTHH:mm
            return d
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(Content(devices: devices, tabGroups: tabGroups, tabGroupsError: tabGroupsError)))
            ?? Data()
        return SHA256.hash(data: data).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public static let empty = Snapshot(updatedAt: ISO.now(), sourceModifiedAt: nil, devices: [], tabGroups: [])
}

public enum ISO {
    public static func string(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    public static func now() -> String { string(Date()) }

    public static func date(_ s: String?) -> Date? {
        guard let s else { return nil }
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

public extension JSONEncoder {
    /// The encoder for everything served to the extensions.
    static var wire: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }
}
