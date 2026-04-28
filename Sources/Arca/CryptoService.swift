import CryptoKit
import Foundation

enum CryptoError: Error, LocalizedError {
    case invalidBase64
    case invalidEnvelope
    case passwordVerificationFailed
    case unsupportedCipherSuite(String)
    case missingMasterPasswordConfiguration

    var errorDescription: String? {
        switch self {
        case .invalidBase64:
            return L10n.string("error.crypto.invalid_base64")
        case .invalidEnvelope:
            return L10n.string("error.crypto.invalid_envelope")
        case .passwordVerificationFailed:
            return L10n.string("error.crypto.password_incorrect")
        case .unsupportedCipherSuite(let suite):
            return L10n.format("error.crypto.unsupported_suite", suite)
        case .missingMasterPasswordConfiguration:
            return L10n.string("error.crypto.missing_master_password")
        }
    }
}

struct CryptoService {
    private enum CryptoSuite {
        static let cipher = "aes-256-gcm"
        static let keyLength = 32
    }

    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    init() {
        jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .iso8601
        jsonEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        jsonDecoder = JSONDecoder()
        jsonDecoder.dateDecodingStrategy = .iso8601
    }

    func makeVaultSecret() -> SymmetricKey {
        let secret = Data((0..<CryptoSuite.keyLength).map { _ in UInt8.random(in: .min ... .max) })
        return SymmetricKey(data: secret)
    }

    func makeVaultMetadata(
        vaultKey: SymmetricKey,
        includeMasterPassword password: String?,
        includeDeviceAuthentication: Bool
    ) throws -> VaultMetadata {
        var enabledModes: [VaultAuthenticationMode] = []
        var masterPasswordConfig: MasterPasswordAuthConfig?

        if let password {
            masterPasswordConfig = try makeMasterPasswordConfig(password: password, vaultKey: vaultKey)
            enabledModes.append(.masterPassword)
        }

        if includeDeviceAuthentication {
            enabledModes.append(.deviceAuthentication)
        }

        return VaultMetadata(
            formatVersion: FileFormatVersion.currentVaultMetadata,
            cipher: CryptoSuite.cipher,
            createdAt: Date(),
            enabledAuthModes: enabledModes,
            masterPassword: masterPasswordConfig,
            deviceAuthenticationEnabled: includeDeviceAuthentication
        )
    }

    func enablingMasterPassword(_ password: String, for vaultKey: SymmetricKey, metadata: VaultMetadata) throws -> VaultMetadata {
        var updated = metadata
        updated.masterPassword = try makeMasterPasswordConfig(password: password, vaultKey: vaultKey)
        if updated.enabledAuthModes.contains(.masterPassword) == false {
            updated.enabledAuthModes.append(.masterPassword)
        }
        return updated
    }

    func disablingMasterPassword(in metadata: VaultMetadata) -> VaultMetadata {
        var updated = metadata
        updated.masterPassword = nil
        updated.enabledAuthModes.removeAll { $0 == .masterPassword }
        return updated
    }

    func enablingDeviceAuthentication(in metadata: VaultMetadata) -> VaultMetadata {
        var updated = metadata
        updated.deviceAuthenticationEnabled = true
        if updated.enabledAuthModes.contains(.deviceAuthentication) == false {
            updated.enabledAuthModes.append(.deviceAuthentication)
        }
        return updated
    }

    func disablingDeviceAuthentication(in metadata: VaultMetadata) -> VaultMetadata {
        var updated = metadata
        updated.deviceAuthenticationEnabled = false
        updated.enabledAuthModes.removeAll { $0 == .deviceAuthentication }
        return updated
    }

    func unwrapVaultKey(password: String, vaultMetadata: VaultMetadata) throws -> SymmetricKey {
        try FileFormatVersion.validate(vaultMetadata.formatVersion, for: .vaultMetadata)
        try validateCipherSuite(vaultMetadata.cipher)
        guard let config = vaultMetadata.masterPassword else {
            throw CryptoError.missingMasterPasswordConfiguration
        }

        guard let salt = Data(base64Encoded: config.salt) else {
            throw CryptoError.invalidBase64
        }

        let derivedKey = deriveWrappingKey(password: password, salt: salt, iterations: config.iterations)
        let wrappedSecret = try openEnvelope(config.wrappedSecret, using: derivedKey)
        guard wrappedSecret.count == CryptoSuite.keyLength else {
            throw CryptoError.invalidEnvelope
        }

        return SymmetricKey(data: wrappedSecret)
    }

    func exportVaultSecret(_ vaultKey: SymmetricKey) -> String {
        vaultKey.withUnsafeBytes { Data($0).base64EncodedString() }
    }

