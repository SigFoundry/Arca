import AppKit
import Foundation

enum NoteBrowserTab: CaseIterable, Identifiable {
    case allItems
    case secureNotes

    var id: String {
        switch self {
        case .allItems: return "all_items"
        case .secureNotes: return "secure_notes"
        }
    }

    var title: String {
        switch self {
        case .allItems:
            return L10n.string("tab.all_items")
        case .secureNotes:
            return L10n.string("tab.secure_notes")
        }
    }
}

enum VaultLocationFilter: CaseIterable, Identifiable {
    case iCloud

    var id: String { "icloud" }

    var title: String { L10n.string("location.icloud") }
}

enum NoteSortColumn: String, Identifiable {
    case name
    case kind
    case dateModified
    case location

    var id: String { rawValue }
}

enum NoteSortDirection {
    case ascending
    case descending
}

enum NoteSelectionFocusTarget {
    case none
    case title
    case content
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published var isLocked = true
    @Published var searchText = ""
    @Published var selectedNoteID: UUID?
    @Published var editorTitle = ""
    @Published var editorContent = ""
    @Published var warnings: [String] = []
    @Published var unlockError: String?
    @Published var isUnlocking = false
    @Published var deleteTarget: NoteRecord?
    @Published var selectedTab: NoteBrowserTab = .allItems
    @Published var selectedLocation: VaultLocationFilter = .iCloud
    @Published var biometricUnlockAvailable = false
    @Published var biometricUnlockLabel = L10n.string("locked.action.biometric")
    @Published var biometricSetupMessage = L10n.string("locked.biometric_hint")
    @Published var transientNotice: String?
    @Published var titleFocusToken = 0
    @Published var contentFocusToken = 0
    @Published var lockScreenFocusToken = 0
    @Published var sortColumn: NoteSortColumn?
    @Published var sortDirection: NoteSortDirection = .ascending

    let lockController = LockController()

    private let vaultManager: VaultManager
    private let credentialUnlockService = CredentialUnlockService()
    private var isHydratingEditor = false
    private var loadedEditorTitle = ""
    private var loadedEditorContent = ""

    init() {
        do {
            vaultManager = try VaultManager()
        } catch {
            fatalError(L10n.format("error.init_vault", error.localizedDescription))
        }
        refreshBiometricUnlockAvailability()
    }

    var vaultPath: String {
        vaultManager.vaultURL.path
    }

    var needsVaultCreation: Bool {
        vaultManager.needsVaultCreation
    }

