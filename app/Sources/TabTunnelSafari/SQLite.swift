import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteError: Error, CustomStringConvertible {
    public let description: String
}

/// A minimal read-only SQLite wrapper. Every database it touches is a private in-memory copy.
public final class SQLiteDB {
    let handle: OpaquePointer

    private init(handle: OpaquePointer) { self.handle = handle }

    deinit { sqlite3_close_v2(handle) }

    /// Opens `path` read-only and copies it (with its WAL applied) into memory, then closes the file.
    public static func memoryCopy(ofFileAt path: String) throws -> SQLiteDB {
        var disk: OpaquePointer?
        let uri = "file:" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path) + "?mode=ro"
        guard sqlite3_open_v2(uri, &disk, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let disk else {
            let msg = disk.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(disk)
            throw SQLiteError(description: msg)
        }
        defer { sqlite3_close_v2(disk) }
        sqlite3_busy_timeout(disk, 2000) // Safari may be mid-write; wait briefly instead of failing
        var mem: OpaquePointer?
        guard sqlite3_open_v2(":memory:", &mem, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK, let mem else {
            sqlite3_close_v2(mem)
            throw SQLiteError(description: "memory open failed")
        }
        guard let backup = sqlite3_backup_init(mem, "main", disk, "main") else {
            let msg = String(cString: sqlite3_errmsg(mem))
            sqlite3_close_v2(mem)
            throw SQLiteError(description: msg)
        }
        let rc = sqlite3_backup_step(backup, -1)
        sqlite3_backup_finish(backup)
        guard rc == SQLITE_DONE else {
            sqlite3_close_v2(mem)
            throw SQLiteError(description: "backup failed (\(rc))")
        }
        return SQLiteDB(handle: mem)
    }

    public func query(_ sql: String, _ args: [String] = [], _ row: (Row) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(description: String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() { sqlite3_bind_text(stmt, Int32(i + 1), a, -1, SQLITE_TRANSIENT) }
        let r = Row(stmt: stmt)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(description: String(cString: sqlite3_errmsg(handle))) }
            try row(r)
        }
    }

    public func tables() throws -> [String] {
        var out: [String] = []
        try query("SELECT name FROM sqlite_master WHERE type='table' ORDER BY name") { out.append($0.text(0) ?? "") }
        return out
    }

    public func columns(_ table: String) throws -> [String] {
        var out: [String] = []
        try query("PRAGMA table_info(\"\(table.replacingOccurrences(of: "\"", with: "\"\""))\")") { out.append($0.text(1) ?? "") }
        return out
    }

    public struct Row {
        let stmt: OpaquePointer

        public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }

        public func text(_ i: Int32) -> String? {
            guard !isNull(i), let p = sqlite3_column_text(stmt, i) else { return nil }
            return String(cString: p)
        }

        public func double(_ i: Int32) -> Double? {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER, SQLITE_FLOAT: return sqlite3_column_double(stmt, i)
            case SQLITE_TEXT: return text(i).flatMap(Double.init)
            default: return nil
            }
        }

        public func int(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }

        public func bool(_ i: Int32) -> Bool { !isNull(i) && sqlite3_column_int64(stmt, i) != 0 }

        /// The raw value as bytes (BLOB or TEXT), or a number.
        public func value(_ i: Int32) -> SQLValue {
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_INTEGER, SQLITE_FLOAT: return .number(sqlite3_column_double(stmt, i))
            case SQLITE_BLOB:
                let n = Int(sqlite3_column_bytes(stmt, i))
                guard n > 0, let p = sqlite3_column_blob(stmt, i) else { return .bytes(Data()) }
                return .bytes(Data(bytes: p, count: n))
            case SQLITE_TEXT: return .bytes(Data((text(i) ?? "").utf8))
            default: return .null
            }
        }
    }
}

public enum SQLValue {
    case null
    case number(Double)
    case bytes(Data)
}
