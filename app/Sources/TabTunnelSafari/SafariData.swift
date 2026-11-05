import Compression
import Foundation
import TabTunnelModel

/// Where Safari keeps the data TabTunnel reads. These are private, undocumented files: a Safari or macOS
/// update can move or change them, and then reading fails with `.noDatabase` or `.unsupportedSchema`.
public struct SafariPaths: Sendable {
    /// Directories that may hold CloudTabs.db (and SafariTabs.db next to it), newest layout first.
    public var safariDirs: [String]
    public var faviconDirs: [String]

    public init(safariDirs: [String], faviconDirs: [String]) {
        self.safariDirs = safariDirs
        self.faviconDirs = faviconDirs
    }

    public static var live: SafariPaths {
        let home = SafariData.realHome
        return SafariPaths(
            safariDirs: [home + "/Library/Containers/com.apple.Safari/Data/Library/Safari", home + "/Library/Safari"],
            faviconDirs: [home + "/Library/Safari/Favicon Cache",
                          home + "/Library/Containers/com.apple.Safari/Data/Library/Safari/Favicon Cache"])
    }

    /// A test layout: one folder with CloudTabs.db and (optionally) SafariTabs.db and a Favicon Cache folder.
    public static func fixture(_ dir: String) -> SafariPaths {
        SafariPaths(safariDirs: [dir], faviconDirs: [dir + "/Favicon Cache"])
    }
}

public enum ReadError: Error {
    case noAccess
    case noDatabase
    case unsupportedSchema(String)
    case failed(String)

    public var problem: ReaderProblem {
        switch self {
        case .noAccess: return .noAccess
        case .noDatabase: return .noDatabase
        case .unsupportedSchema: return .unsupportedSchema
        case .failed: return .readFailed
        }
    }

    public var detail: String? {
        switch self {
        case .unsupportedSchema(let s), .failed(let s): return s
        default: return nil
        }
    }
}

/// File identity used to notice changes cheaply: (mtime ns, size) of a database and its WAL.
public struct FileSignature: Hashable, Sendable {
    var parts: [Int64]

    public static func of(_ paths: [String]) throws -> FileSignature {
        var parts: [Int64] = []
        for p in paths {
            for suffix in ["", "-wal"] {
                var st = stat()
                if stat(p + suffix, &st) == 0 {
                    parts += [Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec), Int64(st.st_size)]
                } else if errno == EPERM || errno == EACCES {
                    throw ReadError.noAccess
                } else {
                    parts += [-1, -1]
                }
            }
        }
        return FileSignature(parts: parts)
    }
}

public enum SafariData {
    /// Finds CloudTabs.db. Throws `.noAccess` when macOS blocks the folder (no Full Disk Access).
    public static func findCloudTabs(_ paths: SafariPaths) throws -> String? {
        var denied = false
        for dir in paths.safariDirs {
            let p = dir + "/CloudTabs.db"
            var st = stat()
            if stat(p, &st) == 0 { return p }
            if errno == EPERM || errno == EACCES {
                denied = true
                continue
            }
            // The file may look missing while the folder itself is blocked: try listing the folder.
            if let d = opendir(dir) {
                closedir(d)
            } else if errno == EPERM || errno == EACCES {
                denied = true
            }
        }
        if denied { throw ReadError.noAccess }
        return nil
    }

    /// The user's home folder from the user database, not from HOME/CFFIXED_USER_HOME, so the environment of a
    /// launchd job can't point the reader somewhere else.
    public static var realHome: String {
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { return String(cString: dir) }
        return NSHomeDirectory()
    }