    func importVaultSecret(_ encoded: String) throws -> SymmetricKey {
        guard let data = Data(base64Encoded: encoded), data.count == CryptoSuite.keyLength else {
            throw CryptoError.invalidBase64
        }
        return SymmetricKey(data: data)
    }

    func encrypt(note: NotePayload, using key: SymmetricKey) throws -> EncryptedNoteFile {
        let plainData = try jsonEncoder.encode(note)
        let sealedBox = try AES.GCM.seal(plainData, using: key)
        return EncryptedNoteFile(
            formatVersion: FileFormatVersion.currentNoteFile,
            noteID: note.noteID,
            cipher: CryptoSuite.cipher,
            nonce: sealedBox.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: sealedBox.ciphertext.base64EncodedString(),
            tag: sealedBox.tag.base64EncodedString()
        )
    }

    func decrypt(file: EncryptedNoteFile, using key: SymmetricKey) throws -> NotePayload {
        try FileFormatVersion.validate(file.formatVersion, for: .note)
        try validateCipherSuite(file.cipher)
        let nonceData = try decodeBase64(file.nonce)
        let ciphertext = try decodeBase64(file.ciphertext)
        let tag = try decodeBase64(file.tag)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        let decrypted = try AES.GCM.open(sealedBox, using: key)
        return try jsonDecoder.decode(NotePayload.self, from: decrypted)
    }

    func encoder() -> JSONEncoder {
        jsonEncoder
    }

    func decoder() -> JSONDecoder {
        jsonDecoder
    }

    private func makeMasterPasswordConfig(password: String, vaultKey: SymmetricKey) throws -> MasterPasswordAuthConfig {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let iterations = 210_000
        let derivedKey = deriveWrappingKey(password: password, salt: salt, iterations: iterations)
        let secretData = vaultKey.withUnsafeBytes { Data($0) }
        let envelope = try seal(secretData, using: derivedKey)

        return MasterPasswordAuthConfig(
            kdf: "pbkdf2-sha256",
            salt: salt.base64EncodedString(),
            iterations: iterations,
            wrappedSecret: envelope
        )
    }

    private func deriveWrappingKey(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let derived = pbkdf2SHA256(
            password: passwordData,
            salt: salt,
            iterations: iterations,
            keyLength: CryptoSuite.keyLength
        )
        return SymmetricKey(data: derived)
    }

    private func seal(_ plaintext: Data, using key: SymmetricKey) throws -> KeyCheckEnvelope {
        let seal = try AES.GCM.seal(plaintext, using: key)
        return KeyCheckEnvelope(
            nonce: seal.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertext: seal.ciphertext.base64EncodedString(),
            tag: seal.tag.base64EncodedString()
        )
    }

    private func openEnvelope(_ envelope: KeyCheckEnvelope, using key: SymmetricKey) throws -> Data {
        let nonceData = try decodeBase64(envelope.nonce)
        let ciphertext = try decodeBase64(envelope.ciphertext)
        let tag = try decodeBase64(envelope.tag)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        return try AES.GCM.open(sealedBox, using: key)
    }

    private func decodeBase64(_ string: String) throws -> Data {
        guard let data = Data(base64Encoded: string) else {
            throw CryptoError.invalidBase64
        }
        return data
    }

    private func validateCipherSuite(_ cipher: String?) throws {
        guard let cipher else { return }
        guard cipher == CryptoSuite.cipher else {
            throw CryptoError.unsupportedCipherSuite(cipher)
        }
    }

    private func pbkdf2SHA256(password: Data, salt: Data, iterations: Int, keyLength: Int) -> Data {
        let hLen = 32
        let blocks = Int(ceil(Double(keyLength) / Double(hLen)))
        var derived = Data()

        for blockIndex in 1 ... blocks {
            var saltAndIndex = Data()
            saltAndIndex.append(salt)
            var be = UInt32(blockIndex).bigEndian
            withUnsafeBytes(of: &be) { saltAndIndex.append(contentsOf: $0) }

            var u = hmacSHA256(key: password, data: saltAndIndex)
            var t = u

            if iterations > 1 {
                for _ in 2 ... iterations {
                    u = hmacSHA256(key: password, data: u)
                    t = xor(t, u)
                }
            }

            derived.append(t)
        }

        return derived.prefix(keyLength)
    }

    private func hmacSHA256(key: Data, data: Data) -> Data {
        let symmetricKey = SymmetricKey(data: key)
        let digest = HMAC<SHA256>.authenticationCode(for: data, using: symmetricKey)
        return Data(digest)
    }

    private func xor(_ lhs: Data, _ rhs: Data) -> Data {
        Data(zip(lhs, rhs).map { $0 ^ $1 })
    }
}
