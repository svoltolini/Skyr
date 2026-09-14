import CryptoKit
import Foundation

/// BLAKE2b (RFC 7693), unkeyed. Noise's hash in DSM's sign-in handshake; CryptoKit has no BLAKE2.
nonisolated enum Blake2b {
    static let outputLength = 64
    static let blockLength = 128

    private static let iv: [UInt64] = [
        0x6a09_e667_f3bc_c908, 0xbb67_ae85_84ca_a73b, 0x3c6e_f372_fe94_f82b, 0xa54f_f53a_5f1d_36f1,
        0x510e_527f_ade6_82d1, 0x9b05_688c_2b3e_6c1f, 0x1f83_d9ab_fb41_bd6b, 0x5be0_cd19_137e_2179,
    ]
    private static let sigma: [[Int]] = [
        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15],
        [14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3],
        [11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4],
        [7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8],
        [9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13],
        [2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9],
        [12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11],
        [13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10],
        [6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5],
        [10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0],
    ]

    static func hash(_ message: Data) -> Data {
        var h = iv
        h[0] ^= 0x0101_0000 ^ UInt64(outputLength)
        let bytes = [UInt8](message)
        var counter: UInt64 = 0
        var offset = 0
        while bytes.count - offset > blockLength {
            counter += UInt64(blockLength)
            compress(&h, Array(bytes[offset..<offset + blockLength]), counter: counter, last: false)
            offset += blockLength
        }
        let remaining = Array(bytes[offset...])
        counter += UInt64(remaining.count)
        compress(&h, remaining + [UInt8](repeating: 0, count: blockLength - remaining.count), counter: counter, last: true)
        var out = Data(capacity: outputLength)
        for word in h {
            var little = word.littleEndian
            out.append(Data(bytes: &little, count: 8))
        }
        return out
    }

    /// HMAC over BLAKE2b with its 128-byte block, as Noise's HKDF needs.
    static func hmac(key: Data, message: Data) -> Data {
        var padded = [UInt8](key.count > blockLength ? hash(key) : key)
        padded += [UInt8](repeating: 0, count: blockLength - padded.count)
        let inner = hash(Data(padded.map { $0 ^ 0x36 }) + message)
        return hash(Data(padded.map { $0 ^ 0x5c }) + inner)
    }

    private static func compress(_ h: inout [UInt64], _ block: [UInt8], counter: UInt64, last: Bool) {
        var m = [UInt64](repeating: 0, count: 16)
        for i in 0..<16 {
            var word: UInt64 = 0
            for j in 0..<8 { word |= UInt64(block[i * 8 + j]) << (8 * UInt64(j)) }
            m[i] = word
        }
        var v = h + iv
        v[12] ^= counter
        if last { v[14] = ~v[14] }
        func mix(_ a: Int, _ b: Int, _ c: Int, _ d: Int, _ x: UInt64, _ y: UInt64) {
            v[a] = v[a] &+ v[b] &+ x
            v[d] = (v[d] ^ v[a]).rotated(right: 32)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotated(right: 24)
            v[a] = v[a] &+ v[b] &+ y
            v[d] = (v[d] ^ v[a]).rotated(right: 16)
            v[c] = v[c] &+ v[d]
            v[b] = (v[b] ^ v[c]).rotated(right: 63)
        }
        for round in 0..<12 {
            let s = sigma[round % 10]
            mix(0, 4, 8, 12, m[s[0]], m[s[1]])
            mix(1, 5, 9, 13, m[s[2]], m[s[3]])
            mix(2, 6, 10, 14, m[s[4]], m[s[5]])
            mix(3, 7, 11, 15, m[s[6]], m[s[7]])
            mix(0, 5, 10, 15, m[s[8]], m[s[9]])
            mix(1, 6, 11, 12, m[s[10]], m[s[11]])
            mix(2, 7, 8, 13, m[s[12]], m[s[13]])
            mix(3, 4, 9, 14, m[s[14]], m[s[15]])
        }
        for i in 0..<8 { h[i] ^= v[i] ^ v[i + 8] }
    }
}

private nonisolated extension UInt64 {
    func rotated(right bits: UInt64) -> UInt64 { (self >> bits) | (self << (64 - bits)) }
}

