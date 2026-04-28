import AppKit
import SwiftUI

struct ContentView: View {
    @StateObject private var model: AppModel

    init(model: AppModel = .shared) {
        _model = StateObject(wrappedValue: model)
    }

    var body: some View {
        Group {
            if model.isLocked {
                LockedView(model: model)
            } else {
                VaultView(model: model)
            }
        }
        .frame(minWidth: 980, minHeight: 620)
    }
}

private enum ArcaTypography {
    static let titleSize: CGFloat = 21
    static let lockTitleSize: CGFloat = 31
    static let bodySize: CGFloat = 10
    static let headlineSize: CGFloat = 10
    static let captionSize: CGFloat = 8
    static let editorSize: CGFloat = 13
    static let nameFieldSize: CGFloat = 13
    static let tabSize: CGFloat = 10
    static let searchFieldSize: CGFloat = 13
    static let tableSize: CGFloat = 11
}

private enum ArcaLayout {
    static let sidebarWidth: CGFloat = 220
    static let noteIconWidth: CGFloat = 28
    static let noteIconSpacing: CGFloat = 14
    static let tabControlWidth: CGFloat = 238
}

private enum ArcaColors {
    static let tabActive = Color(nsColor: .selectedControlColor).opacity(0.32)
}

private struct LockedView: View {
    @ObservedObject var model: AppModel
    @State private var password = ""
    @State private var confirmation = ""
    @State private var passwordFocusToken = 0
    @State private var passwordSelectAllToken = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("app.name"))
                .font(.system(size: ArcaTypography.lockTitleSize, weight: .semibold))
            Text(model.needsVaultCreation ? L10n.string("locked.title.create") : L10n.string("locked.title.unlock"))
                .font(.system(size: ArcaTypography.bodySize))
                .foregroundStyle(.secondary)

            if model.needsVaultCreation {
                VStack(alignment: .leading, spacing: 10) {
                    Text(L10n.string("locked.auth_mode.title"))
                        .font(.system(size: ArcaTypography.bodySize, weight: .semibold))

                    VStack(spacing: 10) {
                        authModeOption(
                            mode: .masterPassword,
                            title: L10n.string("locked.auth_mode.master.title"),
                            message: L10n.string("locked.auth_mode.master.message")
                        )
                        authModeOption(
                            mode: .deviceAuthentication,
                            title: L10n.string("locked.auth_mode.device.title"),
                            message: L10n.string("locked.auth_mode.device.message")
                        )
                    }

                    Text(L10n.string("locked.auth_mode.mutable"))
                        .font(.system(size: ArcaTypography.bodySize))
                        .foregroundStyle(.secondary)
                }
            }

            if model.passwordUnlockAvailable {
                VStack(alignment: .leading, spacing: 12) {
                    SecureInputField(L10n.string("locked.master_password"), text: $password)
                        .focusOnToken(passwordFocusToken)
                        .selectAllOnToken(passwordSelectAllToken)
                        .frame(height: 30)
                        .disabled(model.isUnlocking)
                        .onChange(of: password) {
                            model.unlockError = nil
                        }

                    if model.needsVaultCreation {
                        SecureInputField(L10n.string("locked.confirm_password"), text: $confirmation)
                            .frame(height: 30)
                            .disabled(model.isUnlocking)
                            .onChange(of: confirmation) {
                                model.unlockError = nil
                            }
                    }
                }
            }

            if let error = model.unlockError {
                Text(error)
                    .foregroundStyle(.red)
                    .font(.system(size: ArcaTypography.bodySize))
            }

            if model.passwordUnlockAvailable || model.needsVaultCreation {
                Button(model.needsVaultCreation ? L10n.string("locked.action.create") : L10n.string("locked.action.unlock")) {
                    if model.needsVaultCreation {
                        if model.initialSetupUsesMasterPassword {
                            if password != confirmation {
                                model.unlockError = L10n.string("locked.error.passwords_mismatch")
                                return
                            }
                            model.createVault(password: password)
                        } else {
                            model.createVault(password: nil)
                        }
                    } else {
                        model.unlockWithPassword(password)
                    }
                }
                .disabled(model.isUnlocking || model.passwordUnlockAvailable == false)
                .keyboardShortcut(.defaultAction)
            }

            if model.deviceUnlockConfigured {
                Button(model.deviceAuthLabel) {
                    if model.needsVaultCreation {
                        model.createVault(password: nil)
                    } else {
                        model.unlockWithDeviceAuthentication()
                    }
                }
                .disabled(model.isUnlocking || model.deviceAuthAvailable == false)
            }

            if model.isUnlocking {
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text(L10n.string("locked.loading"))
                        .font(.system(size: ArcaTypography.bodySize))
                        .foregroundStyle(.secondary)
                }
            }

            Text(model.lockedScreenMessage)
                .font(.system(size: ArcaTypography.bodySize))
                .foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: 460)
        .onAppear {
            focusPasswordIfNeeded()
        }
        .onChange(of: model.isLocked) {
            if model.isLocked == false {
                password = ""
                confirmation = ""
            }
        }
        .onChange(of: model.lockScreenFocusToken) {
            focusPasswordIfNeeded()
        }
        .onChange(of: model.unlockError) {
            guard model.unlockError != nil else { return }
            guard model.passwordUnlockAvailable else { return }
            passwordFocusToken += 1
            passwordSelectAllToken += 1
        }
        .onChange(of: model.initialSetupAuthMode) {
            model.unlockError = nil
            focusPasswordIfNeeded()
        }
    }

    private func focusPasswordIfNeeded() {
        guard model.passwordUnlockAvailable else { return }
        passwordFocusToken += 1
    }

    private func authModeOption(mode: VaultAuthenticationMode, title: String, message: String) -> some View {
        Button {
            model.setInitialSetupAuthMode(mode)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.initialSetupAuthMode == mode ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(model.initialSetupAuthMode == mode ? Color.accentColor : Color.secondary)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: ArcaTypography.bodySize, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(message)
                        .font(.system(size: ArcaTypography.bodySize))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(model.initialSetupAuthMode == mode ? Color.accentColor.opacity(0.7) : Color(nsColor: .separatorColor), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

private struct SecureInputField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var focusToken = 0
    var selectAllToken = 0

    init(_ placeholder: String, text: Binding<String>) {
        self.placeholder = placeholder
        _text = text
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSSecureTextField {
        let field = NSSecureTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = true
        field.isBezeled = true
        field.focusRingType = .default
        field.bezelStyle = .roundedBezel
        field.font = .systemFont(ofSize: NSFont.systemFontSize)
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSSecureTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.requestFocus(token: focusToken, field: nsView, selectAll: false)
        }
        if context.coordinator.lastSelectAllToken != selectAllToken {
            context.coordinator.requestFocus(token: selectAllToken, field: nsView, selectAll: true)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        var lastFocusToken = 0
        var lastSelectAllToken = 0

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSecureTextField else { return }
            text = field.stringValue
        }

        func requestFocus(token: Int, field: NSSecureTextField, selectAll: Bool) {
            DispatchQueue.main.async {
                self.attemptFocus(token: token, field: field, selectAll: selectAll, attempt: 0)
            }
        }

        @MainActor
        private func attemptFocus(token: Int, field: NSSecureTextField, selectAll: Bool, attempt: Int) {
            guard attempt < 16 else { return }
            guard let window = field.window, window.canBecomeKey, window.isKeyWindow else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    self.attemptFocus(token: token, field: field, selectAll: selectAll, attempt: attempt + 1)
                }
                return
            }

            let didFocus = window.makeFirstResponder(field)
            guard didFocus else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    self.attemptFocus(token: token, field: field, selectAll: selectAll, attempt: attempt + 1)
                }
                return
            }

            if selectAll {
                guard field.stringValue.isEmpty == false else {
                    lastSelectAllToken = token
                    return
                }
                DispatchQueue.main.async {
                    field.currentEditor()?.selectAll(nil)
                    self.lastSelectAllToken = token
                }
            } else {
                lastFocusToken = token
            }
        }
    }
}

