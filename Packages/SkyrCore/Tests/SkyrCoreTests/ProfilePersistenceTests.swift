import Foundation
import Testing
@testable import SkyrCore

nonisolated private final class PersistenceControls: @unchecked Sendable {
    private let lock = NSLock()
    private var journalFailure = false
    private var snapshotFailure = false
    private var journalThrowsAfterWrite = false
    private var cleanupFailure = false
    private var journalSizes: [Int] = []
    private var mainThreadEncoding = false

    func failJournal(_ value: Bool) { lock.withLock { journalFailure = value } }
    func failSnapshot(_ value: Bool) { lock.withLock { snapshotFailure = value } }
    func throwAfterJournalWrite() { lock.withLock { journalThrowsAfterWrite = true } }
    func failCleanup(_ value: Bool) { lock.withLock { cleanupFailure = value } }
    var sizes: [Int] { lock.withLock { journalSizes } }
    var encodedOnMainThread: Bool { lock.withLock { mainThreadEncoding } }

    var hooks: ProfilePersistenceHooks {
        .init(beforeSnapshotEncoding: { self.lock.withLock { self.mainThreadEncoding = self.mainThreadEncoding || Thread.isMainThread } },
              writeJournal: { data, url in
                  let behavior = self.lock.withLock { (self.journalFailure, self.journalThrowsAfterWrite) }
                  if behavior.0 { throw CocoaError(.fileWriteOutOfSpace) }
                  try data.write(to: url, options: .atomic)
                  self.lock.withLock { self.journalSizes.append(data.count) }
                  if behavior.1 { throw CocoaError(.fileWriteUnknown) }
              },
              writeSnapshot: { data, url in
                  if self.lock.withLock({ self.snapshotFailure }) { throw CocoaError(.fileWriteOutOfSpace) }
                  try data.write(to: url, options: .atomic)
              },
              removeJournal: { url in
                  if self.lock.withLock({ self.cleanupFailure }) { throw CocoaError(.fileWriteNoPermission) }
                  try FileManager.default.removeItem(at: url)
              })
    }
}

nonisolated private final class SnapshotGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var armed = true
    private var entered = false
    private var released = false

    func pauseOnce() {
        let wait = lock.withLock {
            guard armed else { return false }
            armed = false
            entered = true
            return true
        }
        if wait { _ = semaphore.wait(timeout: .now() + 10) }
    }
    var isPaused: Bool { lock.withLock { entered } }
    func release() {
        let signal = lock.withLock { if released { return false }; released = true; return true }
        if signal { semaphore.signal() }
    }
    func awaitPause() async throws {
        for _ in 0..<2_000 {
            if isPaused { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.fileReadUnknown)
    }
}

@MainActor private final class PersistenceFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-persistence-\(UUID().uuidString)")
    let suite = "skyr.persistence.\(UUID().uuidString)"
    let defaults: UserDefaults
    let store: ProfileStore
    var reopened: [ProfileStore] = []

    init(hooks: ProfilePersistenceHooks = .init()) throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        store = ProfileStore(directory: directory, defaults: defaults, persistenceHooks: hooks)
        #expect(store.activate(try #require(store.owner)))
    }

    func reopen() -> ProfileStore {
        let next = ProfileStore(directory: directory, defaults: defaults)
        reopened.append(next)
        return next
    }

    func settle() async {
        await store.drainPersistence()
        for _ in 0..<5 { await Task.yield() }
    }

    func close() async throws {
        for current in [store] + reopened { current.lock() }
        for current in [store] + reopened { await current.drainPersistence() }
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
}

