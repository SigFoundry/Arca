import CryptoKit
import Foundation

enum CryptoError: Error, LocalizedError {
    case invalidBase64
    case invalidEnvelope
    case passwordVerificationFailed
    case unsupportedCipherSuite(String)

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
        }
    }
}

struct CryptoService {
    private enum CryptoSuite {
        static let cipher = "aes-256-gcm"
        static let keyLength = 32
        static let verificationPlaintext = "arca-unlock-check"
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

    func makeVaultMetadata(password: String) throws -> VaultMetadata {
        let salt = Data((0..<16).map { _ in UInt8.random(in: .min ... .max) })
        let iterations = 210_000
        let key = deriveKey(password: password, salt: salt, iterations: iterations)
        let seal = try AES.GCM.seal(Data(CryptoSuite.verificationPlaintext.utf8), using: key)
        return VaultMetadata(
            formatVersion: FileFormatVersion.currentVaultMetadata,
            kdf: "pbkdf2-sha256",
            cipher: CryptoSuite.cipher,
            createdAt: Date(),
            salt: salt.base64EncodedString(),
            iterations: iterations,
            keyCheck: KeyCheckEnvelope(
                nonce: seal.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
                ciphertext: seal.ciphertext.base64EncodedString(),
                tag: seal.tag.base64EncodedString()
            )
        )
    }

    func deriveKey(password: String, vaultMetadata: VaultMetadata) throws -> SymmetricKey {
        try FileFormatVersion.validate(vaultMetadata.formatVersion, for: .vaultMetadata)
        try validateCipherSuite(vaultMetadata.cipher)
        guard let salt = Data(base64Encoded: vaultMetadata.salt) else {
            throw CryptoError.invalidBase64
        }
        return deriveKey(password: password, salt: salt, iterations: vaultMetadata.iterations)
    }

    func verifyPassword(_ password: String, vaultMetadata: VaultMetadata) throws -> SymmetricKey {
        let key = try deriveKey(password: password, vaultMetadata: vaultMetadata)
        let nonceData = try decodeBase64(vaultMetadata.keyCheck.nonce)
        let ciphertext = try decodeBase64(vaultMetadata.keyCheck.ciphertext)
        let tag = try decodeBase64(vaultMetadata.keyCheck.tag)
        let sealedBox = try AES.GCM.SealedBox(
            nonce: try AES.GCM.Nonce(data: nonceData),
            ciphertext: ciphertext,
            tag: tag
        )
        let plaintext = try AES.GCM.open(sealedBox, using: key)
        guard plaintext == Data(CryptoSuite.verificationPlaintext.utf8) else {
            throw CryptoError.passwordVerificationFailed
        }
        return key
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

    private func decodeBase64(_ string: String) throws -> Data {
        guard let data = Data(base64Encoded: string) else {
            throw CryptoError.invalidBase64
        }
        return data
    }

    private func deriveKey(password: String, salt: Data, iterations: Int) -> SymmetricKey {
        let passwordData = Data(password.utf8)
        let derived = pbkdf2SHA256(
            password: passwordData,
            salt: salt,
            iterations: iterations,
            keyLength: CryptoSuite.keyLength
        )
        return SymmetricKey(data: derived)
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