    /// The per-user temporary folder from the system, not from TMPDIR.
    public static var realTemp: String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        if confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count) > 0 { return String(cString: buf) }
        return NSTemporaryDirectory()
    }

    public enum Method: String, Sendable { case direct, copy }
    /// How the last database was read (for diagnostics).
    public nonisolated(unsafe) static var lastMethod: Method = .direct

    /// An in-memory copy of a database with its WAL applied, made without writing Safari's data anywhere:
    /// SQLite opens the live file read-only (a read-only connection never checkpoints or changes Safari's files)
    /// and copies it into memory. Only if that fails (for example a missing -shm) does it fall back to copying
    /// the files into a fresh 0700 folder for the moment SQLite needs them.
    public static func loadPrivate(_ src: String) throws -> SQLiteDB {
        var st = stat()
        if stat(src, &st) != 0 && (errno == EPERM || errno == EACCES) { throw ReadError.noAccess }
        if let db = try? SQLiteDB.memoryCopy(ofFileAt: src) {
            lastMethod = .direct
            return db
        }
        lastMethod = .copy
        return try loadViaCopy(src)
    }

    /// Fallback: copy db/-wal/-shm into a private temp folder, read into memory, delete at once.
    /// If Safari writes during the copy, it copies again.
    static func loadViaCopy(_ src: String) throws -> SQLiteDB {
        var lastError: Error = ReadError.failed("copy failed")
        for _ in 0..<3 {
            let before = try FileSignature.of([src])
            let work = (realTemp as NSString).appendingPathComponent("tabtunnel-" + UUID().uuidString)
            guard mkdir(work, 0o700) == 0 else { throw ReadError.failed("temp folder") }
            defer { try? FileManager.default.removeItem(atPath: work) }
            let dest = work + "/db.sqlite"
            do {
                try copyFile(src, dest)
                for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: src + suffix) {
                    try copyFile(src + suffix, dest + suffix)
                }
            } catch let e as ReadError {
                throw e
            } catch {
                lastError = ReadError.failed("copy failed")
                continue
            }
            if try FileSignature.of([src]) != before { continue } // Safari wrote mid-copy: take a clean copy
            do {
                return try SQLiteDB.memoryCopy(ofFileAt: dest)
            } catch {
                lastError = ReadError.failed("open failed")
            }
        }
        throw lastError
    }

    /// Removes copies a killed reader may have left behind.
    public static func sweepLeftovers() {
        let tmp = realTemp
        for name in (try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? [] where name.hasPrefix("tabtunnel-") {
            try? FileManager.default.removeItem(atPath: (tmp as NSString).appendingPathComponent(name))
        }
    }

    private static func copyFile(_ src: String, _ dst: String) throws {
        let fd = open(src, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            if errno == EPERM || errno == EACCES { throw ReadError.noAccess }
            throw ReadError.failed("open")
        }
        defer { close(fd) }
        let out = open(dst, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard out >= 0 else { throw ReadError.failed("create") }
        defer { close(out) }
        var buf = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buf, buf.count)
            if n < 0 { throw ReadError.failed("read") }
            if n == 0 { break }
            var off = 0
            while off < n {
                let w = buf[off..<n].withUnsafeBytes { write(out, $0.baseAddress, n - off) }
                if w <= 0 { throw ReadError.failed("write") }
                off += w
            }
        }
    }

    // MARK: - iCloud Tabs (CloudTabs.db)

    /// All schema knowledge for CloudTabs.db lives here, so a Safari update only breaks one function.
    public static func readDevices(_ db: SQLiteDB) throws -> [Device] {
        let tables = Set(try db.tables())
        guard tables.contains("cloud_tabs"), tables.contains("cloud_tab_devices") else {
            throw ReadError.unsupportedSchema("tables: " + tables.sorted().joined(separator: ", "))
        }
        let tcols = Set(try db.columns("cloud_tabs")), dcols = Set(try db.columns("cloud_tab_devices"))
        guard tcols.contains("device_uuid"), tcols.contains("url"), dcols.contains("device_uuid"), dcols.contains("device_name") else {
            throw ReadError.unsupportedSchema("columns changed")
        }
        func col(_ cols: Set<String>, _ name: String) -> String { cols.contains(name) ? name : "NULL" }

        struct Dev { var device: Device; var sort: Double; var tabs: [(Tab, PositionKey)] }
        var devices: [String: Dev] = [:]
        var order: [String] = []
        let devSQL = "SELECT device_uuid, device_name, \(col(dcols, "device_type_identifier")), \(col(dcols, "last_modified")), "
            + "\(col(dcols, "is_ephemeral_device")) FROM cloud_tab_devices"
        try db.query(devSQL) { r in
            guard let uuid = r.text(0), !r.bool(4) else { return }
            let name = r.text(1) ?? "Unknown device"
            let modified = r.double(3)
            devices[uuid] = Dev(device: Device(name: name.isEmpty ? "Unknown device" : name,
                                               kind: deviceKind(r.text(2), name), lastModified: appleTime(modified), tabs: []),
                                sort: modified ?? 0, tabs: [])
            order.append(uuid)
        }
        let tabSQL = "SELECT device_uuid, \(col(tcols, "title")), url, \(col(tcols, "is_pinned")), \(col(tcols, "position")), "
            + "\(col(tcols, "last_viewed_time")) FROM cloud_tabs"
        try db.query(tabSQL) { r in
            guard let dev = r.text(0), var d = devices[dev], let url = r.text(2), !url.isEmpty else { return }
            // last_modified is rounded to whole days; the newest tab view is a better "last active".
            if let viewed = r.double(5), viewed > d.sort {
                d.sort = viewed
                d.device.lastModified = appleTime(viewed)
            }
            let title = r.text(1).flatMap { $0.isEmpty ? nil : $0 } ?? url
            d.tabs.append((Tab(title: title, url: url, pinned: r.bool(3) ? true : nil), positionKey(r.value(4))))
            devices[dev] = d
        }
        // Newest device first; ties keep table order (Python's sort is stable too).
        let sorted = order.enumerated().compactMap { i, uuid in devices[uuid].map { (i, $0) } }
            .sorted { a, b in a.1.sort != b.1.sort ? a.1.sort > b.1.sort : a.0 < b.0 }
        return sorted.compactMap { _, d in
            guard !d.tabs.isEmpty else { return nil }
            var device = d.device
            device.tabs = d.tabs.enumerated().sorted { a, b in
                a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset
            }.map { $0.element.0 }
            return device
        }
    }

    public static func deviceKind(_ typeID: String?, _ name: String?) -> DeviceKind {
        let s = "\(typeID ?? "") \(name ?? "")".lowercased()
        if s.contains("iphone") { return .phone }
        if s.contains("ipad") { return .tablet }
        if s.contains("macbook") { return .laptop }
        if s.contains("imac") || s.contains("mac") { return .desktop }
        return .unknown
    }

    /// Safari stores Core Data timestamps (seconds since 2001-01-01).
    public static func appleTime(_ v: Double?) -> String? {
        guard let v, v <= 1e11 else { return nil }
        return ISO.string(Date(timeIntervalSinceReferenceDate: v))
    }

    public struct PositionKey: Comparable {
        let missing: Int
        let value: Double
        public static func < (a: PositionKey, b: PositionKey) -> Bool {
            (a.missing, a.value) < (b.missing, b.value)
        }
    }

    /// `position` is zlib-compressed JSON on macOS 26: {"sortValues":[{"changeID":0,"sortValue":1799000,...}]}.
    /// Older versions used plain JSON or a number; the latest changeID wins.
    public static func positionKey(_ raw: SQLValue) -> PositionKey {
        let none = PositionKey(missing: 1, value: 0)
        var data: Data
        switch raw {
        case .null: return none
        case .number(let n): return PositionKey(missing: 0, value: n)
        case .bytes(let d): data = d
        }
        if data.first == UInt8(ascii: "x"), let inflated = zlibInflate(data) { data = inflated }
        guard let obj = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return none }
        if let n = obj as? NSNumber { return PositionKey(missing: 0, value: n.doubleValue) }
        guard let dict = obj as? [String: Any] else { return none }
        for k in ["sortValues", "position"] {
            guard let v = dict[k] else { continue }
            if let list = v as? [Any], let first = list.first {
                if first is [String: Any] {
                    let entries = list.compactMap { $0 as? [String: Any] }
                    var best = entries[0]
                    for e in entries where ((e["changeID"] as? NSNumber)?.doubleValue ?? 0) > ((best["changeID"] as? NSNumber)?.doubleValue ?? 0) {
                        best = e
                    }
                    return PositionKey(missing: 0, value: (best["sortValue"] as? NSNumber)?.doubleValue ?? 0)
                }
                if let n = first as? NSNumber { return PositionKey(missing: 0, value: n.doubleValue) }
                return none
            }
            if let n = v as? NSNumber { return PositionKey(missing: 0, value: n.doubleValue) }
            return none
        }
        return none
    }

    /// zlib stream (2-byte header + raw deflate + adler32) -> bytes. Apple's Compression framework only
    /// speaks raw deflate, so the header is skipped. Output is capped at 1 MB.
    static func zlibInflate(_ data: Data) -> Data? {
        guard data.count > 2 else { return nil }
        let body = data.dropFirst(2)
        let cap = 1 << 20
        var out = Data(count: cap)
        let n = out.withUnsafeMutableBytes { dst in
            body.withUnsafeBytes { src in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, body.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard n > 0, n < cap else { return nil }
        return out.prefix(n)
    }

    // MARK: - Tab Groups (SafariTabs.db)

    /// Layout seen on macOS 26: `bookmarks` is a tree. The folder titled "Root" (parent NULL) holds one folder per
    /// tab group (type=1, subtype=0). A group holds its tabs (type=0, by order_index) and a type=1/subtype=1
    /// folder with the group's pinned tabs.
    public static func readTabGroups(_ db: SQLiteDB) throws -> [TabGroup] {
        guard try db.tables().contains("bookmarks") else { throw ReadError.unsupportedSchema("no bookmarks table") }
        var rootID: String?
        try db.query("SELECT id FROM bookmarks WHERE parent IS NULL AND type=1 AND title='Root' LIMIT 1") { rootID = $0.text(0) }
        guard let rootID else { throw ReadError.unsupportedSchema("no Root folder") }
        var raw: [(id: String, title: String?, uuid: String?)] = []
        try db.query("SELECT id, title, external_uuid FROM bookmarks WHERE parent=? AND type=1 AND subtype=0 "
                     + "AND deleted=0 AND hidden=0 ORDER BY order_index, id", [rootID]) { r in
            raw.append((r.text(0) ?? "", r.text(1), r.text(2)))
        }
        var groups: [TabGroup] = []
        for g in raw {
            var tabs: [Tab] = []
            var pinnedDirs: [String] = []
            try db.query("SELECT id FROM bookmarks WHERE parent=? AND type=1 AND subtype=1 AND deleted=0", [g.id]) {
                pinnedDirs.append($0.text(0) ?? "")
            }
            for pid in pinnedDirs {
                tabs += try groupTabs(db, pid).map { var t = $0; t.pinned = true; return t }
            }
            tabs += try groupTabs(db, g.id)
            if !tabs.isEmpty {
                let title = g.title.flatMap { $0.isEmpty ? nil : $0 } ?? "Untitled group"
                groups.append(TabGroup(id: g.uuid.flatMap { $0.isEmpty ? nil : $0 } ?? g.id, title: title, tabs: tabs))
            }
        }
        return groups
    }

    static func groupTabs(_ db: SQLiteDB, _ parent: String) throws -> [Tab] {
        var out: [Tab] = []
        try db.query("SELECT title, url, external_uuid FROM bookmarks WHERE parent=? AND type=0 AND deleted=0 "
                     + "AND url IS NOT NULL AND url != '' ORDER BY order_index, id", [parent]) { r in
            let url = r.text(1) ?? ""
            out.append(Tab(id: r.text(2), title: r.text(0).flatMap { $0.isEmpty ? nil : $0 } ?? url, url: url))
        }
        return out
    }
}
