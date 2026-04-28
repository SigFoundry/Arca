import Foundation

enum FileFormatKind {
    case note
    case tombstone
    case vaultMetadata

    var displayName: String {
        switch self {
        case .note:
            return L10n.string("file_format.kind.note")
        case .tombstone:
            return L10n.string("file_format.kind.tombstone")
        case .vaultMetadata:
            return L10n.string("file_format.kind.vault_metadata")
        }
    }
}

enum FileFormatError: Error, LocalizedError {
    case unsupportedVersion(kind: FileFormatKind, version: Int, maxSupported: Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let kind, let version, let maxSupported):
            return L10n.format("error.file_format.unsupported_version", kind.displayName, version, maxSupported)
        }
    }
}

enum FileFormatVersion {
    static let currentNoteFile = 1
    static let currentTombstone = 1
    static let currentVaultMetadata = 3

    static func validate(_ version: Int, for kind: FileFormatKind) throws {
        let maxSupported: Int
        switch kind {
        case .note:
            maxSupported = currentNoteFile
        case .tombstone:
            maxSupported = currentTombstone
        case .vaultMetadata:
            maxSupported = currentVaultMetadata
        }

        guard version >= 1, version <= maxSupported else {
            throw FileFormatError.unsupportedVersion(kind: kind, version: version, maxSupported: maxSupported)
        }
    }
}