private extension SecureInputField {
    func focusOnToken(_ token: Int) -> SecureInputField {
        var copy = self
        copy.focusToken = token
        return copy
    }

    func selectAllOnToken(_ token: Int) -> SecureInputField {
        var copy = self
        copy.selectAllToken = token
        return copy
    }
}

private struct SelectableTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var focusToken: Int

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: ArcaTypography.nameFieldSize)
        field.stringValue = text
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.placeholderString = placeholder
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.requestFocus(token: focusToken, field: nsView)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding private var text: String
        var lastFocusToken = 0

        init(text: Binding<String>) {
            _text = text
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            text = field.stringValue
        }

        func requestFocus(token: Int, field: NSTextField) {
            DispatchQueue.main.async {
                self.attemptFocus(token: token, field: field, attempt: 0)
            }
        }

        @MainActor
        private func attemptFocus(token: Int, field: NSTextField, attempt: Int) {
            guard attempt < 16 else { return }
            guard let window = field.window, window.canBecomeKey, window.isKeyWindow else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    self.attemptFocus(token: token, field: field, attempt: attempt + 1)
                }
                return
            }

            let didFocus = window.makeFirstResponder(field)
            guard didFocus else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    self.attemptFocus(token: token, field: field, attempt: attempt + 1)
                }
                return
            }

            DispatchQueue.main.async {
                field.currentEditor()?.selectAll(nil)
                self.lastFocusToken = token
            }
        }
    }
}

