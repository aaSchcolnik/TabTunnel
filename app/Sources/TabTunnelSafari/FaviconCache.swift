import CryptoKit
import Foundation

/// Safari's own favicon cache: `favicons.db` maps page URLs to icon UUIDs, and the icon files live in
/// `favicons/`, named by a hash. The naming scheme isn't documented, so it's learned from the files that exist.
/// Only files that really exist in that folder are ever opened. Bytes are returned as stored; decoding
/// happens in the app, never in the process that holds Full Disk Access.
public final class SafariFaviconCache {
    private let dirs: [String]
    private let lock = NSLock()
    private var signature: FileSignature?
    private var dir: String?
    private var pages: [String: String] = [:]   // page url -> icon uuid
    private var hosts: [String: String] = [:]   // host -> best icon uuid
    private var icons: [String: String] = [:]   // uuid -> icon url
    private var files: [String: String] = [:]   // lowercased file name -> real name
    private var firstPage: [String: String] = [:]

    public init(dirs: [String]) { self.dirs = dirs }

    private static let schemes: [(String, String, String) -> String] = [
        { icon, _, _ in md5(icon) },
        { _, uuid, _ in uuid.replacingOccurrences(of: "-", with: "") },
        { _, uuid, _ in uuid },
        { icon, _, _ in Insecure.SHA1.hash(data: Data(icon.utf8)).map { String(format: "%02x", $0) }.joined() },
        { _, uuid, _ in md5(uuid) },
        { _, _, page in md5(page) },
    ]

    private static func md5(_ s: String) -> String {
        Insecure.MD5.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Rebuilds the index only when favicons.db changed.
    private func refreshIndex() {
        guard let dir = dirs.first(where: { FileManager.default.fileExists(atPath: $0 + "/favicons.db") }) else { return }
        let sig = try? FileSignature.of([dir + "/favicons.db"])
        if sig != nil, sig == signature, dir == self.dir { return }
        signature = sig
        self.dir = dir
        guard sig != nil, let db = try? SafariData.loadPrivate(dir + "/favicons.db") else { return }
        var icons: [String: (String, Double)] = [:]
        var pages: [String: String] = [:], hosts: [String: String] = [:], firstPage: [String: String] = [:]
        try? db.query("SELECT uuid, url, width FROM icon_info") { r in
            if let u = r.text(0), let url = r.text(1) { icons[u] = (url, r.double(2) ?? 0) }
        }
        try? db.query("SELECT url, uuid FROM page_url") { r in
            guard let page = r.text(0), let uuid = r.text(1), let icon = icons[uuid] else { return }
            pages[page] = uuid
            if firstPage[uuid] == nil { firstPage[uuid] = page }
            let h = Self.host(page)
            if !h.isEmpty, hosts[h] == nil || icon.1 > (icons[hosts[h]!]?.1 ?? 0) { hosts[h] = uuid }
        }
        var files: [String: String] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir + "/favicons")) ?? [] {
            files[name.lowercased()] = name
        }
        self.pages = pages
        self.hosts = hosts
        self.icons = icons.mapValues { $0.0 }
        self.firstPage = firstPage
        self.files = files
    }

    public static func host(_ url: String) -> String {
        guard let c = URLComponents(string: url), let scheme = c.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let h = c.host?.lowercased() else { return "" }
        return h.hasPrefix("www.") ? String(h.dropFirst(4)) : h
    }

    /// The stored icon for a page (exact URL, then without the trailing slash, then the best icon for its host).
    public func icon(forPage page: String) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        refreshIndex()
        guard let dir else { return nil }
        let trimmed = page.hasSuffix("/") ? String(page.dropLast()) : page
        guard let uuid = pages[page] ?? pages[trimmed] ?? hosts[Self.host(page)], let iconURL = icons[uuid] else { return nil }
        for scheme in Self.schemes {
            guard let name = files[scheme(iconURL, uuid, firstPage[uuid] ?? "").lowercased()] else { continue }
            let path = dir + "/favicons/" + name
            let fd = open(path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            let data = (try? handle.read(upToCount: 4 * 1024 * 1024 + 1)) ?? nil
            if let data, !data.isEmpty, data.count <= 4 * 1024 * 1024 { return data }
        }
        return nil
    }
}
