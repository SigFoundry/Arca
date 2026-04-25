import CryptoKit
import Foundation

enum NoteStoreError: Error, LocalizedError {
    case missingMetadata

    var errorDescription: String? {
        switch self {
        case .missingMetadata:
            return L10n.string("error.notestore.missing_metadata")
        }
    }
}

struct NoteStore {
    let rootURL: URL
    let crypto: CryptoService
    let retentionDays: Int

    private var notesURL: URL { rootURL.appendingPathComponent("notes", isDirectory: true) }
    private var tombstonesURL: URL { rootURL.appendingPathComponent("tombstones", isDirectory: true) }
    private var metaURL: URL { rootURL.appendingPathComponent("meta", isDirectory: true) }
    private var deviceMetadataURL: URL { metaURL.appendingPathComponent("device.json") }
    private var vaultMetadataURL: URL { metaURL.appendingPathComponent("vault.json") }

    init(rootURL: URL, crypto: CryptoService, retentionDays: Int = 90) {
        self.rootURL = rootURL
        self.crypto = crypto
        self.retentionDays = retentionDays
    }

    func prepareDirectories() throws {
        try FileManager.default.createDirectory(at: notesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: tombstonesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: metaURL, withIntermediateDirectories: true)
    }

    func loadDeviceMetadata() throws -> DeviceMetadata? {
        guard FileManager.default.fileExists(atPath: deviceMetadataURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: deviceMetadataURL)
        return try crypto.decoder().decode(DeviceMetadata.self, from: data)
    }

    func saveDeviceMetadata(_ metadata: DeviceMetadata) throws {
        let data = try crypto.encoder().encode(metadata)
        try AtomicFileWriter.write(data: data, to: deviceMetadataURL)
    }

    func loadVaultMetadata() throws -> VaultMetadata? {
        guard FileManager.default.fileExists(atPath: vaultMetadataURL.path) else {
            return nil
        }
        let data = try Data(contentsOf: vaultMetadataURL)
        let metadata = try crypto.decoder().decode(VaultMetadata.self, from: data)
        try FileFormatVersion.validate(metadata.formatVersion, for: .vaultMetadata)
        return metadata
    }

    func saveVaultMetadata(_ metadata: VaultMetadata) throws {
        let data = try crypto.encoder().encode(metadata)
        try AtomicFileWriter.write(data: data, to: vaultMetadataURL)
    }

    func save(note: NotePayload, key: SymmetricKey) throws {
        let encrypted = try crypto.encrypt(note: note, using: key)
        let data = try crypto.encoder().encode(encrypted)
        try AtomicFileWriter.write(data: data, to: noteURL(for: note.noteID))
    }

    func delete(note: NotePayload, key: SymmetricKey) throws {
        let tombstone = Tombstone(
            formatVersion: FileFormatVersion.currentTombstone,
            noteID: note.noteID,
            version: note.version + 1,
            deletedAt: Date(),
            deviceID: note.deviceID
        )
        let tombstoneData = try crypto.encoder().encode(tombstone)
        try AtomicFileWriter.write(data: tombstoneData, to: tombstoneURL(for: note.noteID))
        let noteFileURL = noteURL(for: note.noteID)
        if FileManager.default.fileExists(atPath: noteFileURL.path) {
            try? FileManager.default.removeItem(at: noteFileURL)
        }
    }

