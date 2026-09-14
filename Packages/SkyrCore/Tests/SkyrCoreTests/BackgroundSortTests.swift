import Foundation
import Testing
@testable import SkyrCore

nonisolated private struct SortFixtureRow: Equatable, Sendable {
    let id: Int
    let title: String
    let group: Int
}

@Test func backgroundSortPreservesStableTiesAndMultipleColumnOrdering() async throws {
    let rows = [
        SortFixtureRow(id: 0, title: "Song 10", group: 2),
        SortFixtureRow(id: 1, title: "Song 2", group: 1),
        SortFixtureRow(id: 2, title: "Song 2", group: 1),
        SortFixtureRow(id: 3, title: "Song 3", group: 1),
    ]
    let order = [KeyPathComparator(\SortFixtureRow.group), KeyPathComparator(\SortFixtureRow.title, order: .reverse)]
    let result = try await BackgroundSort.sorted(rows, using: order)
    #expect(result == rows.sorted(using: order))
    #expect(result.filter { $0.title == "Song 2" }.map(\.id) == [1, 2])
    #expect(rows.map(\.id) == [0, 1, 2, 3], "Display sorting never mutates the original playlist order")
}

nonisolated private final class SortProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var started = false
    private var comparisons = 0
    private var mainThreadSeen = false

    func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        let first = lock.withLock {
            comparisons += 1
            mainThreadSeen = mainThreadSeen || Thread.isMainThread
            if started { return false }
            started = true
            return true
        }
        if first { _ = gate.wait(timeout: .now() + 5) }
        return lhs == rhs ? .orderedSame : (lhs < rhs ? .orderedAscending : .orderedDescending)
    }
    var hasStarted: Bool { lock.withLock { started } }
    var comparisonCount: Int { lock.withLock { comparisons } }
    var ranOnMainThread: Bool { lock.withLock { mainThreadSeen } }
    func release() { gate.signal() }
}

nonisolated private struct ProbeComparator: SortComparator {
    var order: SortOrder = .forward
    let probe: SortProbe
    func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult { probe.compare(lhs, rhs) }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.order == rhs.order && lhs.probe === rhs.probe }
    func hash(into hasher: inout Hasher) { hasher.combine(order); hasher.combine(ObjectIdentifier(probe)) }
}

@Test @MainActor func cancelledBackgroundSortStopsItsWorkerWithoutBlockingMainActor() async throws {
    let probe = SortProbe()
    defer { probe.release() }
    let operation = Task {
        try await BackgroundSort.sorted(Array((0..<15_000).reversed()), using: [ProbeComparator(probe: probe)])
    }
    // The first comparator waits on a background worker. The actor remains available to observe
    // that start and cancel it without depending on timing thresholds for sort performance.
    for _ in 0..<2_000 {
        if probe.hasStarted { break }
        try await Task.sleep(for: .milliseconds(1))
    }
    #expect(probe.hasStarted)
    #expect(!probe.ranOnMainThread)
    operation.cancel()
    probe.release()
    do {
        _ = try await operation.value
        Issue.record("A cancelled sort must not publish its completed snapshot")
    } catch is CancellationError {
        #expect(probe.comparisonCount <= 2, "Cancellation should stop further comparisons, not merely ignore the full sort")
    }
}
