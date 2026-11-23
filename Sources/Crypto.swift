import Foundation
import CryptoKit
import Security
import LocalAuthentication

// Log encryption.
//
// Rows are sealed to an X25519 public key (in config.json), so the logger can write rows but
// can't read them back. The matching private key is stored only in wrapped form (key.json),
// encrypted to a key that lives inside this Mac's Secure Enclave and that the Enclave refuses
// to use without Touch ID or the login password. So decrypting takes your presence, enforced
// by hardware and not by a check in this program, and the files are useless on another Mac.
//
// Each row is sealed on its own with HPKE (X25519, HKDF-SHA256, ChaCha20-Poly1305), bound to
// its day so rows can't be moved between files, and written as one base64 line: 32 bytes of
// encapsulated key followed by the ciphertext.

enum LogCrypto {
    static let info = Data("activity-logger/v1".utf8)
    static let suite = HPKE.Ciphersuite.Curve25519_SHA256_ChachaPoly
    static let encapsulatedKeyLength = 32
    /// Rows are padded with spaces to a multiple of this, so a row's size says little about its title or URL.
    static let padBlock = 128

    struct Malformed: Error {}

    static func publicKey(base64: String) -> Curve25519.KeyAgreement.PublicKey? {
        guard let raw = Data(base64Encoded: base64) else { return nil }
        return try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: raw)
    }

    static func padded(_ row: Data) -> Data {
        var out = Data(row)
        let extra = out.count % padBlock
        if extra != 0 { out.append(contentsOf: [UInt8](repeating: 0x20, count: padBlock - extra)) }
        return out
    }

    static func unpadded(_ row: Data) -> Data {
        var bytes = [UInt8](row)
        while bytes.last == 0x20 { bytes.removeLast() }
        return Data(bytes)
    }

    /// One row in, one base64 line out (no trailing newline). `day` is the file's YYYY-MM-DD.
    static func encryptLine(_ row: Data, day: String, to key: Curve25519.KeyAgreement.PublicKey) throws -> Data {
        var sender = try HPKE.Sender(recipientKey: key, ciphersuite: suite, info: info)
        let sealed = try sender.seal(padded(row), authenticating: Data(day.utf8))
        return (sender.encapsulatedKey + sealed).base64EncodedData()
    }

    static func decryptLine(_ line: Data, day: String, with key: Curve25519.KeyAgreement.PrivateKey) throws -> Data {
        guard let raw = Data(base64Encoded: line), raw.count > encapsulatedKeyLength else { throw Malformed() }
        let enc = Data(raw.prefix(encapsulatedKeyLength))
        let sealed = Data(raw.dropFirst(encapsulatedKeyLength))
        var recipient = try HPKE.Recipient(privateKey: key, ciphersuite: suite, info: info, encapsulatedKey: enc)
        return unpadded(try recipient.open(sealed, authenticating: Data(day.utf8)))
    }
}

/// key.json: the log key's public half, and its private half wrapped to a Secure Enclave key.
struct KeyVault: Codable {
    var version = 1
    var publicKey: String
    /// The Secure Enclave key, as the opaque blob only this Mac's Enclave can use.
    var enclaveKey: String
    /// Ephemeral P-256 public key (65 bytes) followed by the ChaCha20-Poly1305 box holding the log private key.
    var wrappedPrivateKey: String

    enum CodingKeys: String, CodingKey {
        case version
        case publicKey = "public_key"
        case enclaveKey = "enclave_key"
        case wrappedPrivateKey = "wrapped_private_key"
    }

    struct VaultError: Error, CustomStringConvertible {
        let description: String
    }

    static let ephemeralKeyLength = 65
    static var file: URL { Paths.logDir.appendingPathComponent("key.json") }

    static func load(from url: URL = KeyVault.file) -> KeyVault? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(KeyVault.self, from: data)
    }

    func save(to url: URL = KeyVault.file) throws {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try enc.encode(self).write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private static func wrappingKey(_ shared: SharedSecret, ephemeral: Data, enclave: Data) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + enclave,
                                       sharedInfo: Data("activity-logger/key-wrap/v1".utf8), outputByteCount: 32)
    }

    /// Makes a new log key and wraps it. `requirePresence` is false only in the self-test, which
    /// has to run without a Touch ID prompt.
    static func create(requirePresence: Bool = true) throws -> KeyVault {
        guard SecureEnclave.isAvailable else {
            throw VaultError(description: "This Mac has no Secure Enclave (it needs Apple silicon or a T2 chip), which the log encryption relies on.")
        }
        var flags: SecAccessControlCreateFlags = [.privateKeyUsage]
        if requirePresence { flags.insert(.userPresence) }
        var cfError: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, flags, &cfError) else {
            throw VaultError(description: "Couldn't set up the key's access rule: \(String(describing: cfError?.takeRetainedValue()))")
        }
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: access)
        let logKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let ephemeralPublic = ephemeral.publicKey.x963Representation
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: enclave.publicKey)
        let key = wrappingKey(shared, ephemeral: ephemeralPublic, enclave: enclave.publicKey.x963Representation)
        let box = try ChaChaPoly.seal(logKey.rawRepresentation, using: key)
        return KeyVault(publicKey: logKey.publicKey.rawRepresentation.base64EncodedString(),
                        enclaveKey: enclave.dataRepresentation.base64EncodedString(),
                        wrappedPrivateKey: (ephemeralPublic + box.combined).base64EncodedString())
    }

    /// Unwraps the log private key. macOS asks for Touch ID or the login password here.
    func unlock(reason: String) throws -> Curve25519.KeyAgreement.PrivateKey {
        guard let blob = Data(base64Encoded: enclaveKey), let wrapped = Data(base64Encoded: wrappedPrivateKey),
              wrapped.count > KeyVault.ephemeralKeyLength else {
            throw VaultError(description: "key.json is damaged.")
        }
        let context = LAContext()
        context.localizedReason = reason
        let enclave = try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: blob, authenticationContext: context)
        let ephemeralPublic = Data(wrapped.prefix(KeyVault.ephemeralKeyLength))
        let shared = try enclave.sharedSecretFromKeyAgreement(with: P256.KeyAgreement.PublicKey(x963Representation: ephemeralPublic))
        let key = KeyVault.wrappingKey(shared, ephemeral: ephemeralPublic, enclave: enclave.publicKey.x963Representation)
        let box = try ChaChaPoly.SealedBox(combined: Data(wrapped.dropFirst(KeyVault.ephemeralKeyLength)))
        let logKey = try Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ChaChaPoly.open(box, using: key))
        guard logKey.publicKey.rawRepresentation.base64EncodedString() == publicKey else {
            throw VaultError(description: "key.json is inconsistent: the unwrapped key doesn't match its public half.")
        }
        return logKey
    }
}