    func loadVault(key: SymmetricKey, deviceID: UUID) throws -> VaultLoadResult {
        try prepareDirectories()
        try garbageCollect()

        let tombstones = try loadTombstones()
        let noteFiles = try FileManager.default.contentsOfDirectory(
            at: notesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "enc" }

        var grouped: [UUID: [(NotePayload, URL)]] = [:]
        var warnings: [String] = []

        for fileURL in noteFiles {
            do {
                let data = try Data(contentsOf: fileURL)
                let encrypted = try crypto.decoder().decode(EncryptedNoteFile.self, from: data)
                let payload = try crypto.decrypt(file: encrypted, using: key)
                grouped[payload.noteID, default: []].append((payload, fileURL))
            } catch {
                warnings.append(L10n.format("warning.skipped_note_file", fileURL.lastPathComponent))
            }
        }

        var notes: [NoteRecord] = []
        for (noteID, variants) in grouped {
            let liveVariants = variants.filter { variant in
                guard let tombstone = tombstones[noteID] else { return true }
                return tombstone.version < variant.0.version
            }

            guard liveVariants.isEmpty == false else { continue }

            let sorted = liveVariants.sorted { lhs, rhs in
                if lhs.0.version != rhs.0.version {
                    return lhs.0.version > rhs.0.version
                }
                return lhs.0.updatedAt > rhs.0.updatedAt
            }

            let canonical = sorted[0]
            notes.append(NoteRecord(payload: canonical.0, sourceFileName: canonical.1.lastPathComponent))

            let sameVersionConflicts = sorted.dropFirst().filter {
                $0.0.version == canonical.0.version && $0.0 != canonical.0
            }

            for conflict in sameVersionConflicts {
                let conflictSuffix = L10n.string("suffix.conflicted_copy")
                let normalized = NotePayload(
                    noteID: UUID(),
                    version: 1,
                    updatedAt: Date(),
                    deviceID: deviceID,
                    title: conflict.0.title.hasSuffix(conflictSuffix)
                        ? conflict.0.title
                        : "\(conflict.0.title) \(conflictSuffix)",
                    content: conflict.0.content
                )
                do {
                    try save(note: normalized, key: key)
                    try? FileManager.default.removeItem(at: conflict.1)
                    notes.append(NoteRecord(payload: normalized, isConflictCopy: true, sourceFileName: noteURL(for: normalized.noteID).lastPathComponent))
                    warnings.append(L10n.format("warning.conflict_preserved", canonical.0.title))
                } catch {
                    warnings.append(L10n.format("warning.conflict_normalize_failed", conflict.1.lastPathComponent))
                }
            }
        }

        return VaultLoadResult(
            notes: notes.sorted { $0.updatedAt > $1.updatedAt },
            warnings: warnings
        )
    }

    func noteURL(for noteID: UUID) -> URL {
        notesURL.appendingPathComponent("\(noteID.uuidString).json.enc")
    }

    func tombstoneURL(for noteID: UUID) -> URL {
        tombstonesURL.appendingPathComponent("\(noteID.uuidString).json")
    }

    private func loadTombstones() throws -> [UUID: Tombstone] {
        guard FileManager.default.fileExists(atPath: tombstonesURL.path) else {
            return [:]
        }

        let files = try FileManager.default.contentsOfDirectory(
            at: tombstonesURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { $0.pathExtension == "json" }

        var tombstones: [UUID: Tombstone] = [:]
        for fileURL in files {
            do {
                let data = try Data(contentsOf: fileURL)
                let tombstone = try crypto.decoder().decode(Tombstone.self, from: data)
                try FileFormatVersion.validate(tombstone.formatVersion, for: .tombstone)
                let current = tombstones[tombstone.noteID]
                if current == nil || tombstone.version > current?.version ?? 0 {
                    tombstones[tombstone.noteID] = tombstone
                }
            } catch {
                continue
            }
        }
        return tombstones
    }

    private func garbageCollect() throws {
        let expiration = Calendar.current.date(byAdding: .day, value: -retentionDays, to: Date()) ?? .distantPast

        if FileManager.default.fileExists(atPath: tombstonesURL.path) {
            let tombstoneFiles = try FileManager.default.contentsOfDirectory(
                at: tombstonesURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            for fileURL in tombstoneFiles {
                guard
                    let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey]),
                    let modifiedAt = values.contentModificationDate,
                    modifiedAt < expiration
                else {
                    continue
                }
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        if FileManager.default.fileExists(atPath: notesURL.path) {
            let tempFiles = try FileManager.default.contentsOfDirectory(
                at: notesURL,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.hasPrefix(".") && $0.pathExtension == "tmp" }
            for fileURL in tempFiles {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }
    }
}