/// DSM 7.2's web sign-in handshake: Noise_IK_25519_ChaChaPoly_BLAKE2b against the NAS's key from
/// its `_SSID` cookie. A session signed in this way may run administration calls; each request then
/// carries an `X-SYNO-HASH` header derived from the handshake, which is what the DSM interface sends.
public nonisolated final class NoiseSession: @unchecked Sendable, Hashable {
    public enum Failure: Error { case badKey, badMessage, notFinished }

    private let lock = NSLock()
    private let staticKey = Curve25519.KeyAgreement.PrivateKey()
    private let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
    private let remoteStatic: Curve25519.KeyAgreement.PublicKey
    private var h: Data
    private var ck: Data
    private var k: Data?
    private var n: UInt64 = 0
    private var sendKey: Data?
    private var sendNonce: UInt64 = 0
    private var handshakeHash: Data?

    public init(remoteStaticKey: Data) throws {
        guard remoteStaticKey.count == 32, let remote = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteStaticKey) else {
            throw Failure.badKey
        }
        remoteStatic = remote
        var name = Data("Noise_IK_25519_ChaChaPoly_BLAKE2b".utf8)
        name.append(Data(count: Blake2b.outputLength - name.count))
        h = name
        ck = name
        mixHash(Data())                       // empty prologue
        mixHash(remote.rawRepresentation)     // IK pre-message: the responder's static key
    }

    /// The initiator's message: `e, es, s, ss` and the payload. Base64url as DSM's `ik_message`.
    public func firstMessage(payload: Data) throws -> Data {
        lock.lock(); defer { lock.unlock() }
        var message = ephemeralKey.publicKey.rawRepresentation
        mixHash(message)
        try mixKey(dh(ephemeralKey, remoteStatic))
        message += try encryptAndHash(staticKey.publicKey.rawRepresentation)
        try mixKey(dh(staticKey, remoteStatic))
        message += try encryptAndHash(payload)
        return message
    }

    /// The responder's answer: `e, ee, se` and its payload; afterwards the transport keys exist.
    public func finish(with response: Data) throws {
        lock.lock(); defer { lock.unlock() }
        guard response.count >= 32 + 16 else { throw Failure.badMessage }
        let remoteEphemeralData = response.prefix(32)
        guard let remoteEphemeral = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: remoteEphemeralData) else { throw Failure.badMessage }
        mixHash(remoteEphemeralData)
        try mixKey(dh(ephemeralKey, remoteEphemeral))
        try mixKey(dh(staticKey, remoteEphemeral))
        _ = try decryptAndHash(response.dropFirst(32))
        let (first, _) = hkdf(ck, Data())
        sendKey = first.prefix(32)
        handshakeHash = h
    }

    /// The value for `X-SYNO-HASH`: the handshake's fingerprint, a proof made with the send key, and the counter.
    public func requestHash() -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let sendKey, let handshakeHash else { return nil }
        let nonce = sendNonce
        guard let proof = try? encrypt(key: sendKey, nonce: nonce, ad: Data(), plaintext: Data()) else { return nil }
        sendNonce += 1
        return String(Self.base64url(handshakeHash).prefix(8)) + Self.base64url(proof) + "." + Self.base64url(Data(String(nonce).utf8))
    }

    public var isFinished: Bool {
        lock.lock(); defer { lock.unlock() }
        return handshakeHash != nil
    }

    // MARK: Noise primitives

    private func mixHash(_ data: Data) {
        h = Blake2b.hash(h + data)
    }

    private func mixKey(_ input: Data) throws {
        let (chaining, temp) = hkdf(ck, input)
        ck = chaining
        k = temp.prefix(32)
        n = 0
    }

    private func hkdf(_ chainingKey: Data, _ input: Data) -> (Data, Data) {
        let temp = Blake2b.hmac(key: chainingKey, message: input)
        let first = Blake2b.hmac(key: temp, message: Data([0x01]))
        let second = Blake2b.hmac(key: temp, message: first + Data([0x02]))
        return (first, second)
    }

    private func encryptAndHash(_ plaintext: Data) throws -> Data {
        guard let k else { throw Failure.notFinished }
        let ciphertext = try encrypt(key: k, nonce: n, ad: h, plaintext: plaintext)
        mixHash(ciphertext)
        n += 1
        return ciphertext
    }

    private func decryptAndHash(_ ciphertext: Data) throws -> Data {
        guard let k, ciphertext.count >= 16 else { throw Failure.badMessage }
        let box = try ChaChaPoly.SealedBox(nonce: Self.nonce(n), ciphertext: ciphertext.dropLast(16), tag: ciphertext.suffix(16))
        let plaintext = try ChaChaPoly.open(box, using: SymmetricKey(data: k), authenticating: h)
        mixHash(Data(ciphertext))
        n += 1
        return plaintext
    }

    private func encrypt(key: Data, nonce: UInt64, ad: Data, plaintext: Data) throws -> Data {
        let sealed = try ChaChaPoly.seal(plaintext, using: SymmetricKey(data: key), nonce: Self.nonce(nonce), authenticating: ad)
        return sealed.ciphertext + sealed.tag
    }

    private func dh(_ key: Curve25519.KeyAgreement.PrivateKey, _ peer: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        let secret = try key.sharedSecretFromKeyAgreement(with: peer)
        return secret.withUnsafeBytes { Data($0) }
    }

    /// Noise's 96-bit nonce: four zero bytes, then the counter little-endian.
    private static func nonce(_ n: UInt64) throws -> ChaChaPoly.Nonce {
        var little = n.littleEndian
        return try ChaChaPoly.Nonce(data: Data(count: 4) + Data(bytes: &little, count: 8))
    }

    // MARK: Encoding

    /// Base64url without padding, the form DSM uses for its `_SSID` cookie and `ik_message`.
    public static func base64url(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    public static func data(base64url text: String) -> Data? {
        var base64 = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        return Data(base64Encoded: base64)
    }

    public static func == (lhs: NoiseSession, rhs: NoiseSession) -> Bool { lhs === rhs }
    public func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
}