private struct FocusableTextEditor: NSViewRepresentable {
    @Binding var text: String
    var focusToken: Int
    let font: NSFont

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.borderType = .noBorder
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.drawsBackground = false
        textView.allowsUndo = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainerInset = NSSize(width: 0, height: 0)
        textView.font = font
        textView.delegate = context.coordinator
        textView.string = text

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = context.coordinator.textView else { return }
        if textView.string != text {
            textView.string = text
        }
        textView.font = font
        if context.coordinator.lastFocusToken != focusToken {
            context.coordinator.requestFocus(token: focusToken)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String
        weak var textView: NSTextView?
        var lastFocusToken = 0

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            text = textView.string
        }

        func requestFocus(token: Int) {
            DispatchQueue.main.async {
                self.attemptFocus(token: token, attempt: 0)
            }
        }

        @MainActor
        private func attemptFocus(token: Int, attempt: Int) {
            guard attempt < 16 else { return }
            guard let textView, let window = textView.window, window.canBecomeKey, window.isKeyWindow else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    self.attemptFocus(token: token, attempt: attempt + 1)
                }
                return
            }

            let didFocus = window.makeFirstResponder(textView)
            guard didFocus else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) {
                    self.attemptFocus(token: token, attempt: attempt + 1)
                }
                return
            }

            let start = NSRange(location: 0, length: 0)
            textView.setSelectedRange(start)
            textView.scrollRangeToVisible(start)
            lastFocusToken = token
        }
    }
}

