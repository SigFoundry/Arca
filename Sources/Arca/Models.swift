import Foundation

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
    var kdf: String
    var cipher: String?
    var createdAt: Date
    var salt: String
    var iterations: Int
    var keyCheck: KeyCheckEnvelope

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case kdf
        case cipher
        case createdAt = "created_at"
        case salt
        case iterations
        case keyCheck = "key_check"
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