@Test @MainActor func profileJournalReplaysOriginalIntentsBeforeCheckpoint() async throws {
    let gate = SnapshotGate()
    defer { gate.release() }
    let fixture = try PersistenceFixture(hooks: .init(beforeSnapshotEncoding: { gate.pauseOnce() }))
    let store = fixture.store
    let owner = try #require(store.owner)
    store.updateLibrary("drive") {
        $0.favourites = ["a", "b"]
        $0.playlists = [.init(id: "list", name: "List", trackIDs: ["a", "b"], created: Date(timeIntervalSince1970: 1))]
    }
    store.flushSave()
    try await gate.awaitPause()
    store.updateLibrary("drive") { $0.favourites.removeFirst(); $0.playlists[0].trackIDs.reverse() }
    store.updateLibrary("drive", recordingHistory: .played) { $0.played = ["a"] }
    store.updateLibrary("drive", recordingHistory: .played) { $0.played = ["a"] }
    store.updateLibrary("drive", recordingHistory: .searches) { $0.searches = ["Jazz"] }
    store.updateLibrary("drive") { $0.searches = [] }
    store.updateSettings { $0.shuffle = true; $0.appearance = "Dark" }
    let expected = store.state
    let next = fixture.reopen()
    #expect(next.activate(owner))
    #expect(next.state.syncDigest == expected.syncDigest)
    #expect(next.libraryState(for: "drive").favourites == ["b"])
    #expect(next.libraryState(for: "drive").played == ["a"])
    next.flushSave()
    await next.drainPersistence()
    gate.release()
    await fixture.settle()
    let third = fixture.reopen()
    #expect(third.activate(owner))
    #expect(third.state.syncDigest == expected.syncDigest)
    try await fixture.close()
}

@Test @MainActor func profileOlderSnapshotCannotOverwriteRemoteCheckpoint() async throws {
    let gate = SnapshotGate()
    defer { gate.release() }
    let fixture = try PersistenceFixture(hooks: .init(beforeSnapshotEncoding: { gate.pauseOnce() }))
    let owner = try #require(fixture.store.owner)
    fixture.store.updateLibrary("drive") { $0.favourites = ["local"] }
    fixture.store.flushSave()
    try await gate.awaitPause()
    let previous = fixture.store.state
    var remote = previous
    remote.settings.shuffle = true
    remote.recordChanges(from: previous, operationID: "remote")
    #expect(fixture.store.applyRemote(remote, id: owner.id))
    let expected = fixture.store.state.syncDigest
    gate.release()
    await fixture.settle()
    let reopened = fixture.reopen()
    #expect(reopened.activate(owner))
    #expect(reopened.state.syncDigest == expected)
    #expect(reopened.state.settings.shuffle)
    #expect(reopened.libraryState(for: "drive").favourites == ["local"])
    try await fixture.close()
}

@Test @MainActor func profileDeletionRetiresPausedSnapshotWithoutResurrection() async throws {
    let gate = SnapshotGate()
    defer { gate.release() }
    let fixture = try PersistenceFixture(hooks: .init(beforeSnapshotEncoding: { gate.pauseOnce() }))
    let owner = try #require(fixture.store.owner)
    fixture.store.updateLibrary("drive") { $0.favourites = ["a"] }
    fixture.store.flushSave()
    try await gate.awaitPause()
    #expect(fixture.store.removeRemote(id: owner.id))
    gate.release()
    await fixture.settle()
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "\(owner.id).json").path))
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "\(owner.id).journal").path))
    #expect(!fixture.reopen().profiles.contains(where: { $0.id == owner.id }))
    try await fixture.close()
}

@Test @MainActor func profileJournalFailureRejectsTheEditAndReloadsConsumers() async throws {
    let controls = PersistenceControls()
    let fixture = try PersistenceFixture(hooks: controls.hooks)
    let before = fixture.store.state.syncDigest
    var reloads = 0
    fixture.store.onRemoteState = { reloads += 1 }
    controls.failJournal(true)
    fixture.store.updateLibrary("drive") { $0.favourites = ["rejected"] }
    #expect(fixture.store.state.syncDigest == before)
    #expect(fixture.store.persistenceError != nil)
    #expect(reloads == 1)
    controls.failJournal(false)
    fixture.store.updateSettings { $0.shuffle = true }
    #expect(fixture.store.persistenceError == nil)
    let reopened = fixture.reopen()
    #expect(reopened.activate(try #require(reopened.owner)))
    #expect(reopened.libraryState(for: "drive").favourites.isEmpty)
    #expect(reopened.state.settings.shuffle)
    try await fixture.close()
}

