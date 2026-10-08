import AppKit

/// Keep the normal event loop alive while saving and cancelling work. AppKit's
/// terminateLater enters a modal loop that can starve MainActor tasks, including
/// the task meant to reply to that very quit request.
@MainActor
final class ApplicationTermination {
    private enum State { case running, cleaningUp, ready }
    private var state = State.running
    private var cleanupTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private let gracePeriod: Duration
    private let stop: () -> Void
    private let cleanup: () async -> Void
    private let terminate: () -> Void

    var isQuitting: Bool { state != .running }

    init(gracePeriod: Duration, stop: @escaping () -> Void,
         cleanup: @escaping () async -> Void, terminate: @escaping () -> Void) {
        self.gracePeriod = gracePeriod
        self.stop = stop
        self.cleanup = cleanup
        self.terminate = terminate
    }

    func request() -> NSApplication.TerminateReply {
        switch state {
        case .ready: return .terminateNow
        case .cleaningUp: return .terminateCancel
        case .running:
            state = .cleaningUp
            stop()
            cleanupTask = Task { [self] in
                await cleanup()
                finish()
            }
            deadlineTask = Task { [self] in
                do { try await Task.sleep(for: gracePeriod) }
                catch { return }
                finish()
            }
            // Retry termination ourselves once cleanup finishes. Repeated
            // Command-Q requests neither restart cleanup nor add modal loops.
            return .terminateCancel
        }
    }

    private func finish() {
        guard state == .cleaningUp else { return }
        state = .ready
        cleanupTask?.cancel()
        deadlineTask?.cancel()
        cleanupTask = nil
        deadlineTask = nil
        terminate()
    }
}
