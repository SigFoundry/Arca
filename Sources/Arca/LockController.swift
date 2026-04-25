import Foundation

@MainActor
final class LockController: ObservableObject {
    @Published var timeout: TimeInterval = 5 * 60
    private var timer: Timer?
    private(set) var lastActivityAt = Date()

    func start(onIdle: @escaping @MainActor () -> Void) {
        stop()
        lastActivityAt = Date()
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if Date().timeIntervalSince(self.lastActivityAt) >= self.timeout {
                    onIdle()
                }
            }
        }
    }

    func touch() {
        lastActivityAt = Date()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }
}
