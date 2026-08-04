import CryptoKit
import Foundation

/// Port of apps/web/server.js helpers: SHA-256 / MD5 (lowercase hex).
///
/// MD5 is retained only for the legacy `passwordMD5` API field. It must not
/// be used for security-sensitive hashing; use `sha256Hex` for new code.
enum Hashing {
    static func sha256Hex(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func md5Hex(_ string: String) -> String {
        let digest = Insecure.MD5.hash(data: Data(string.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
