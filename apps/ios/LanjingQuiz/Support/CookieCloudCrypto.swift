import CommonCrypto
import CryptoKit
import Foundation

/// Swift port of apps/web/lib/cookiecloud.js: encryption compatible with the
/// official CookieCloud browser extension (github.com/easychen/CookieCloud).
///
///   the_key = MD5(`${uuid}-${password}`).hex.prefix(16)   // 16-char string
///
///   legacy:   OpenSSL EVP_BytesToKey (MD5) -> AES-256-CBC, random 8-byte
///             salt, PKCS7; payload is base64("Salted__" + salt + ciphertext)
///   fixed:    AES-128-CBC, key = UTF-8 bytes of the_key, zero IV, PKCS7;
///             payload is raw base64 ciphertext
///
/// We always push with "aes-128-cbc-fixed" and decrypt either type. Decryption
/// fails closed: a missing "Salted__" header, an unknown crypto type or a bad
/// password (PKCS7 padding error) throws instead of returning garbage.
enum CookieCloudCrypto {
    enum Error: Swift.Error, LocalizedError {
        case unsupportedCryptoType(String)
        case missingSaltedHeader
        case invalidCiphertext
        case invalidPlaintext

        var errorDescription: String? {
            switch self {
            case .unsupportedCryptoType(let type): "cookiecloud: unsupported crypto_type \(type)"
            case .missingSaltedHeader: "cookiecloud: legacy payload is missing the Salted__ header"
            case .invalidCiphertext: "cookiecloud: failed to decrypt (bad password or payload)"
            case .invalidPlaintext: "cookiecloud: decrypted payload is not valid UTF-8"
            }
        }
    }

    private static let saltedPrefix = Data("Salted__".utf8)

    static func deriveKey(uuid: String, password: String) -> String {
        String(Hashing.md5Hex("\(uuid)-\(password)").prefix(16))
    }

    /// OpenSSL EVP_BytesToKey with MD5: D1=MD5(pass+salt), D2=MD5(D1+pass+salt),
    /// D3=MD5(D2+pass+salt); key = D1||D2 (32 B), iv = D3 (16 B).
    private static func evpBytesToKey(passphrase: String, salt: Data) -> (key: Data, iv: Data) {
        let pass = Data(passphrase.utf8)
        var previous = Data()
        var material = Data()
        while material.count < 48 {
            let digest = Insecure.MD5.hash(data: previous + pass + salt)
            let block = Data(digest)
            material.append(block)
            previous = block
        }
        return (key: material.prefix(32), iv: material.subdata(in: 32..<48))
    }

    private static func aesCBC(_ data: Data, key: Data, iv: Data, encrypt: Bool) throws -> Data {
        let operation = CCOperation(encrypt ? kCCEncrypt : kCCDecrypt)
        let capacity = data.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { inBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, key.count,
                            ivBytes.baseAddress,
                            inBytes.baseAddress, data.count,
                            outBytes.baseAddress, capacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Error.invalidCiphertext }
        return output.prefix(outputLength)
    }

    private static func randomSalt() -> Data {
        Data((0..<8).map { _ in UInt8.random(in: .min ... .max) })
    }

    static func legacyEncrypt(_ data: String, key: String, salt: Data = CookieCloudCrypto.randomSalt()) -> String {
        let derived = evpBytesToKey(passphrase: key, salt: salt)
        let ciphertext = try! aesCBC(Data(data.utf8), key: derived.key, iv: derived.iv, encrypt: true)
        return (saltedPrefix + salt + ciphertext).base64EncodedString()
    }

    static func legacyDecrypt(_ encrypted: String, key: String) throws -> String {
        guard let payload = Data(base64Encoded: encrypted),
              payload.count >= saltedPrefix.count + 8,
              payload.prefix(saltedPrefix.count) == saltedPrefix
        else { throw Error.missingSaltedHeader }
        let salt = payload[saltedPrefix.count..<(saltedPrefix.count + 8)]
        let ciphertext = payload[(saltedPrefix.count + 8)...]
        let derived = evpBytesToKey(passphrase: key, salt: Data(salt))
        let plaintext = try aesCBC(Data(ciphertext), key: derived.key, iv: derived.iv, encrypt: false)
        guard let text = String(data: plaintext, encoding: .utf8) else { throw Error.invalidPlaintext }
        return text
    }

    static func fixedEncrypt(_ data: String, key: String) -> String {
        let ciphertext = try! aesCBC(Data(data.utf8), key: Data(key.utf8), iv: Data(count: 16), encrypt: true)
        return ciphertext.base64EncodedString()
    }

    static func fixedDecrypt(_ encrypted: String, key: String) throws -> String {
        guard let ciphertext = Data(base64Encoded: encrypted) else { throw Error.invalidCiphertext }
        let plaintext = try aesCBC(ciphertext, key: Data(key.utf8), iv: Data(count: 16), encrypt: false)
        guard let text = String(data: plaintext, encoding: .utf8) else { throw Error.invalidPlaintext }
        return text
    }

    static func encrypt(_ data: String, uuid: String, password: String, cryptoType: String = "aes-128-cbc-fixed") throws -> String {
        let key = deriveKey(uuid: uuid, password: password)
        switch cryptoType {
        case "aes-128-cbc-fixed": return fixedEncrypt(data, key: key)
        case "legacy": return legacyEncrypt(data, key: key)
        default: throw Error.unsupportedCryptoType(cryptoType)
        }
    }

    /// Missing crypto_type defaults to "legacy" (the extension's default
    /// writer); anything else fails closed.
    static func decrypt(_ encrypted: String, uuid: String, password: String, cryptoType: String = "legacy") throws -> String {
        let key = deriveKey(uuid: uuid, password: password)
        switch cryptoType {
        case "aes-128-cbc-fixed": return try fixedDecrypt(encrypted, key: key)
        case "legacy": return try legacyDecrypt(encrypted, key: key)
        default: throw Error.unsupportedCryptoType(cryptoType)
        }
    }
}
