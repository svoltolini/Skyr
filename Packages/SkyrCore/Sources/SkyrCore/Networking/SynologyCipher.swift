import CommonCrypto
import CryptoKit
import Foundation
import Security

/// What DSM's `SYNO.API.Encryption` hands out: the field name for sealed parameters, a token that
/// must travel inside the sealed payload, the NAS's RSA public key (hex modulus) and its clock.
public nonisolated struct SynologyEncryptionInfo: Decodable, Sendable {
    public let cipherkey: String
    public let ciphertoken: String
    public let publicKey: String
    public let serverTime: String

    private enum CodingKeys: String, CodingKey { case cipherkey, ciphertoken, publicKey, serverTime }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        cipherkey = try container.decode(String.self, forKey: .cipherkey)
        ciphertoken = try container.decode(String.self, forKey: .ciphertoken)
        publicKey = try container.decode(String.self, forKey: .publicKey)
        if let number = try? container.decode(Int.self, forKey: .serverTime) {
            serverTime = String(number)
        } else {
            serverTime = try container.decode(String.self, forKey: .serverTime)
        }
    }
}

/// DSM's request encryption, as the DSM web interface applies it to passwords: a random passphrase
/// sealed with the NAS's RSA public key, and the secret fields encrypted with that passphrase using
/// OpenSSL-style AES-256-CBC. User administration expects passwords to arrive this way.
public nonisolated enum SynologyCipher {
    public enum Failure: Error { case badKey, sealFailed, encryptFailed }

    /// The JSON value DSM expects under `info.cipherkey`, carrying `secrets` and the cipher token.
    public static func seal(_ secrets: [String: String], with info: SynologyEncryptionInfo) throws -> String {
        let modulus = try hexData(info.publicKey)
        let key = try publicKey(modulus: modulus)
        // PKCS#1 v1.5 leaves modulus length minus 11 bytes for the message; DSM's own client uses 501 with its 4096-bit key.
        let passphrase = randomPassphrase(length: max(16, min(501, modulus.count - 11)))
        var fields = secrets
        fields[info.ciphertoken] = info.serverTime
        let query = fields.map { "\(formEncoded($0.key))=\(formEncoded($0.value))" }.joined(separator: "&")
        let aes = try aesEncrypt(Data(query.utf8), passphrase: Data(passphrase.utf8))
        var error: Unmanaged<CFError>?
        guard let rsa = SecKeyCreateEncryptedData(key, .rsaEncryptionPKCS1, Data(passphrase.utf8) as CFData, &error) as Data? else {
            throw Failure.sealFailed
        }
        return "{\"rsa\":\"\(rsa.base64EncodedString())\",\"aes\":\"\(aes.base64EncodedString())\"}"
    }

    // MARK: Pieces

    private static func randomPassphrase(length: Int) -> String {
        let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ~!@#$%^&*()_+-/")
        return String((0..<length).map { _ in alphabet.randomElement()! })
    }

    /// `application/x-www-form-urlencoded` as DSM decodes it: letters, digits, `_.-~` as is, space as `+`.
    private static func formEncoded(_ value: String) -> String {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_.-~ ")
        return (value.addingPercentEncoding(withAllowedCharacters: safe) ?? value).replacingOccurrences(of: " ", with: "+")
    }

    private static func hexData(_ hex: String) throws -> Data {
        var text = hex.filter { !$0.isWhitespace }
        if text.count % 2 == 1 { text = "0" + text }
        var data = Data(capacity: text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { throw Failure.badKey }
            data.append(byte)
            index = next
        }
        // A leading zero byte is DER's sign padding, not part of the modulus.
        while data.count > 1, data[data.startIndex] == 0 { data.removeFirst() }
        return data
    }

    /// An RSA public key from its modulus and the usual exponent 65537, as PKCS#1 DER.
    private static func publicKey(modulus: Data) throws -> SecKey {
        let sequence = derInteger(modulus) + derInteger(Data([0x01, 0x00, 0x01]))
        let der = Data([0x30]) + derLength(sequence.count) + sequence
        let attributes: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass: kSecAttrKeyClassPublic,
            kSecAttrKeySizeInBits: modulus.count * 8,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) else { throw Failure.badKey }
        return key
    }

    private static func derInteger(_ value: Data) -> Data {
        var bytes = value
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: bytes.startIndex) }
        return Data([0x02]) + derLength(bytes.count) + bytes
    }

    private static func derLength(_ length: Int) -> Data {
        if length < 0x80 { return Data([UInt8(length)]) }
        var remaining = length
        var bytes: [UInt8] = []
        while remaining > 0 {
            bytes.insert(UInt8(remaining & 0xff), at: 0)
            remaining >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)]) + Data(bytes)
    }

    /// OpenSSL's `enc -aes-256-cbc -md md5` layout: "Salted__", 8 salt bytes, then the ciphertext,
    /// with key and IV from one-round EVP_BytesToKey.
    private static func aesEncrypt(_ plaintext: Data, passphrase: Data) throws -> Data {
        var salt = Data(count: 8)
        let saltStatus = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 8, $0.baseAddress!) }
        guard saltStatus == errSecSuccess else { throw Failure.encryptFailed }
        var derived = Data()
        var previous = Data()
        while derived.count < 48 {
            previous = Data(Insecure.MD5.hash(data: previous + passphrase + salt))
            derived += previous
        }
        let key = Data(derived[0..<32])
        let iv = Data(derived[32..<48])
        var output = Data(count: plaintext.count + kCCBlockSizeAES128)
        var moved = 0
        let status = key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                plaintext.withUnsafeBytes { inBytes in
                    output.withUnsafeMutableBytes { outBytes in
                        CCCrypt(
                            CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress, kCCKeySizeAES256, ivBytes.baseAddress,
                            inBytes.baseAddress, plaintext.count, outBytes.baseAddress, outBytes.count, &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw Failure.encryptFailed }
        return Data("Salted__".utf8) + salt + output.prefix(moved)
    }
}
