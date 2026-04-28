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
    @Published var initialSetupAuthMode: VaultAuthenticationMode = .masterPassword
    @Published var deviceAuthAvailable = false
    @Published var deviceAuthLabel = L10n.string("locked.action.device_auth")
    @Published var lockedScreenMessage = ""
    @Published var transientNotice: String?
    @Published var titleFocusToken = 0
    @Published var contentFocusToken = 0
    @Published var lockScreenFocusToken = 0
    @Published var sortColumn: NoteSortColumn?
    @Published var sortDirection: NoteSortDirection = .ascending
    @Published var authSettingsError: String?
    @Published var authSettingsNotice: String?

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
        refreshAuthenticationState()
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

    var initialSetupUsesMasterPassword: Bool {
        initialSetupAuthMode == .masterPassword
    }

    var passwordUnlockAvailable: Bool {
        needsVaultCreation ? initialSetupUsesMasterPassword : vaultManager.supportsMasterPassword
    }

    var deviceUnlockConfigured: Bool {
        needsVaultCreation ? initialSetupAuthMode == .deviceAuthentication : vaultManager.supportsDeviceAuthentication
    }

    var canDisableMasterPassword: Bool {
        vaultManager.supportsMasterPassword && vaultManager.supportsDeviceAuthentication
    }

    var canDisableDeviceAuthentication: Bool {
        vaultManager.supportsDeviceAuthentication && vaultManager.supportsMasterPassword
    }

    func setInitialSetupAuthMode(_ mode: VaultAuthenticationMode) {
        initialSetupAuthMode = mode
        refreshAuthenticationState()
    }

    func createVault(password: String?) {
        guard isUnlocking == false else { return }
        isUnlocking = true
        unlockError = nil

        Task {
            let request = vaultManager.makeUnlockRequest()

            do {
                let result: VaultManager.UnlockComputationResult
                switch initialSetupAuthMode {
                case .masterPassword:
                    guard let password else {
                        throw CryptoError.passwordVerificationFailed
                    }
                    result = try await Task.detached(priority: .userInitiated) {
                        try VaultManager.performInitialUnlock(
                            request: request,
                            initialPassword: password,
                            deviceAuthenticationEnabled: false,
                            deviceSecret: nil
                        )
                    }.value
                case .deviceAuthentication:
                    let crypto = CryptoService()
                    let secret = crypto.exportVaultSecret(crypto.makeVaultSecret())
                    try credentialUnlockService.store(secret: secret)
                    do {
                        result = try await Task.detached(priority: .userInitiated) {
                            try VaultManager.performInitialUnlock(
                                request: request,
                                initialPassword: nil,
                                deviceAuthenticationEnabled: true,
                                deviceSecret: secret
                            )
                        }.value
                    } catch {
                        credentialUnlockService.deleteStoredSecret()
                        throw error
                    }
                }

                await MainActor.run {
                    self.finishUnlock(with: result)
                }
            } catch {
                await MainActor.run {
                    self.unlockError = error.localizedDescription
                    self.isUnlocking = false
                    self.refreshAuthenticationState()
                }
            }
        }
    }

    func unlockWithPassword(_ password: String) {
        guard isUnlocking == false else { return }
        isUnlocking = true
        unlockError = nil

        Task {
            let request = vaultManager.makeUnlockRequest()
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try VaultManager.performPasswordUnlock(password: password, request: request)
                }.value

                await MainActor.run {
                    self.finishUnlock(with: result)
                }
            } catch {
                await MainActor.run {
                    self.unlockError = error.localizedDescription
                    self.isUnlocking = false
                    self.refreshAuthenticationState()
                }
            }
        }
    }

    func unlockWithDeviceAuthentication() {
        guard isUnlocking == false else { return }
        isUnlocking = true
        unlockError = nil

        do {
            let secret = try credentialUnlockService.retrieveSecret(prompt: L10n.string("unlock.prompt"))

            Task {
                let request = vaultManager.makeUnlockRequest()
                do {
                    let result = try await Task.detached(priority: .userInitiated) {
                        try VaultManager.performDeviceAuthenticationUnlock(deviceSecret: secret, request: request)
                    }.value

                    await MainActor.run {
                        self.finishUnlock(with: result)
                    }
                } catch {
                    await MainActor.run {
                        self.unlockError = error.localizedDescription
                        self.isUnlocking = false
                        self.refreshAuthenticationState()
                    }
                }
            }
        } catch {
            unlockError = error.localizedDescription
            isUnlocking = false
            refreshAuthenticationState()
        }
    }

    func enableMasterPassword(password: String, confirmation: String) {
        guard password == confirmation else {
            authSettingsError = L10n.string("locked.error.passwords_mismatch")
            return
        }

        do {
            try vaultManager.enableMasterPassword(password)
            authSettingsError = nil
            authSettingsNotice = L10n.string("settings.auth.master.enabled")
            refreshAuthenticationState()
        } catch {
            authSettingsError = error.localizedDescription
        }
    }

    func disableMasterPassword() {
        do {
            try vaultManager.disableMasterPassword()
            authSettingsError = nil
            authSettingsNotice = L10n.string("settings.auth.master.disabled")
            refreshAuthenticationState()
        } catch {
            authSettingsError = error.localizedDescription
        }
    }

    func enableDeviceAuthentication() {
        do {
            let secret = try vaultManager.enableDeviceAuthentication()
            do {
                try credentialUnlockService.store(secret: secret)
            } catch {
                try? vaultManager.disableDeviceAuthentication()
                throw error
            }
            authSettingsError = nil
            authSettingsNotice = L10n.string("settings.auth.device.enabled")
            refreshAuthenticationState()
        } catch {
            authSettingsError = error.localizedDescription
            refreshAuthenticationState()
        }
    }

    func disableDeviceAuthentication() {
        do {
            try vaultManager.disableDeviceAuthentication()
            credentialUnlockService.deleteStoredSecret()
            authSettingsError = nil
            authSettingsNotice = L10n.string("settings.auth.device.disabled")
            refreshAuthenticationState()
        } catch {
            authSettingsError = error.localizedDescription
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
        refreshAuthenticationState()
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

    func clearAuthSettingsMessages() {
        authSettingsError = nil
        authSettingsNotice = nil
    }

    private func finishUnlock(with result: VaultManager.UnlockComputationResult) {
        vaultManager.applyUnlockResult(result)
        warnings = result.warnings
        unlockError = nil
        isLocked = false
        lockController.start { [weak self] in
            self?.lock()
        }
        selectedNoteID = nil
        clearEditor()
        isUnlocking = false
        refreshAuthenticationState()
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

    private func refreshAuthenticationState() {
        deviceAuthLabel = credentialUnlockService.buttonTitle()
        let hasStoredCredential = credentialUnlockService.hasStoredCredential()
        let canAuthenticate = credentialUnlockService.isDeviceAuthenticationAvailable()
        let canUseProtectedKeychain = credentialUnlockService.isRunningAsAppBundle()

        if needsVaultCreation {
            deviceAuthAvailable = canAuthenticate && canUseProtectedKeychain
            lockedScreenMessage = credentialUnlockService.lockedScreenMessage(
                hasMasterPassword: initialSetupAuthMode == .masterPassword,
                hasDeviceAuthentication: initialSetupAuthMode == .deviceAuthentication,
                hasStoredCredential: hasStoredCredential
            )
            return
        }

        deviceAuthAvailable = canAuthenticate && vaultManager.supportsDeviceAuthentication
        lockedScreenMessage = credentialUnlockService.lockedScreenMessage(
            hasMasterPassword: vaultManager.supportsMasterPassword,
            hasDeviceAuthentication: vaultManager.supportsDeviceAuthentication,
            hasStoredCredential: hasStoredCredential
        )
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