private struct VaultView: View {
    @ObservedObject var model: AppModel
    @State private var tablePaneHeight: CGFloat?
    @State private var dragStartTableHeight: CGFloat?
    @State private var dragAvailableHeight: CGFloat?
    @State private var dragStartGlobalY: CGFloat?
    @State private var showingSettingsSheet = false
    @State private var settingsLocations: [SettingsLocation] = [
        SettingsLocation(name: "iCloud", path: "~/Library/Mobile Documents/com~apple~CloudDocs/ArcaVault")
    ]
    @State private var selectedSettingsLocationID: SettingsLocation.ID?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $model.selectedLocation) {
                    Section(L10n.string("sidebar.location")) {
                        Label(model.currentLocationDisplayName, systemImage: "externaldrive")
                            .tag(VaultLocationFilter.iCloud)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack {
                    Button {
                        selectedSettingsLocationID = settingsLocations.first?.id
                        showingSettingsSheet = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .help(L10n.string("sidebar.settings"))
                    .padding(.leading, 12)
                    .padding(.vertical, 10)
                    Spacer()
                }
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: ArcaLayout.sidebarWidth)
        } detail: {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    if model.warnings.isEmpty == false {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(model.warnings, id: \.self) { warning in
                                Label(warning, systemImage: "exclamationmark.triangle")
                                    .font(.system(size: ArcaTypography.bodySize))
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 8)
                            }

                            Divider()
                        }
                    }

                    noteStack
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .padding(.bottom, 12)
                }

                if let notice = model.transientNotice {
                    NoticeToastView(message: notice)
                        .padding(.top, 12)
                        .padding(.trailing, 14)
                        .transition(.move(edge: .top).combined(with: .opacity))
                        .zIndex(1)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .sheet(isPresented: $showingSettingsSheet) {
            SettingsWindowView(
                model: model,
                locations: $settingsLocations,
                selectedLocationID: $selectedSettingsLocationID
            )
        }
        .toolbar {
            ToolbarItemGroup {
                Button(action: model.createNote) {
                    Image(systemName: "plus")
                }
                .help(L10n.string("toolbar.new_note"))

                Button(action: model.refresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .help(L10n.string("toolbar.refresh"))

                Button(action: model.confirmDelete) {
                    Image(systemName: "trash")
                }
                .disabled(model.selectedNoteID == nil)
                .help(L10n.string("toolbar.delete"))
            }

            ToolbarItem {
                TextField(L10n.string("toolbar.search"), text: $model.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 220)
                    .font(.system(size: ArcaTypography.searchFieldSize))
            }

            ToolbarItem {
                Button(action: model.requestLock) {
                    Image(systemName: "lock")
                }
                .padding(.leading, 10)
                .help(L10n.string("toolbar.lock"))
            }
        }
        .confirmationDialog(
            L10n.string("delete.confirm.title"),
            isPresented: Binding(
                get: { model.deleteTarget != nil },
                set: { if $0 == false { model.deleteTarget = nil } }
            ),
            presenting: model.deleteTarget
        ) { _ in
            Button(L10n.string("delete.confirm.action"), role: .destructive) {
                model.deleteConfirmed()
            }
            Button(L10n.string("common.cancel"), role: .cancel) {
                model.deleteTarget = nil
            }
        } message: { note in
            Text(L10n.format("delete.confirm.message", note.title))
        }
    }

    private var noteHeaderPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(NoteBrowserTab.allCases) { tab in
                        Button {
                            model.selectedTab = tab
                        } label: {
                            ZStack {
                                if model.selectedTab == tab {
                                    RoundedRectangle(cornerRadius: 8)
                                        .fill(ArcaColors.tabActive)
                                }

                                Text(tab.title)
                                    .font(.system(size: ArcaTypography.tabSize))
                                    .foregroundStyle(model.selectedTab == tab ? Color.primary : Color.secondary)
                                    .padding(.vertical, 5)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(width: ArcaLayout.tabControlWidth)
                .frame(height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: ArcaLayout.noteIconSpacing) {
                Group {
                    if model.selectedNoteID != nil {
                        SecureNoteIcon()
                    } else {
                        Color.clear
                    }
                }
                .frame(width: ArcaLayout.noteIconWidth, height: 28)

                VStack(alignment: .leading, spacing: 3) {
                    if model.selectedNoteID != nil {
                        SelectableTextField(
                            placeholder: L10n.string("note.name.placeholder"),
                            text: $model.editorTitle,
                            focusToken: model.titleFocusToken
                        )
                        .frame(height: 20)
                        .onChange(of: model.editorTitle) { model.markEditorChanged() }

                        Text(L10n.string("note.kind.label"))
                            .font(.system(size: ArcaTypography.bodySize))
                            .foregroundStyle(.secondary)
                        Text(L10n.format("note.modified.label", model.selectedNote?.updatedAt.formatted(date: .abbreviated, time: .shortened) ?? "-"))
                            .font(.system(size: ArcaTypography.bodySize))
                            .foregroundStyle(.secondary)
                    } else {
                        Color.clear.frame(height: 20)
                        Color.clear.frame(height: 14)
                        Color.clear.frame(height: 14)
                    }
                }

                Spacer()
            }
        }
        .padding(16)
    }

    private var noteTablePane: some View {
        GeometryReader { proxy in
            let widths = columnWidths(for: proxy.size.width - 20)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    sortHeader(title: L10n.string("table.header.name"), column: .name, width: widths.name)
                    sortHeader(title: L10n.string("table.header.kind"), column: .kind, width: widths.kind)
                    sortHeader(title: L10n.string("table.header.date_modified"), column: .dateModified, width: widths.modified)
                    sortHeader(title: L10n.string("table.header.location"), column: .location, width: widths.location)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(model.filteredNotes.enumerated()), id: \.element.id) { index, note in
                            Button {
                                model.select(noteID: note.id, focusTarget: .content)
                            } label: {
                                HStack(spacing: 0) {
                                    rowCell(note.title, width: widths.name)
                                    rowCell(L10n.string("note.kind.secure"), width: widths.kind)
                                    rowCell(note.updatedAt.formatted(date: .abbreviated, time: .shortened), width: widths.modified)
                                    rowCell(model.currentLocationDisplayName, width: widths.location)
                                    Spacer(minLength: 0)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                                .padding(.horizontal, 10)
                                .padding(.vertical, 4)
                                .background(rowBackground(for: note, index: index))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .leading)

                            Divider()
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private var noteContentPane: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("contents.title"))
                .font(.system(size: ArcaTypography.headlineSize, weight: .semibold))

            if model.selectedNoteID != nil {
                FocusableTextEditor(
                    text: $model.editorContent,
                    focusToken: model.contentFocusToken,
                    font: .monospacedSystemFont(ofSize: ArcaTypography.editorSize, weight: .regular)
                )
                    .padding(8)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color(nsColor: .controlBackgroundColor).opacity(0.45))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.85), lineWidth: 1)
                    )
                    .onChange(of: model.editorContent) { model.markEditorChanged() }
            } else {
                Text(L10n.string("contents.empty"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
        .padding(16)
    }

    private var noteStack: some View {
        GeometryReader { proxy in
            let totalHeight = max(proxy.size.height, 420)
            let headerHeight: CGFloat = 148
            let handleHeight: CGFloat = 12
            let available = max(totalHeight - headerHeight - handleHeight, 160)
            let defaultTableHeight = available * 0.52
            let resolvedTableHeight = tablePaneHeight ?? defaultTableHeight
            let tableHeight = min(max(resolvedTableHeight, 72), max(72, available - 72))
            let contentHeight = max(72, available - tableHeight)

            VStack(spacing: 0) {
                noteHeaderPane
                    .frame(height: headerHeight)

                noteTablePane
                    .frame(height: tableHeight)

                resizeHandle(totalHeight: available, currentTableHeight: tableHeight)
                    .frame(height: handleHeight)

                noteContentPane
                    .frame(height: contentHeight)
            }
        }
    }

    private func resizeHandle(totalHeight: CGFloat, currentTableHeight: CGFloat) -> some View {
        Rectangle()
            .fill(Color.clear)
            .overlay(
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 44, height: 4)
            )
            .contentShape(Rectangle())
            .cursor(.resizeUpDown)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        if dragStartTableHeight == nil {
                            dragStartTableHeight = currentTableHeight
                            dragAvailableHeight = totalHeight
                            dragStartGlobalY = value.startLocation.y
                        }
                        let referenceHeight = dragAvailableHeight ?? totalHeight
                        let startTableHeight = dragStartTableHeight ?? currentTableHeight
                        let startGlobalY = dragStartGlobalY ?? value.startLocation.y
                        let deltaY = value.location.y - startGlobalY
                        let proposedTableHeight = startTableHeight + deltaY
                        let minTableHeight: CGFloat = 72
                        let maxTableHeight = max(minTableHeight, referenceHeight - 72)
                        let clampedTableHeight = min(max(proposedTableHeight, minTableHeight), maxTableHeight)
                        tablePaneHeight = clampedTableHeight
                    }
                    .onEnded { _ in
                        dragStartTableHeight = nil
                        dragAvailableHeight = nil
                        dragStartGlobalY = nil
                    }
            )
    }

    private func rowBackground(for note: NoteRecord, index: Int) -> Color {
        if model.selectedNoteID == note.id {
            return Color(nsColor: .selectedContentBackgroundColor).opacity(0.22)
        }

        return index.isMultiple(of: 2)
            ? Color(nsColor: .alternatingContentBackgroundColors.first ?? .controlBackgroundColor)
            : Color(nsColor: .alternatingContentBackgroundColors.dropFirst().first ?? .windowBackgroundColor)
    }

    private func sortHeader(title: String, column: NoteSortColumn, width: CGFloat) -> some View {
        Button {
            model.toggleSort(for: column)
        } label: {
            HStack(spacing: 4) {
                Text(title + model.sortIndicator(for: column))
                    .font(.system(size: ArcaTypography.tableSize, weight: .semibold))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .frame(width: width, alignment: .leading)
        }
        .buttonStyle(.plain)
    }

    private func rowCell(_ text: String, width: CGFloat) -> some View {
        Text(text)
            .font(.system(size: ArcaTypography.tableSize))
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private func columnWidths(for totalWidth: CGFloat) -> (name: CGFloat, kind: CGFloat, modified: CGFloat, location: CGFloat) {
        let safeWidth = max(totalWidth, 400)
        return (
            name: safeWidth * 0.34,
            kind: safeWidth * 0.18,
            modified: safeWidth * 0.28,
            location: safeWidth * 0.20
        )
    }
}

private struct NoticeToastView: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(message)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
    }
}

