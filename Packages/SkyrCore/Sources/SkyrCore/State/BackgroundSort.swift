import Foundation

/// Sorts immutable display snapshots without holding the main actor. Cancelling an outdated
/// request also interrupts its comparisons, rather than only discarding its eventual result.
public nonisolated enum BackgroundSort {
    public static func sorted<Element: Sendable, Comparator: SortComparator & Sendable>(
        _ elements: [Element], using comparators: [Comparator]
    ) async throws -> [Element] where Comparator.Compared == Element {
        try Task.checkCancellation()
        let worker = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let result = try elements.sorted { lhs, rhs in
                try Task.checkCancellation()
                for comparator in comparators {
                    let result = comparator.compare(lhs, rhs)
                    if result != .orderedSame { return result == .orderedAscending }
                }
                // Swift's stable sort preserves the displayed order when every key is equal.
                return false
            }
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await worker.value
            try Task.checkCancellation()
            return result
        } onCancel: {
            worker.cancel()
        }
    }
}
