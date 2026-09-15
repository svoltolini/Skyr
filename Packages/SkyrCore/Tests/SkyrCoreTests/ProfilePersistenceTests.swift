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

/// A local document as the build before #74 wrote it: no download membership in the plain library
/// fields nor in the compressed sync metadata.
private func documentBeforeDownloadMembership(_ data: Data) throws -> Data {
    func stripped(_ value: Any?) throws -> [String: Any] {
        var libraries = try #require(value as? [String: Any])
        for (id, library) in libraries {
            var fields = try #require(library as? [String: Any])
            #expect(fields["downloadedAlbums"] != nil && fields["downloadedPlaylists"] != nil)
            fields["downloadedAlbums"] = nil
            fields["downloadedPlaylists"] = nil
            libraries[id] = fields
        }
        return libraries
    }
    var document = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    document["libraries"] = try stripped(document["libraries"])
    let encoded = try #require(document["syncData"] as? String)
    let metadata = try ProfileStateSyncCodec.decompress(try #require(Data(base64Encoded: encoded)))
    var sync = try #require(JSONSerialization.jsonObject(with: metadata) as? [String: Any])
    sync["libraries"] = try stripped(sync["libraries"])
    document["syncData"] = try ProfileStateSyncCodec.compress(JSONSerialization.data(withJSONObject: sync)).base64EncodedString()
    return try JSONSerialization.data(withJSONObject: document)
}

@Test @MainActor func profileDocumentWrittenBeforeDownloadMembershipOpensAndAcceptsEdits() async throws {
    // #94: after the update the profile picker could not open a profile saved by the previous build.
    let fixture = try PersistenceFixture()
    let owner = try #require(fixture.store.owner)
    fixture.store.updateLibrary("drive") {
        $0.favourites = ["kept"]
        $0.playlists = [.init(id: "list", name: "List", trackIDs: ["kept", "too"], created: Date(timeIntervalSince1970: 1))]
    }
    fixture.store.updateLibrary("drive", recordingHistory: .played) { $0.played = ["kept"] }
    fixture.store.updateSettings { $0.appearance = "Dark" }
    fixture.store.lock()
    await fixture.settle()
    let file = fixture.directory.appending(path: "\(owner.id).json")
    try documentBeforeDownloadMembership(try Data(contentsOf: file)).write(to: file, options: .atomic)
    let reopened = fixture.reopen()
    #expect(reopened.activate(owner))
    #expect(reopened.persistenceFailure == nil)
    #expect(reopened.libraryState(for: "drive").favourites == ["kept"])
    #expect(reopened.libraryState(for: "drive").playlists.map(\.trackIDs) == [["kept", "too"]])
    #expect(reopened.libraryState(for: "drive").played == ["kept"])
    #expect(reopened.libraryState(for: "drive").downloadedAlbums.isEmpty)
    #expect(reopened.state.settings.appearance == "Dark")
    reopened.updateLibrary("drive") { $0.downloadedAlbums = ["album"]; $0.favourites.append("new") }
    #expect(reopened.persistenceFailure == nil)
    let third = fixture.reopen()
    #expect(third.activate(owner))
    #expect(third.libraryState(for: "drive").favourites == ["kept", "new"])
    #expect(third.libraryState(for: "drive").downloadedAlbums == ["album"])
    #expect(third.state.syncDigest == reopened.state.syncDigest)
    try await fixture.close()
}

@Test @MainActor func profileUnreadableDocumentCanBeOpenedWithoutItAndKeepsTheOriginalAside() async throws {
    let fixture = try PersistenceFixture()
    let owner = try #require(fixture.store.owner)
    fixture.store.updateLibrary("drive") { $0.favourites = ["a"] }
    fixture.store.lock()
    await fixture.settle()
    let file = fixture.directory.appending(path: "\(owner.id).json")
    let damaged = Data("{ not a document".utf8)
    try damaged.write(to: file, options: .atomic)
    let reopened = fixture.reopen()
    #expect(!reopened.activate(owner))
    let failure = try #require(reopened.persistenceFailure)
    #expect(failure.kind == .unreadable(profileID: owner.id))
    #expect(failure.title == "Profile couldn't be opened")
    #expect(failure.message.contains(owner.name))
    #expect(reopened.canOpenWithoutSavedData)
    // Dismissing the alert keeps the offer for the profile that was just admitted.
    reopened.dismissPersistenceError()
    #expect(reopened.persistenceFailure == nil)
    #expect(reopened.canOpenWithoutSavedData)
    #expect(reopened.openWithoutSavedData())
    #expect(reopened.activeID == owner.id)
    #expect(reopened.persistenceFailure == nil)
    #expect(!reopened.canOpenWithoutSavedData)
    #expect(reopened.libraryState(for: "drive").favourites.isEmpty)
    let kept = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        .filter { $0.lastPathComponent.hasPrefix("\(owner.id).unreadable-") }
    #expect(try Data(contentsOf: try #require(kept.first { $0.pathExtension == "json" })) == damaged)
    // Writes are no longer held: an edit is journaled, checkpointed and read back after a relaunch.
    reopened.updateLibrary("drive") { $0.favourites = ["fresh"] }
    #expect(reopened.persistenceFailure == nil)
    reopened.lock()
    await reopened.drainPersistence()
    let third = fixture.reopen()
    #expect(third.activate(owner))
    #expect(third.libraryState(for: "drive").favourites == ["fresh"])
    try await fixture.close()
}

@Test @MainActor func profileDocumentThatReadsAgainOpensWithItsDataAndWritesWithoutBeingSetAside() async throws {
    let fixture = try PersistenceFixture()
    let owner = try #require(fixture.store.owner)
    fixture.store.updateLibrary("drive") { $0.favourites = ["a"] }
    fixture.store.lock()
    await fixture.settle()
    let file = fixture.directory.appending(path: "\(owner.id).json")
    let original = try Data(contentsOf: file)
    try Data("{ not a document".utf8).write(to: file, options: .atomic)
    let reopened = fixture.reopen()
    #expect(!reopened.activate(owner))
    #expect(reopened.persistenceFailure?.kind == .unreadable(profileID: owner.id))
    reopened.dismissPersistenceError()
    // The document reads again, say after an update that understands it.
    try original.write(to: file, options: .atomic)
    #expect(reopened.activate(owner))
    #expect(reopened.persistenceFailure == nil)
    #expect(!reopened.canOpenWithoutSavedData)
    #expect(reopened.libraryState(for: "drive").favourites == ["a"])
    reopened.updateLibrary("drive") { $0.favourites = ["a", "b"] }
    #expect(reopened.persistenceFailure == nil)
    #expect(reopened.libraryState(for: "drive").favourites == ["a", "b"])
    let contents = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
    #expect(!contents.contains { $0.lastPathComponent.hasPrefix("\(owner.id).unreadable-") })
    let third = fixture.reopen()
    #expect(third.activate(owner))
    #expect(third.libraryState(for: "drive").favourites == ["a", "b"])
    try await fixture.close()
}

@Test @MainActor func profileUnreadableDocumentIsReportedOnceFromBackgroundReadsAndAgainWhenOpened() async throws {
    let fixture = try PersistenceFixture()
    let owner = try #require(fixture.store.owner)
    let other = try #require(fixture.store.create(name: "Other", avatar: .random(), pin: nil))
    try Data("{ not a document".utf8).write(to: fixture.directory.appending(path: "\(other.id).json"), options: .atomic)
    // iCloud reads every profile's document on each sync.
    #expect(fixture.store.storedState(id: other.id).libraries.isEmpty)
    let failure = try #require(fixture.store.persistenceFailure)
    #expect(failure.kind == .unreadable(profileID: other.id))
    #expect(failure.title == "Saved data couldn't be read")
    #expect(failure.message.contains("Other"))
    #expect(!fixture.store.canOpenWithoutSavedData)
    #expect(!fixture.store.openWithoutSavedData())
    fixture.store.dismissPersistenceError()
    _ = fixture.store.storedState(id: other.id)
    #expect(!fixture.store.storedStateIsPristine(id: other.id))
    #expect(fixture.store.persistenceFailure == nil)
    // Trying to open it reports again and offers the way in; the current profile stays open meanwhile.
    #expect(!fixture.store.activate(other))
    #expect(fixture.store.persistenceFailure?.title == "Profile couldn't be opened")
    #expect(fixture.store.canOpenWithoutSavedData)
    #expect(fixture.store.canOpenWithoutSavedData(other))
    #expect(!fixture.store.canOpenWithoutSavedData(owner))
    #expect(fixture.store.activeID == owner.id)
    #expect(fixture.store.openWithoutSavedData())
    #expect(fixture.store.activeID == other.id)
    #expect(fixture.store.persistenceFailure == nil)
    try await fixture.close()
}

@Test @MainActor func profileWithPINReportsUnreadableDocumentOnlyOnceAdmitted() async throws {
    let fixture = try PersistenceFixture()
    let locked = try #require(fixture.store.create(name: "Locked", avatar: .random(), pin: "1234"))
    try Data("{ not a document".utf8).write(to: fixture.directory.appending(path: "\(locked.id).json"), options: .atomic)
    // Without the PIN, or with a wrong one, the keypad is still the answer.
    #expect(!fixture.store.activate(locked))
    #expect(!fixture.store.activate(locked, pin: "0000"))
    #expect(fixture.store.persistenceFailure == nil)
    #expect(!fixture.store.canOpenWithoutSavedData(locked))
    #expect(!fixture.store.activate(locked, pin: "1234"))
    #expect(fixture.store.persistenceFailure?.kind == .unreadable(profileID: locked.id))
    #expect(fixture.store.canOpenWithoutSavedData(locked))
    #expect(fixture.store.openWithoutSavedData())
    #expect(fixture.store.activeID == locked.id)
    try await fixture.close()
}

@Test func profilePersistenceSetsAsideUnreadableFilesAndRetiresThemWithTheProfile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-set-aside-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProfilePersistence(directory: directory)
    let id = UUID().uuidString
    _ = try persistence.replace(ProfileState(), id: id)
    _ = try persistence.append(.settings(ProfileSettings(), ProfileRevision(time: 1, operation: "edit")), id: id)
    let file = directory.appending(path: "\(id).json")
    let damaged = Data("{ damaged".utf8)
    try damaged.write(to: file, options: .atomic)
    #expect(throws: (any Error).self) { _ = try persistence.load(id: id) }
    let kept = try persistence.setAside(id: id)
    #expect(kept.map(\.pathExtension).sorted() == ["journal", "json"])
    #expect(try Data(contentsOf: try #require(kept.first { $0.pathExtension == "json" })) == damaged)
    #expect(!FileManager.default.fileExists(atPath: file.path))
    #expect(persistence.setAsideURLs(id).map(\.lastPathComponent) == kept.map(\.lastPathComponent).sorted())
    let fresh = try persistence.load(id: id)
    #expect(fresh.state.libraries.isEmpty)
    #expect(fresh.token.sequence == 0)
    _ = try persistence.append(.settings(ProfileSettings(), ProfileRevision(time: 2, operation: "again")), id: id)
    #expect(try persistence.load(id: id).token.sequence == 1)
    try persistence.retire(id: id)
    #expect(persistence.setAsideURLs(id).isEmpty)
    #expect(try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).isEmpty)
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
