import Foundation
import Testing
@testable import SkyrCore

@Test(arguments: [0, 3, 8]) func byteCollectorAcceptsEmptySmallAndExactResponses(_ count: Int) async throws {
    let source = CountingBytes.Source(count: count)
    let result = try await BoundedBytes.collect(CountingBytes(source: source), maximum: 8)
    #expect(result == Data(repeating: 42, count: count))
}

@Test func byteCollectorStopsAtLimitPlusOneWithoutLengthHeader() async throws {
    let source = CountingBytes.Source(count: 30)
    do {
        _ = try await BoundedBytes.collect(CountingBytes(source: source), maximum: 8)
        Issue.record("Expected the byte limit to be enforced")
    } catch RemoteDriveError.tooLarge { }
    #expect(await source.consumed == 9)
}

@Test func byteCollectorChecksActualBodyDespiteSmallAdvertisedLength() async throws {
    let source = CountingBytes.Source(count: 30)
    do {
        _ = try await BoundedBytes.collect(CountingBytes(source: source), maximum: 8, expectedLength: 3)
        Issue.record("Expected actual byte count to enforce the limit")
    } catch RemoteDriveError.tooLarge { }
    #expect(await source.consumed == 9)
}

@Test func byteCollectorRejectsOversizedLengthBeforeConsumption() async throws {
    let source = CountingBytes.Source(count: 30)
    do {
        _ = try await BoundedBytes.collect(CountingBytes(source: source), maximum: 8, expectedLength: 30)
        Issue.record("Expected advertised limit rejection")
    } catch RemoteDriveError.tooLarge { }
    #expect(await source.consumed == 0)
}

@Test func byteCollectorPropagatesSourceFailureAndCancellation() async throws {
    let failing = CountingBytes.Source(count: 8, failureAt: 3)
    do {
        _ = try await BoundedBytes.collect(CountingBytes(source: failing), maximum: 8)
        Issue.record("Expected source error")
    } catch CountingBytes.SourceError.interrupted { }
    #expect(await failing.consumed == 3)

    let source = CountingBytes.Source(count: 8)
    let cancelled = Task {
        withUnsafeCurrentTask { $0?.cancel() }
        return try await BoundedBytes.collect(CountingBytes(source: source), maximum: 8)
    }
    do {
        _ = try await cancelled.value
        Issue.record("Expected cancellation")
    } catch is CancellationError { }
    #expect(await source.consumed == 0)
}

private nonisolated struct CountingBytes: AsyncSequence, Sendable {
    typealias Element = UInt8
    typealias AsyncIterator = Iterator
    let source: Source
    func makeAsyncIterator() -> Iterator { Iterator(source: source) }
    struct Iterator: AsyncIteratorProtocol {
        let source: Source
        mutating func next() async throws -> UInt8? { try await source.next() }
    }
    enum SourceError: Error { case interrupted }
    actor Source {
        let count: Int
        let failureAt: Int?
        private(set) var consumed = 0
        init(count: Int, failureAt: Int? = nil) { self.count = count; self.failureAt = failureAt }
        func next() throws -> UInt8? {
            if consumed == failureAt { throw SourceError.interrupted }
            guard consumed < count else { return nil }
            consumed += 1
            return 42
        }
    }
}
