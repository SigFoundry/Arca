import CryptoKit
import Foundation

@MainActor
final class VaultManager {
    struct UnlockRequest: Sendable {
        let rootURL: URL
        let deviceMetadata: DeviceMetadata
        let vaultMetadata: VaultMetadata?
    }

    struct UnlockComputationResult: Sendable {
        let keyData: Data
        let notes: [NoteRecord]
        let warnings: [String]
        let vaultMetadata: VaultMetadata
    }

    private let crypto = CryptoService()
    private let searchIndex = SearchIndex()

    private(set) var store: NoteStore
    private(set) var deviceMetadata: DeviceMetadata
    private(set) var vaultMetadata: VaultMetadata?
    private(set) var key: SymmetricKey?
    private(set) var notes: [NoteRecord] = []
    private(set) var warnings: [String] = []

    init() throws {
        let rootURL = Self.defaultVaultURL()
        store = NoteStore(rootURL: rootURL, crypto: crypto)
        try store.prepareDirectories()

        if let existingDevice = try store.loadDeviceMetadata() {
            deviceMetadata = existingDevice
        } else {
            let metadata = DeviceMetadata(deviceID: UUID(), createdAt: Date())
            try store.saveDeviceMetadata(metadata)
            deviceMetadata = metadata
        }
        vaultMetadata = try store.loadVaultMetadata()
    }

    var vaultURL: URL {
        store.rootURL
    }

    var needsVaultCreation: Bool {
        vaultMetadata == nil
    }

    func makeUnlockRequest() -> UnlockRequest {
        UnlockRequest(
            rootURL: store.rootURL,
            deviceMetadata: deviceMetadata,
            vaultMetadata: vaultMetadata
        )
    }

    nonisolated static func performUnlock(password: String, request: UnlockRequest) throws -> UnlockComputationResult {
        let crypto = CryptoService()
        let store = NoteStore(rootURL: request.rootURL, crypto: crypto)
        try store.prepareDirectories()

        let effectiveVaultMetadata: VaultMetadata
        if let existing = request.vaultMetadata {
            effectiveVaultMetadata = existing
        } else {
            let created = try crypto.makeVaultMetadata(password: password)
            try store.saveVaultMetadata(created)
            effectiveVaultMetadata = created
        }

        let derivedKey = try crypto.verifyPassword(password, vaultMetadata: effectiveVaultMetadata)
        let result = try store.loadVault(key: derivedKey, deviceID: request.deviceMetadata.deviceID)
        let keyData = derivedKey.withUnsafeBytes { Data($0) }

        return UnlockComputationResult(
            keyData: keyData,
            notes: result.notes,
            warnings: result.warnings,
            vaultMetadata: effectiveVaultMetadata
        )
    }

    func applyUnlockResult(_ result: UnlockComputationResult) {
        key = SymmetricKey(data: result.keyData)
        notes = result.notes
        warnings = result.warnings
        vaultMetadata = result.vaultMetadata
    }

    func unlock(password: String) throws {
        if vaultMetadata == nil {
            let metadata = try crypto.makeVaultMetadata(password: password)
            try store.saveVaultMetadata(metadata)
            vaultMetadata = metadata
        }

        guard let vaultMetadata else {
            throw NoteStoreError.missingMetadata
        }

        let derivedKey = try crypto.verifyPassword(password, vaultMetadata: vaultMetadata)
        let result = try store.loadVault(key: derivedKey, deviceID: deviceMetadata.deviceID)
        key = derivedKey
        notes = result.notes
        warnings = result.warnings
    }

    func lock() {
        key = nil
        notes = []
        warnings = []
    }

    func filteredNotes(query: String) -> [NoteRecord] {
        searchIndex.filter(notes: notes, query: query)
    }

    @discardableResult
    func createNote() throws -> NoteRecord {
        guard let key else { throw CryptoError.passwordVerificationFailed }
        let payload = NotePayload(
            noteID: UUID(),
            version: 1,
            updatedAt: Date(),
            deviceID: deviceMetadata.deviceID,
            title: L10n.string("note.title.untitled"),
            content: ""
        )
        try store.save(note: payload, key: key)
        let note = NoteRecord(payload: payload, sourceFileName: store.noteURL(for: payload.noteID).lastPathComponent)
        notes.insert(note, at: 0)
        return note
    }

    @discardableResult
    func saveNote(id: UUID, title: String, content: String) throws -> Bool {
        guard let key else { throw CryptoError.passwordVerificationFailed }
        guard let index = notes.firstIndex(where: { $0.id == id }) else { return false }
        var note = notes[index]
        let normalizedTitle = title.isEmpty ? L10n.string("note.title.untitled") : title
        let normalizedContent = content

        guard note.title != normalizedTitle || note.content != normalizedContent else {
            return false
        }

        note.title = normalizedTitle
        note.content = normalizedContent
        note.version += 1
        note.updatedAt = Date()
        note.deviceID = deviceMetadata.deviceID
        try store.save(note: note.asPayload(), key: key)
        notes[index] = note
        notes.sort { $0.updatedAt > $1.updatedAt }
        return true
    }

    func deleteNote(id: UUID) throws {
        guard let key else { throw CryptoError.passwordVerificationFailed }
        guard let note = notes.first(where: { $0.id == id }) else { return }
        try store.delete(note: note.asPayload(), key: key)
        notes.removeAll { $0.id == id }
    }

    func reload() throws {
        guard let key else { return }
        let result = try store.loadVault(key: key, deviceID: deviceMetadata.deviceID)
        notes = result.notes
        warnings = result.warnings
    }

    private static func defaultVaultURL() -> URL {
        let fm = FileManager.default
        let iCloud = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs/ArcaVault", isDirectory: true)
        if fm.fileExists(atPath: iCloud.deletingLastPathComponent().path) {
            return iCloud
        }

        let fallback = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ArcaVault", isDirectory: true)
        return fallback
    }
}