private struct SettingsLocation: Identifiable, Hashable {
    let id: UUID
    var name: String
    var path: String

    init(id: UUID = UUID(), name: String, path: String) {
        self.id = id
        self.name = name
        self.path = path
    }
}

private struct SettingsWindowView: View {
    @ObservedObject var model: AppModel
    @Binding var locations: [SettingsLocation]
    @Binding var selectedLocationID: SettingsLocation.ID?
    @Environment(\.dismiss) private var dismiss
    @State private var newMasterPassword = ""
    @State private var confirmMasterPassword = ""

    private var selectedIndex: Int? {
        guard let selectedLocationID else { return nil }
        return locations.firstIndex(where: { $0.id == selectedLocationID })
    }

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedLocationID) {
                    ForEach(locations) { location in
                        Label(location.name, systemImage: "externaldrive")
                            .tag(location.id)
                    }
                }
                .listStyle(.sidebar)

                Divider()

                HStack(spacing: 8) {
                    Button {
                        let newLocation = SettingsLocation(
                            name: L10n.string("settings.location.new_name"),
                            path: "~/ArcaVault"
                        )
                        locations.append(newLocation)
                        selectedLocationID = newLocation.id
                    } label: {
                        Image(systemName: "plus")
                    }

                    Button {
                        guard let selectedIndex else { return }
                        locations.remove(at: selectedIndex)
                        selectedLocationID = locations.first?.id
                    } label: {
                        Image(systemName: "minus")
                    }
                    .disabled(selectedIndex == nil)
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("settings.title"))
                    .font(.title2.weight(.semibold))

                GroupBox {
                    VStack(alignment: .leading, spacing: 14) {
                        Text(L10n.string("settings.auth.title"))
                            .font(.headline)

                        authStatusRow(
                            title: L10n.string("settings.auth.master.title"),
                            enabled: model.vaultPath.isEmpty == false && model.passwordUnlockAvailable
                        )

                        if model.passwordUnlockAvailable == false {
                            SecureField(L10n.string("settings.auth.master.new_password"), text: $newMasterPassword)
                            SecureField(L10n.string("settings.auth.master.confirm_password"), text: $confirmMasterPassword)

                            Button(L10n.string("settings.auth.master.enable")) {
                                model.enableMasterPassword(password: newMasterPassword, confirmation: confirmMasterPassword)
                                if model.authSettingsError == nil {
                                    newMasterPassword = ""
                                    confirmMasterPassword = ""
                                }
                            }
                        } else {
                            Button(L10n.string("settings.auth.master.disable")) {
                                model.disableMasterPassword()
                            }
                            .disabled(model.canDisableMasterPassword == false)
                        }

                        Divider()

                        authStatusRow(
                            title: L10n.string("settings.auth.device.title"),
                            enabled: model.deviceUnlockConfigured
                        )

                        if model.deviceUnlockConfigured {
                            Button(L10n.string("settings.auth.device.disable")) {
                                model.disableDeviceAuthentication()
                            }
                            .disabled(model.canDisableDeviceAuthentication == false)
                        } else {
                            Button(L10n.string("settings.auth.device.enable")) {
                                model.enableDeviceAuthentication()
                            }
                        }

                        Text(L10n.string("settings.auth.helper"))
                            .font(.callout)
                            .foregroundStyle(.secondary)

                        if let error = model.authSettingsError {
                            Text(error)
                                .font(.callout)
                                .foregroundStyle(.red)
                        } else if let notice = model.authSettingsNotice {
                            Text(notice)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(8)
                }

                if let selectedIndex {
                    GroupBox {
                        VStack(alignment: .leading, spacing: 14) {
                            LabeledContent(L10n.string("settings.location.name")) {
                                TextField("", text: $locations[selectedIndex].name)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 280)
                            }

                            LabeledContent(L10n.string("settings.location.path")) {
                                TextField("", text: $locations[selectedIndex].path)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(minWidth: 360)
                            }

                            Toggle(L10n.string("settings.location.sync"), isOn: .constant(true))
                            Toggle(L10n.string("settings.location.default"), isOn: .constant(selectedIndex == 0))
                        }
                        .padding(8)
                    }

                    Text(L10n.string("settings.placeholder"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView(
                        L10n.string("settings.empty_title"),
                        systemImage: "gearshape",
                        description: Text(L10n.string("settings.empty_message"))
                    )
                }

                Spacer()

                HStack {
                    Spacer()
                    Button(L10n.string("common.done")) {
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                }
            }
            .padding(24)
            .frame(minWidth: 560, minHeight: 420, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .onAppear {
                model.clearAuthSettingsMessages()
            }
        }
        .frame(minWidth: 860, minHeight: 520)
    }

    private func authStatusRow(title: String, enabled: Bool) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(enabled ? L10n.string("settings.auth.enabled") : L10n.string("settings.auth.disabled"))
                .foregroundStyle(enabled ? Color.green : Color.secondary)
        }
    }
}

private struct SecureNoteIcon: View {
    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: "doc.text.fill")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)

            Image(systemName: "lock.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.white)
                .padding(3)
                .background(Color(nsColor: .secondaryLabelColor), in: Circle())
                .offset(x: 2, y: 2)
        }
    }
}

private extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        onHover { inside in
            if inside {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}
