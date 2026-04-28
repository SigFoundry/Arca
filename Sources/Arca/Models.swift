import Foundation

enum VaultAuthenticationMode: String, Codable, CaseIterable, Identifiable {
    case masterPassword = "master_password"
    case deviceAuthentication = "device_authentication"

    var id: String { rawValue }
}

struct MasterPasswordAuthConfig: Codable {
    var kdf: String
    var salt: String
    var iterations: Int
    var wrappedSecret: KeyCheckEnvelope

    enum CodingKeys: String, CodingKey {
        case kdf
        case salt
        case iterations
        case wrappedSecret = "wrapped_secret"
    }
}

struct NotePayload: Codable, Equatable {
    var noteID: UUID
    var version: Int
    var updatedAt: Date
    var deviceID: UUID
    var title: String
    var content: String

    enum CodingKeys: String, CodingKey {
        case noteID = "note_id"
        case version
        case updatedAt = "updated_at"
        case deviceID = "device_id"
        case title
        case content
    }
}

struct EncryptedNoteFile: Codable {
    var formatVersion: Int
    var noteID: UUID
    var cipher: String?
    var nonce: String
    var ciphertext: String
    var tag: String

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case noteID = "note_id"
        case cipher
        case nonce
        case ciphertext
        case tag
    }
}

struct Tombstone: Codable {
    var formatVersion: Int
    var noteID: UUID
    var version: Int
    var deletedAt: Date
    var deviceID: UUID

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case noteID = "note_id"
        case version
        case deletedAt = "deleted_at"
        case deviceID = "device_id"
    }
}

struct DeviceMetadata: Codable {
    var deviceID: UUID
    var createdAt: Date

    enum CodingKeys: String, CodingKey {
        case deviceID = "device_id"
        case createdAt = "created_at"
    }
}

struct VaultMetadata: Codable {
    var formatVersion: Int
    var cipher: String?
    var createdAt: Date
    var enabledAuthModes: [VaultAuthenticationMode]
    var masterPassword: MasterPasswordAuthConfig?
    var deviceAuthenticationEnabled: Bool

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case cipher
        case createdAt = "created_at"
        case enabledAuthModes = "enabled_auth_modes"
        case masterPassword = "master_password"
        case deviceAuthenticationEnabled = "device_authentication_enabled"
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case kdf
        case cipher
        case authMode = "auth_mode"
        case createdAt = "created_at"
        case salt
        case iterations
        case keyCheck = "key_check"
    }

    var allowsMasterPassword: Bool {
        enabledAuthModes.contains(.masterPassword) && masterPassword != nil
    }

    var allowsDeviceAuthentication: Bool {
        enabledAuthModes.contains(.deviceAuthentication) && deviceAuthenticationEnabled
    }

    init(
        formatVersion: Int,
        cipher: String?,
        createdAt: Date,
        enabledAuthModes: [VaultAuthenticationMode],
        masterPassword: MasterPasswordAuthConfig?,
        deviceAuthenticationEnabled: Bool
    ) {
        self.formatVersion = formatVersion
        self.cipher = cipher
        self.createdAt = createdAt
        self.enabledAuthModes = enabledAuthModes
        self.masterPassword = masterPassword
        self.deviceAuthenticationEnabled = deviceAuthenticationEnabled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let formatVersion = try container.decode(Int.self, forKey: .formatVersion)

        if formatVersion >= 3 {
            self.formatVersion = formatVersion
            self.cipher = try container.decodeIfPresent(String.self, forKey: .cipher)
            self.createdAt = try container.decode(Date.self, forKey: .createdAt)
            self.enabledAuthModes = try container.decode([VaultAuthenticationMode].self, forKey: .enabledAuthModes)
            self.masterPassword = try container.decodeIfPresent(MasterPasswordAuthConfig.self, forKey: .masterPassword)
            self.deviceAuthenticationEnabled = try container.decode(Bool.self, forKey: .deviceAuthenticationEnabled)
            return
        }

        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let kdf = try legacy.decode(String.self, forKey: .kdf)
        let cipher = try legacy.decodeIfPresent(String.self, forKey: .cipher)
        let createdAt = try legacy.decode(Date.self, forKey: .createdAt)
        let salt = try legacy.decode(String.self, forKey: .salt)
        let iterations = try legacy.decode(Int.self, forKey: .iterations)
        let keyCheck = try legacy.decode(KeyCheckEnvelope.self, forKey: .keyCheck)
        let authMode = try legacy.decodeIfPresent(VaultAuthenticationMode.self, forKey: .authMode) ?? .masterPassword

        let legacyMaster = MasterPasswordAuthConfig(
            kdf: kdf,
            salt: salt,
            iterations: iterations,
            wrappedSecret: keyCheck
        )

        self.formatVersion = formatVersion
        self.cipher = cipher
        self.createdAt = createdAt

        switch authMode {
        case .masterPassword:
            self.enabledAuthModes = [.masterPassword]
            self.masterPassword = legacyMaster
            self.deviceAuthenticationEnabled = false
        case .deviceAuthentication:
            self.enabledAuthModes = [.deviceAuthentication]
            self.masterPassword = nil
            self.deviceAuthenticationEnabled = true
        }
    }
}

struct KeyCheckEnvelope: Codable {
    var nonce: String
    var ciphertext: String
    var tag: String
}

struct NoteRecord: Identifiable, Equatable {
    let id: UUID
    var noteID: UUID
    var version: Int
    var updatedAt: Date
    var deviceID: UUID
    var title: String
    var content: String
    var isConflictCopy: Bool
    var sourceFileName: String

    init(payload: NotePayload, isConflictCopy: Bool = false, sourceFileName: String) {
        self.id = payload.noteID
        self.noteID = payload.noteID
        self.version = payload.version
        self.updatedAt = payload.updatedAt
        self.deviceID = payload.deviceID
        self.title = payload.title
        self.content = payload.content
        self.isConflictCopy = isConflictCopy
        self.sourceFileName = sourceFileName
    }

    func asPayload() -> NotePayload {
        NotePayload(
            noteID: noteID,
            version: version,
            updatedAt: updatedAt,
            deviceID: deviceID,
            title: title,
            content: content
        )
    }
}

struct VaultLoadResult {
    var notes: [NoteRecord]
    var warnings: [String]
}
