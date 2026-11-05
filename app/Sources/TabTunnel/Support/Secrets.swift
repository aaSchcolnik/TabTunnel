import AppKit
import Foundation
import Security

/// The relay token and the Zen feed secret, kept in your login keychain. A keychain item created by TabTunnel can
/// be read without a prompt only by TabTunnel itself (macOS checks its code signature); any other program gets a
/// password prompt. They're never put in a URL, the environment, a log or a plist.
///
/// Files left by earlier TabTunnel builds are moved into the keychain and deleted.
enum Secrets {
    static let service = "dev.tabtunnel.TabTunnel"
    static let dir = NSHomeDirectory() + "/Library/Application Support/TabTunnel"

    enum Failure: Error, LocalizedError {
        case keychain(OSStatus)
        var errorDescription: String? {
            if case .keychain(let s) = self { return SecCopyErrorMessageString(s, nil) as String? ?? "Keychain error \(s)" }
            return nil
        }
    }

    static func ensureDir() {
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        chmod(dir, 0o700)
    }

    /// Reads a secret, migrating or creating it if needed. Throws only if it can't be stored.
    static func load(_ name: String) throws -> String {
        if let s = keychainRead(name), s.count >= 32 { return s }
        // Older TabTunnel builds kept a 0600 file; move it into the keychain and delete the file.
        let ownFile = dir + "/" + name
        if let s = readFile(ownFile), s.count >= 32 {
            try keychainWrite(name, s)
            unlink(ownFile)
            return s
        }
        let fresh = random()
        try keychainWrite(name, fresh)
        return fresh
    }

    /// A new secret, returned only once it's stored (so a failed save never leaves the app using a value that
    /// would vanish at the next launch).
    static func rotate(_ name: String) throws -> String {
        let fresh = random()
        try keychainWrite(name, fresh)
        return fresh
    }

    static func random() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            fatalError("no secure random source")
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: keychain

    private static func query(_ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: name]
    }

    static func keychainRead(_ name: String) -> String? {
        var q = query(name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func keychainWrite(_ name: String, _ value: String) throws {
        let data = Data(value.utf8)
        let update = SecItemUpdate(query(name) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if update == errSecSuccess { return }
        guard update == errSecItemNotFound else { throw Failure.keychain(update) }
        var add = query(name)
        add[kSecValueData as String] = data
        add[kSecAttrLabel as String] = name == "token" ? "TabTunnel relay token" : "TabTunnel feed secret"
        add[kSecAttrDescription as String] = "TabTunnel"
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw Failure.keychain(status) }
    }

    // MARK: files (migration from earlier builds)

    private static func readFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return nil }
        let h = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard let d = try? h.read(upToCount: 4096) else { return nil }
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: clipboard

    /// Puts a secret on this Mac's clipboard only (not Universal Clipboard), marked concealed so clipboard
    /// managers skip it, and clears it after 60 seconds unless something else was copied since.
    @MainActor
    static func copyConcealed(_ value: String) {
        let pb = NSPasteboard.general
        pb.prepareForNewContents(with: .currentHostOnly)
        pb.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
        pb.setString(value, forType: .string)
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        let count = pb.changeCount
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            if pb.changeCount == count { pb.clearContents() }
        }
    }
}