@Test @MainActor func profileSnapshotFailureKeepsJournalAndSuccessfulRetryClearsError() async throws {
    let controls = PersistenceControls()
    let fixture = try PersistenceFixture(hooks: controls.hooks)
    controls.failSnapshot(true)
    fixture.store.updateLibrary("drive", recordingHistory: .played) { $0.played = ["kept"] }
    fixture.store.flushSave()
    await fixture.settle()
    #expect(fixture.store.persistenceError != nil)
    let expected = fixture.store.state.syncDigest
    let reopened = fixture.reopen()
    #expect(reopened.activate(try #require(reopened.owner)))
    #expect(reopened.state.syncDigest == expected)
    controls.failSnapshot(false)
    fixture.store.flushSave()
    await fixture.settle()
    #expect(fixture.store.persistenceError == nil)
    #expect(!controls.encodedOnMainThread)
    try await fixture.close()
}

@Test @MainActor func profileOldSnapshotFailureCannotReportAgainstNewerEditOrSession() async throws {
    for changeSession in [false, true] {
        let controls = PersistenceControls()
        let gate = SnapshotGate()
        defer { gate.release() }
        var hooks = controls.hooks
        hooks.beforeSnapshotEncoding = { gate.pauseOnce() }
        let fixture = try PersistenceFixture(hooks: hooks)
        let other = try #require(fixture.store.create(name: "Other", avatar: .random(), pin: nil))
        fixture.store.updateLibrary("drive") { $0.favourites = ["old"] }
        controls.failSnapshot(true)
        fixture.store.flushSave()
        try await gate.awaitPause()
        if changeSession {
            #expect(fixture.store.activate(other))
        } else {
            fixture.store.updateLibrary("drive") { $0.favourites = ["new"] }
        }
        gate.release()
        await fixture.settle()
        #expect(fixture.store.persistenceError == nil)
        if changeSession { #expect(fixture.store.libraryState(for: "drive").favourites.isEmpty) }
        else { #expect(fixture.store.libraryState(for: "drive").favourites == ["new"]) }
        controls.failSnapshot(false)
        try await fixture.close()
    }
}

@Test @MainActor func profileAcknowledgedJournalCleanupFailureDoesNotReplayHistoryAgain() async throws {
    let controls = PersistenceControls()
    let fixture = try PersistenceFixture(hooks: controls.hooks)
    controls.failCleanup(true)
    fixture.store.updateLibrary("drive", recordingHistory: .played) { $0.played = ["a"] }
    fixture.store.updateLibrary("drive", recordingHistory: .played) { $0.played = ["a"] }
    fixture.store.flushSave()
    await fixture.settle()
    let expected = fixture.store.state.syncDigest
    let reopened = fixture.reopen()
    #expect(reopened.activate(try #require(reopened.owner)))
    #expect(reopened.state.syncDigest == expected)
    #expect(reopened.libraryState(for: "drive").played == ["a"])
    try await fixture.close()
}

@Test @MainActor func profileCleanupCanDeleteAcknowledgedEntryDuringLoad() async throws {
    let gate = SnapshotGate()
    let removed = DispatchSemaphore(value: 0)
    defer { gate.release() }
    var hooks = ProfilePersistenceHooks()
    hooks.removeJournal = { url in
        gate.pauseOnce()
        try FileManager.default.removeItem(at: url)
        removed.signal()
    }
    hooks.afterJournalEnumeration = {
        if gate.isPaused { gate.release(); _ = removed.wait(timeout: .now() + 2) }
    }
    let fixture = try PersistenceFixture(hooks: hooks)
    fixture.store.updateLibrary("drive") { $0.favourites = ["a"] }
    fixture.store.flushSave()
    try await gate.awaitPause()
    // The loader enumerates while cleanup is paused, then cleanup removes the file before read.
    let reader = ProfilePersistence(directory: fixture.directory, hooks: hooks)
    let saved = try reader.load(id: try #require(fixture.store.activeID))
    #expect(saved.state.libraries["drive"]?.favourites == ["a"])
    await fixture.settle()
    try await fixture.close()
}

@Test @MainActor func profileMissingBaseAndUnreadableJournalPreserveOriginalFiles() async throws {
    for removeBase in [false, true] {
        let fixture = try PersistenceFixture()
        let owner = try #require(fixture.store.owner)
        fixture.store.updateLibrary("drive") { $0.favourites = ["a"] }
        let folder = fixture.directory.appending(path: "\(owner.id).journal")
        let journal = try #require(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        let original = try Data(contentsOf: journal)
        if removeBase { try FileManager.default.removeItem(at: fixture.directory.appending(path: "\(owner.id).json")) }
        else { try Data("unfinished document".utf8).write(to: journal, options: .atomic) }
        let reopened = fixture.reopen()
        #expect(!reopened.activate(owner))
        #expect(reopened.persistenceError != nil)
        #expect(FileManager.default.fileExists(atPath: journal.path))
        if removeBase { #expect(try Data(contentsOf: journal) == original) }
        else { #expect(try Data(contentsOf: journal) == Data("unfinished document".utf8)) }
        // The live writer still has the complete accepted state and can repair its own snapshot.
        try await fixture.close()
    }
}

@Test @MainActor func profileAtomicWriteReportedFailureStillAcceptsConfirmedJournal() async throws {
    let controls = PersistenceControls()
    let fixture = try PersistenceFixture(hooks: controls.hooks)
    controls.throwAfterJournalWrite()
    fixture.store.updateSettings { $0.shuffle = true }
    #expect(fixture.store.persistenceError == nil)
    #expect(fixture.store.state.settings.shuffle)
    let reopened = fixture.reopen()
    #expect(reopened.activate(try #require(reopened.owner)))
    #expect(reopened.state.settings.shuffle)
    try await fixture.close()
}

@Test @MainActor func profileFullReplacementFailureRejectsRemoteAcknowledgementAndRecoveryReceipt() async throws {
    let controls = PersistenceControls()
    let fixture = try PersistenceFixture(hooks: controls.hooks)
    let owner = try #require(fixture.store.owner)
    fixture.store.updateLibrary("legacy") { $0.favourites = ["saved"] }
    let before = fixture.store.state
    var remote = before
    remote.settings.shuffle = true
    remote.recordChanges(from: before, operationID: "remote")
    controls.failSnapshot(true)
    #expect(!fixture.store.applyRemote(remote, id: owner.id))
    #expect(fixture.store.state.syncDigest == before.syncDigest)
    #expect(!fixture.store.recoverLibrary(from: "legacy", to: "current"))
    #expect(!fixture.store.hasRecoveredLibrary(from: "legacy", to: "current"))
    let reopened = fixture.reopen()
    #expect(reopened.activate(owner))
    #expect(reopened.state.syncDigest == before.syncDigest)
    controls.failSnapshot(false)
    #expect(fixture.store.recoverLibrary(from: "legacy", to: "current"))
    #expect(fixture.store.hasRecoveredLibrary(from: "legacy", to: "current"))
    let recovered = fixture.reopen()
    #expect(recovered.activate(owner))
    #expect(recovered.hasRecoveredLibrary(from: "legacy", to: "current"))
    #expect(recovered.libraryState(for: "legacy").favourites == ["saved"])
    #expect(recovered.libraryState(for: "current").favourites == ["saved"])
    try await fixture.close()
}

@Test @MainActor func profileLargeLibraryHistoryJournalStaysSmall() async throws {
    let controls = PersistenceControls()
    let fixture = try PersistenceFixture(hooks: controls.hooks)
    fixture.store.updateLibrary("drive") {
        $0.playlists = [.init(id: "all", name: "All", trackIDs: (0..<15_000).map { "/Music/\($0).m4a" }, created: Date(timeIntervalSince1970: 1))]
    }
    fixture.store.updateLibrary("drive", recordingHistory: .played) { $0.played = ["/Music/1.m4a"] }
    let journalBytes = try #require(controls.sizes.last)
    #expect(journalBytes < 1_024)
    print("PROFILE_JOURNAL songs=15000 history_bytes=\(journalBytes)")
    try await fixture.close()
}
