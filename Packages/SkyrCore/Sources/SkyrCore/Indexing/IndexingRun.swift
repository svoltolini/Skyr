import Foundation

/// Identifies one scan, including its detached grouping work. Cancelling it prevents any later
/// artwork writes, even if a drive finishes a request after its task was cancelled.
nonisolated final class IndexingRun: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    private var active = true

    var isActive: Bool { lock.withLock { active } }

    func cancel() {
        lock.withLock { active = false }
    }

    func whileActive(_ operation: () -> Void) {
        lock.withLock {
            guard active else { return }
            operation()
        }
    }
}
