import AppKit
import Darwin
import SwiftUI

@MainActor
final class AboutPanelController {
    static let shared = AboutPanelController()

    private var panel: NSPanel?

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.isReleasedWhenClosed = false
        panel.title = L10n.format("menu.about", L10n.string("app.name"))
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.center()
        panel.contentViewController = NSHostingController(rootView: AboutView())
        return panel
    }
}

@MainActor
final class SingleInstanceController {
    private var lockFileDescriptor: Int32 = -1

    func acquireOrActivateExistingInstance() -> Bool {
        let lockURL = FileManager.default.temporaryDirectory.appendingPathComponent("arca.app.lock")
        let fd = open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else {
            return true
        }

        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFileDescriptor = fd
            return true
        }

        close(fd)
        activateExistingInstance()
        return false
    }

    deinit {
        if lockFileDescriptor >= 0 {
            flock(lockFileDescriptor, LOCK_UN)
            close(lockFileDescriptor)
        }
    }

    private func activateExistingInstance() {
        let currentPID = ProcessInfo.processInfo.processIdentifier
        let processName = ProcessInfo.processInfo.processName
        let bundleIdentifier = Bundle.main.bundleIdentifier

        let candidates: [NSRunningApplication]
        if let bundleIdentifier {
            candidates = NSRunningApplication.runningApplications(withBundleIdentifier: bundleIdentifier)
        } else {
            candidates = NSWorkspace.shared.runningApplications.filter {
                $0.localizedName == processName
            }
        }

        if let app = candidates.first(where: { $0.processIdentifier != currentPID }) {
            app.activate(options: [.activateAllWindows])
        }
    }
}

@MainActor
final class ArcaAppDelegate: NSObject, NSApplicationDelegate {
    private let singleInstanceController = SingleInstanceController()
    private let windowCoordinator = ArcaWindowCoordinator()
    private var closeAlreadyAuthorized = false

    override init() {
        super.init()
        windowCoordinator.onApprovedClose = { [weak self] in
            self?.closeAlreadyAuthorized = true
        }
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        guard singleInstanceController.acquireOrActivateExistingInstance() else {
            NSApp.terminate(nil)
            return
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        bringAppToFront()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        bringAppToFront()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        bringAppToFront()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if closeAlreadyAuthorized {
            closeAlreadyAuthorized = false
            return .terminateNow
        }
        return AppModel.shared.canCloseWindow() ? NSApplication.TerminateReply.terminateNow : NSApplication.TerminateReply.terminateCancel
    }

    private func bringAppToFront() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        for window in NSApp.windows where (window is NSPanel) == false {
            window.collectionBehavior.remove(.transient)
            window.delegate = windowCoordinator
        }

        if let mainWindow = NSApp.windows.first(where: { ($0 is NSPanel) == false && $0.isVisible }) {
            if mainWindow.canBecomeKey {
                mainWindow.makeKeyAndOrderFront(nil)
            } else {
                mainWindow.orderFront(nil)
            }
        }
    }
}

@MainActor
final class ArcaWindowCoordinator: NSObject, NSWindowDelegate {
    var onApprovedClose: (() -> Void)?

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        let allowed = AppModel.shared.canCloseWindow()
        if allowed {
            onApprovedClose?()
        }
        return allowed
    }
}

@main
struct ArcaApp: App {
    @NSApplicationDelegateAdaptor(ArcaAppDelegate.self) private var appDelegate

    var body: some Scene {
        Window(L10n.string("app.name"), id: "main") {
            ContentView(model: .shared)
        }
        .windowResizability(.contentSize)
        .commands {
            ArcaAppCommands(model: .shared)
        }
    }
}

struct ArcaAppCommands: Commands {
    @ObservedObject var model: AppModel

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L10n.format("menu.about", L10n.string("app.name"))) {
                AboutPanelController.shared.show()
            }
        }
        CommandGroup(replacing: .newItem) { }
        CommandGroup(replacing: .saveItem) {
            Button(L10n.string("menu.save")) {
                _ = model.saveCurrentNote()
            }
            .keyboardShortcut("s", modifiers: [.command])
            .disabled(model.isLocked || model.selectedNoteID == nil)
        }
    }
}

private struct AboutView: View {
    private let repositoryURL = URL(string: "https://github.com/SigFoundry/Arca")!

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 112, height: 112)

            Text(L10n.string("app.name"))
                .font(.system(size: 24, weight: .semibold))

            Text(L10n.string("about.tagline"))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            Text(L10n.format("about.version", appVersionString))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)

            Text(L10n.string("about.license"))
                .font(.system(size: 11, weight: .medium))
                .padding(.top, 2)

            HStack(spacing: 8) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(L10n.string("about.repository"))
                    .font(.system(size: 12))

                Button {
                    NSWorkspace.shared.open(repositoryURL)
                } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help(repositoryURL.absoluteString)
            }
            .padding(.top, 1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24)
        .padding(.top, 24)
        .padding(.bottom, 18)
        .frame(width: 320, height: 380)
    }

    private var appVersionString: String {
        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String

        if let shortVersion, shortVersion.isEmpty == false {
            return shortVersion
        }
        if let bundleVersion, bundleVersion.isEmpty == false {
            return bundleVersion
        }
        return "1.0"
    }
}