    var filteredNotes: [NoteRecord] {
        let base = vaultManager.filteredNotes(query: searchText)
        let scoped: [NoteRecord]
        switch selectedTab {
        case .allItems, .secureNotes:
            scoped = base
        }

        guard let sortColumn else {
            return scoped
        }

        return scoped.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch sortColumn {
            case .name:
                comparison = lhs.title.localizedCaseInsensitiveCompare(rhs.title)
            case .kind:
                comparison = L10n.string("note.kind.secure").localizedCaseInsensitiveCompare(L10n.string("note.kind.secure"))
            case .dateModified:
                if lhs.updatedAt == rhs.updatedAt { comparison = .orderedSame }
                else { comparison = lhs.updatedAt < rhs.updatedAt ? .orderedAscending : .orderedDescending }
            case .location:
                comparison = selectedLocation.title.localizedCaseInsensitiveCompare(selectedLocation.title)
            }

            if comparison == .orderedSame {
                return lhs.updatedAt > rhs.updatedAt
            }

            switch sortDirection {
            case .ascending:
                return comparison == .orderedAscending
            case .descending:
                return comparison == .orderedDescending
            }
        }
    }

    var selectedNote: NoteRecord? {
        guard let selectedNoteID else { return nil }
        return vaultManager.notes.first { $0.id == selectedNoteID }
    }

    var selectedNoteLocation: String {
        currentLocationDisplayName
    }

    var currentLocationDisplayName: String {
        vaultPath.contains("/Mobile Documents/com~apple~CloudDocs/") ? L10n.string("location.icloud") : L10n.string("location.local_vault")
    }

    func unlock(password: String, persistBiometricCredential: Bool = true) {
        guard isUnlocking == false else { return }
        isUnlocking = true
        unlockError = nil

        Task {
            let request = vaultManager.makeUnlockRequest()

            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try VaultManager.performUnlock(password: password, request: request)
                }.value

                await MainActor.run {
                    self.vaultManager.applyUnlockResult(result)
                    self.warnings = result.warnings
                    self.unlockError = nil
                    self.isLocked = false
                    if persistBiometricCredential {
                        do {
                            try self.credentialUnlockService.store(password: password)
                        } catch CredentialUnlockError.unavailable {
                            self.biometricSetupMessage = self.credentialUnlockService.setupMessage(hasStoredCredential: false)
                        } catch {
                            self.warnings = result.warnings + [error.localizedDescription]
                        }
                    }
                    self.refreshBiometricUnlockAvailability()
                    self.lockController.start { [weak self] in
                        self?.lock()
                    }
                    self.selectedNoteID = nil
                    self.clearEditor()
                    self.isUnlocking = false
                }
            } catch {
                await MainActor.run {
                    self.unlockError = error.localizedDescription
                    self.isUnlocking = false
                }
            }
        }
    }

    func unlockWithBiometrics() {
        do {
            let password = try credentialUnlockService.retrievePassword(prompt: L10n.string("unlock.prompt"))
            unlock(password: password, persistBiometricCredential: false)
        } catch {
            unlockError = error.localizedDescription
            refreshBiometricUnlockAvailability()
        }
    }

    func lock() {
        lockController.stop()
        vaultManager.lock()
        isLocked = true
        lockScreenFocusToken += 1
        searchText = ""
        selectedNoteID = nil
        clearEditor()
        warnings = []
    }

    func requestLock() {
        guard resolvePendingChangesIfNeeded() else { return }
        lock()
    }

    func touch() {
        lockController.touch()
    }

    func refresh() {
        guard resolvePendingChangesIfNeeded() else { return }
        do {
            try vaultManager.reload()
            warnings = vaultManager.warnings
            if let selectedNoteID, vaultManager.notes.contains(where: { $0.id == selectedNoteID }) {
                loadSelectedNote()
            } else {
                selectedNoteID = nil
                clearEditor()
            }
            showTransientNotice(L10n.format("refresh.notice", currentLocationDisplayName))
        } catch {
            warnings = [error.localizedDescription]
        }
    }

    func createNote() {
        guard resolvePendingChangesIfNeeded() else { return }
        do {
            let note = try vaultManager.createNote()
            warnings = vaultManager.warnings
            select(noteID: note.id, focusTarget: .title)
        } catch {
            warnings = [error.localizedDescription]
        }
    }

    func confirmDelete() {
        guard resolvePendingChangesIfNeeded() else { return }
        guard let selectedNote else { return }
        deleteTarget = selectedNote
    }

    func deleteConfirmed() {
        guard let deleteTarget else { return }
        do {
            try vaultManager.deleteNote(id: deleteTarget.id)
            self.deleteTarget = nil
            if let first = filteredNotes.first {
                select(noteID: first.id)
            } else {
                selectedNoteID = nil
                clearEditor()
            }
        } catch {
            warnings = [error.localizedDescription]
        }
    }

    func select(noteID: UUID?, focusTarget: NoteSelectionFocusTarget = .content) {
        guard selectedNoteID != noteID || noteID == nil else { return }
        guard resolvePendingChangesIfNeeded() else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectedNoteID = noteID
            self.loadSelectedNote()
            switch focusTarget {
            case .none:
                break
            case .title:
                self.titleFocusToken += 1
            case .content:
                if noteID != nil {
                    self.contentFocusToken += 1
                }
            }
        }
    }

    func markEditorChanged() {
        guard isHydratingEditor == false else { return }
        touch()
    }

    @discardableResult
    func saveCurrentNote() -> Bool {
        guard let selectedNoteID else { return false }
        return save(noteID: selectedNoteID, title: editorTitle, content: editorContent)
    }

    func canCloseWindow() -> Bool {
        resolvePendingChangesIfNeeded()
    }

    private func save(noteID: UUID, title: String, content: String) -> Bool {
        do {
            let didSave = try vaultManager.saveNote(id: noteID, title: title, content: content)
            if didSave {
                loadedEditorTitle = title.isEmpty ? L10n.string("note.title.untitled") : title
                loadedEditorContent = content
            }
            return true
        } catch {
            warnings = [error.localizedDescription]
            return false
        }
    }

    private func loadSelectedNote() {
        isHydratingEditor = true
        if let note = selectedNote {
            editorTitle = note.title
            editorContent = note.content
            loadedEditorTitle = note.title
            loadedEditorContent = note.content
        } else {
            clearEditor()
        }
        DispatchQueue.main.async { [weak self] in
            self?.isHydratingEditor = false
        }
    }

    private func clearEditor() {
        editorTitle = ""
        editorContent = ""
        loadedEditorTitle = ""
        loadedEditorContent = ""
    }

    private var hasUnsavedEditorChanges: Bool {
        guard selectedNoteID != nil else { return false }
        let normalizedTitle = editorTitle.isEmpty ? L10n.string("note.title.untitled") : editorTitle
        return normalizedTitle != loadedEditorTitle || editorContent != loadedEditorContent
    }

    private func resolvePendingChangesIfNeeded() -> Bool {
        guard hasUnsavedEditorChanges else { return true }

        let alert = NSAlert()
        alert.messageText = L10n.string("save.confirm.title")
        alert.informativeText = L10n.string("save.confirm.message")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("save.confirm.save"))
        alert.addButton(withTitle: L10n.string("save.confirm.discard"))
        alert.addButton(withTitle: L10n.string("common.cancel"))

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveCurrentNote()
        case .alertSecondButtonReturn:
            return true
        default:
            return false
        }
    }

    func toggleSort(for column: NoteSortColumn) {
        if sortColumn != column {
            sortColumn = column
            sortDirection = .ascending
            return
        }

        switch sortDirection {
        case .ascending:
            sortDirection = .descending
        case .descending:
            sortColumn = nil
            sortDirection = .ascending
        }
    }

    func sortIndicator(for column: NoteSortColumn) -> String {
        guard sortColumn == column else { return "" }
        switch sortDirection {
        case .ascending:
            return " ↑"
        case .descending:
            return " ↓"
        }
    }

    private func refreshBiometricUnlockAvailability() {
        if let kind = credentialUnlockService.biometricKind() {
            biometricUnlockLabel = kind.buttonTitle
            let hasStoredCredential = credentialUnlockService.hasStoredCredential()
            biometricUnlockAvailable = hasStoredCredential
            biometricSetupMessage = credentialUnlockService.setupMessage(hasStoredCredential: hasStoredCredential)
        } else {
            biometricUnlockLabel = L10n.string("locked.action.biometric")
            biometricUnlockAvailable = false
            biometricSetupMessage = credentialUnlockService.setupMessage(hasStoredCredential: false)
        }
    }

    private func showTransientNotice(_ message: String) {
        transientNotice = message
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard self?.transientNotice == message else { return }
            self?.transientNotice = nil
        }
    }
}
