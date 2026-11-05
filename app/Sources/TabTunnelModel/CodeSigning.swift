import CryptoKit
import Foundation
import Security

/// Builds the code-signing requirement each side of the XPC connection demands of the other:
/// signed like this process, and the exact bundle identifier of the expected peer.
/// So only TabTunnel's own signed app can ask the reader for tabs, and the app only trusts the real reader.
///
/// "Signed like this process" means:
/// - Apple-issued certificate (Apple Development, Developer ID): the same Apple team.
/// - Self-signed certificate (the downloadable release builds): the very same signing certificate, by SHA-1.
/// - Ad-hoc or unsigned: nothing. Such builds refuse XPC entirely (see the callers).
public enum CodeSigning {
    private static func signingInfo() -> [String: Any]? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { return nil }
        return info as? [String: Any]
    }

    /// The team identifier this process was signed with, or nil for self-signed, ad-hoc and unsigned builds.
    public static func ownTeamID() -> String? {
        signingInfo()?[kSecCodeInfoTeamIdentifier as String] as? String
    }

    /// SHA-1 (hex) of the leaf certificate this process was signed with, or nil for ad-hoc and unsigned builds.
    public static func ownLeafCertificateSHA1() -> String? {
        guard let certs = signingInfo()?[kSecCodeInfoCertificates as String] as? [SecCertificate], let leaf = certs.first
        else { return nil }
        let der = SecCertificateCopyData(leaf) as Data
        return Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined()
    }

    public static func requirement(forPeer identifier: String) -> String? {
        if let team = ownTeamID(), !team.isEmpty, team.allSatisfy({ $0.isLetter || $0.isNumber }) {
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\" and identifier \"\(identifier)\""
        }
        if let leaf = ownLeafCertificateSHA1() {
            return "certificate leaf = H\"\(leaf)\" and identifier \"\(identifier)\""
        }
        return nil
    }
}
