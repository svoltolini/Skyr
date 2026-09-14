import CloudKit
import Foundation
import Testing
@testable import SkyrCore

private func edited(_ base: ProfileState, time: TimeInterval, id: String, _ change: (inout ProfileState) -> Void) -> ProfileState {
    var result = base
    change(&result)
    result.recordChanges(from: base, at: Date(timeIntervalSince1970: time), operationID: id)
    return result
}

private func seedState() -> ProfileState {
    edited(ProfileState(), time: 10, id: "seed") {
        var library = LibraryState()
        library.favourites = ["a", "b"]
        library.played = ["a", "b"]
        library.recentAlbums = ["album-a"]
        library.searches = ["Jazz"]
        library.playlists = [.init(id: "list", name: "Original", trackIDs: ["a", "b", "c"], created: Date(timeIntervalSince1970: 1))]
        $0.libraries["drive"] = library
    }
}

@Test func profileMergePreservesIndependentFieldsCollectionsAndLibraries() {
    let base = seedState()
    let left = edited(base, time: 20, id: "left") {
        $0.settings.appearance = "Dark"
        $0.libraries["drive"]?.favourites.append("c")
        $0.libraries["drive"]?.playlists[0].name = "Renamed"
        $0.libraries["other"] = LibraryState()
        $0.libraries["other"]?.favourites = ["other-song"]
    }
    let right = edited(base, time: 21, id: "right") {
        $0.settings.gapless = false
        $0.libraries["drive"]?.playlists[0].trackIDs.append("d")
        $0.libraries["drive"]?.played.insert("e", at: 0)
        $0.libraries["drive"]?.recentAlbums.insert("album-b", at: 0)
        $0.libraries["drive"]?.searches.insert("Rock", at: 0)
    }
    let merged = left.merged(with: right)
    #expect(merged == right.merged(with: left))
    #expect(merged.settings.appearance == "Dark")
    #expect(!merged.settings.gapless)
    #expect(merged.libraries["drive"]?.favourites == ["a", "b", "c"])
    #expect(merged.libraries["drive"]?.playlists[0].name == "Renamed")
    #expect(merged.libraries["drive"]?.playlists[0].trackIDs == ["a", "b", "c", "d"])
    #expect(merged.libraries["drive"]?.played == ["e", "a", "b"])
    #expect(merged.libraries["drive"]?.recentAlbums == ["album-b", "album-a"])
    #expect(merged.libraries["drive"]?.searches == ["Rock", "Jazz"])
    #expect(merged.libraries["other"]?.favourites == ["other-song"])
}

@Test func profileMergeConflictingSettingsAndRenamesConvergeAtEqualTimes() {
    let base = seedState()
    let left = edited(base, time: 20, id: "A") { $0.settings.appearance = "Light"; $0.libraries["drive"]?.playlists[0].name = "A" }
    let right = edited(base, time: 20, id: "B") { $0.settings.appearance = "Dark"; $0.libraries["drive"]?.playlists[0].name = "B" }
    let merged = left.merged(with: right)
    #expect(merged == right.merged(with: left))
    #expect(merged.settings.appearance == "Dark")
    #expect(merged.libraries["drive"]?.playlists[0].name == "B")
    #expect(merged.merged(with: left).merged(with: right) == merged)
}

@Test func profileMergeDeletionSurvivesUnrelatedEditsAndStaleReplay() {
    let base = seedState()
    let deleted = edited(base, time: 20, id: "delete") {
        $0.libraries["drive"]?.favourites.removeAll { $0 == "a" }
        $0.libraries["drive"]?.playlists[0].trackIDs.removeAll { $0 == "b" }
        $0.libraries["drive"]?.searches = []
    }
    let unrelated = edited(base, time: 30, id: "unrelated") {
        $0.settings.shuffle = true
        $0.libraries["drive"]?.playlists[0].name = "New name"
    }
    let merged = deleted.merged(with: unrelated).merged(with: base)
    #expect(merged.libraries["drive"]?.favourites == ["b"])
    #expect(merged.libraries["drive"]?.playlists[0].trackIDs == ["a", "c"])
    #expect(merged.libraries["drive"]?.searches == [])
    #expect(merged.settings.shuffle)
    let readded = edited(merged, time: 5, id: "clock-rollback") { $0.libraries["drive"]?.favourites.append("a") }
    #expect(readded.merged(with: deleted).libraries["drive"]?.favourites == ["b", "a"])
}

@Test func profilePlaylistDeletionWinsConcurrentRenameAndRetainsOtherPlaylists() {
    let base = seedState()
    let deleted = edited(base, time: 20, id: "delete") { $0.libraries["drive"]?.playlists = [] }
    let other = edited(base, time: 30, id: "edit") {
        $0.libraries["drive"]?.playlists[0].name = "Changed concurrently"
        $0.libraries["drive"]?.playlists[0].trackIDs.append("d")
        $0.libraries["drive"]?.playlists.append(.init(id: "other", name: "Other", trackIDs: ["e"], created: Date(timeIntervalSince1970: 2)))
    }
    let merged = deleted.merged(with: other)
    #expect(merged.libraries["drive"]?.playlists.map(\.id) == ["other"])
    #expect(merged == other.merged(with: deleted))
    #expect(merged.merged(with: base) == merged)
}

@Test func profileTrackOrderingPreservesReorderConcurrentAppendAndRemoval() {
    let base = seedState()
    let reordered = edited(base, time: 20, id: "reorder") { $0.libraries["drive"]?.playlists[0].trackIDs = ["c", "a", "b"] }
    let appended = edited(base, time: 21, id: "append") { $0.libraries["drive"]?.playlists[0].trackIDs.append("d") }
    let removed = edited(base, time: 22, id: "remove") { $0.libraries["drive"]?.playlists[0].trackIDs.removeAll { $0 == "a" } }
    let merged = reordered.merged(with: appended).merged(with: removed)
    #expect(merged.libraries["drive"]?.playlists[0].trackIDs == ["c", "b", "d"])
    #expect(merged == removed.merged(with: reordered.merged(with: appended)))
    #expect(merged == appended.merged(with: removed).merged(with: reordered))
}

@Test func profileConcurrentInsertionsHaveStableOrderAndCanBeEditedAgain() {
    let base = seedState()
    let left = edited(base, time: 20, id: "A") { $0.libraries["drive"]?.playlists[0].trackIDs.insert("x", at: 1) }
    let right = edited(base, time: 20, id: "B") { $0.libraries["drive"]?.playlists[0].trackIDs.insert("y", at: 1) }
    let merged = left.merged(with: right)
    #expect(merged == right.merged(with: left))
    let order = merged.libraries["drive"]?.playlists[0].trackIDs ?? []
    #expect(Set(order) == ["a", "b", "c", "x", "y"])
    let next = edited(merged, time: 21, id: "C") { $0.libraries["drive"]?.playlists[0].trackIDs.insert("z", at: 2) }
    var expected = order
    expected.insert("z", at: 2)
    #expect(next.libraries["drive"]?.playlists[0].trackIDs == expected)
}

@Test func profileLegacyMigrationPreservesValuesOrderDuplicatesAndDeterministicTies() throws {
    var old = ProfileState()
    old.updatedAt = Date(timeIntervalSince1970: 10)
    old.settings.quality = "High"
    var library = LibraryState()
    library.favourites = ["b", "a"]
    library.playlists = [.init(id: "legacy", name: "Old", trackIDs: ["b", "a", "b"], created: Date(timeIntervalSince1970: 1))]
    old.libraries["drive"] = library
    let data = try JSONEncoder().encode(old)
    let decoded = try JSONDecoder().decode(ProfileState.self, from: data)
    let migrated = decoded.normalizedForSync()
    #expect(migrated.libraries == old.libraries)
    #expect(migrated.settings == old.settings)
    #expect(migrated == decoded.normalizedForSync())
    var anotherOld = old
    anotherOld.settings.quality = "Low"
    anotherOld.libraries["drive"]?.favourites.append("c")
    #expect(old.merged(with: anotherOld) == anotherOld.merged(with: old))
    #expect(Set(old.merged(with: anotherOld).libraries["drive"]?.favourites ?? []) == ["a", "b", "c"])
}

@Test func profileHistoryMergeRetainsIndependentRecentEventsAndExistingBounds() {
    let base = seedState()
    let left = edited(base, time: 20, id: "A") { $0.libraries["drive"]?.played.insert("x", at: 0) }
    let right = edited(base, time: 21, id: "B") { $0.libraries["drive"]?.played.insert("y", at: 0) }
    let merged = left.merged(with: right)
    #expect(merged.libraries["drive"]?.played == ["y", "x", "a", "b"])
    #expect(merged == right.merged(with: left))
    let full = edited(merged, time: 30, id: "full") { $0.libraries["drive"]?.played = (0..<110).map { "song-\($0)" } }
    #expect(full.libraries["drive"]?.played.count == 100)
    let cleared = edited(full, time: 40, id: "clear") { $0.libraries["drive"]?.played = [] }
    #expect(cleared.merged(with: full).libraries["drive"]?.played == [])
}

@Test func profileOrdinaryLargePlaylistEncodingSize() throws {
    let large = edited(ProfileState(), time: 20, id: "ordinary-library") {
        var library = LibraryState()
        library.playlists = [.init(id: "all", name: "All songs", trackIDs: (0..<5_000).map { "/Music/Artist/Album/Track-\($0).m4a" }, created: Date(timeIntervalSince1970: 1))]
        library.played = Array(library.playlists[0].trackIDs.prefix(100))
        $0.libraries["drive"] = library
    }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(large)
    print("Ordinary 5000-song state encoded bytes: \(data.count)")
    #expect(data.count < 900_000)
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let roundTrip = try decoder.decode(ProfileState.self, from: data)
    #expect(roundTrip.syncDigest == large.syncDigest)
    // An existing v1.0 reader ignores the additive syncData key and retains ordinary values.
    struct LegacyState: Decodable { var libraries: [String: LibraryState]; var settings: ProfileSettings }
    let legacy = try decoder.decode(LegacyState.self, from: data)
    #expect(legacy.libraries == large.libraries)
    #expect(legacy.settings == large.settings)
}

@Test func profileMetadataDecodedSizeUsesAnExplicitBound() {
    #expect(!ProfileStateSyncCodec.permitsDecodedSize(0))
    #expect(ProfileStateSyncCodec.permitsDecodedSize(1))
    #expect(ProfileStateSyncCodec.permitsDecodedSize(ProfileStateSyncCodec.maximumDecodedBytes))
    #expect(!ProfileStateSyncCodec.permitsDecodedSize(ProfileStateSyncCodec.maximumDecodedBytes + 1))
    #expect(!ProfileStateSyncCodec.permitsDecodedSize(Int.max))
    #expect(ProfileSequence.midpoint(Int.min, Int.max) == -1)
    #expect(ProfileSequence.midpoint(Int.min, Int.min + 2) == Int.min + 1)
    #expect(ProfileSequence.midpoint(Int.max - 2, Int.max) == Int.max - 1)
}

@MainActor private final class ProfileMergeFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-state-merge-\(UUID().uuidString)")
    let suite = "skyr.state.merge.\(UUID().uuidString)"
    let defaults: UserDefaults
    var profiles: ProfileStore
    let persistence: CloudPersistence
    var sync: CloudSync!
    var pages: [CloudChangePage] = []
    var conflicts: [ProfileState] = []
    var uploaded: [ProfileState] = []
    var duringConflict: (() -> Void)?

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults)
        persistence = CloudPersistence(directory: directory.appending(path: "cloud"))
        sync = makeSync()
        sync.profiles = profiles
        // Refresh is explicit; no debounce tasks can write after the fixture finishes.
        #expect(profiles.activate(try #require(profiles.owner)))
    }

    func makeSync() -> CloudSync {
        CloudSync(services: CloudServices(identity: { "account" }, sharedZones: { [] }, createZone: { _ in }, subscribe: {},
            changes: { _, token in self.pages.isEmpty ? .init(records: [], token: token) : self.pages.removeFirst() },
            modify: { _, records, deleted in
                var saved: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
                for record in records {
                    if record.recordType == "ProfileState", let data = record["document"] as? Data {
                        let state = try self.decode(data)
                        self.uploaded.append(state)
                        if !self.conflicts.isEmpty {
                            let server = try self.record(self.conflicts.removeFirst(), id: try #require(record["profileID"] as? String))
                            self.duringConflict?()
                            self.duringConflict = nil
                            saved[record.recordID] = .failure(CKError(.serverRecordChanged, userInfo: [CKRecordChangedErrorServerRecordKey: server]))
                            continue
                        }
                    }
                    saved[record.recordID] = .success(record)
                }
                return .init(saved: saved, deleted: Dictionary(uniqueKeysWithValues: deleted.map { ($0, .success(())) }))
            }), persistence: persistence)
    }

    func decode(_ data: Data) throws -> ProfileState {
        try ProfileCloudDocument.decode(data)
    }

    func record(_ state: ProfileState, id: String) throws -> CKRecord {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let record = CKRecord(recordType: "ProfileState", recordID: .init(recordName: "state-\(id)", zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)))
        record["document"] = try encoder.encode(state)
        record["profileID"] = id
        record["updatedAt"] = state.updatedAt
        return record
    }

    func relaunch() {
        // Do not flush the old instance: mutations must already have persisted their metadata.
        profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults)
        sync = makeSync()
        sync.profiles = profiles
    }

    func cleanUp() {
        profiles.lock()
        sync.accountChanged()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test @MainActor func profileOfflineRelaunchKeepsEditsAndDeletionMetadataBeforeDebounce() async throws {
    let fixture = try ProfileMergeFixture()
    defer { fixture.cleanUp() }
    let id = try #require(fixture.profiles.activeID)
    fixture.profiles.updateLibrary("drive") { $0.favourites = ["a", "b"] }
    let beforeDeletion = fixture.profiles.state
    fixture.profiles.updateLibrary("drive") { $0.favourites = ["b"] }
    fixture.profiles.updateSettings { $0.appearance = "Dark" }
    let digest = fixture.profiles.state.syncDigest
    fixture.relaunch()
    let restored = fixture.profiles.storedState(id: id)
    #expect(restored.syncDigest == digest)
    #expect(restored.merged(with: beforeDeletion).libraries["drive"]?.favourites == ["b"])
    #expect(restored.settings.appearance == "Dark")
    await fixture.sync.refresh(reason: "reconnect after offline edits")
    #expect(fixture.uploaded.last?.syncDigest == digest)
    fixture.uploaded = []
    fixture.relaunch()
    await fixture.sync.refresh(reason: "acknowledged state after relaunch")
    #expect(fixture.uploaded.isEmpty)
}

@Test @MainActor func profileCloudMergeUploadsIndependentEditsEvenWithTheSameDocumentDate() async throws {
    let fixture = try ProfileMergeFixture()
    defer { fixture.cleanUp() }
    await fixture.sync.refresh(reason: "baseline")
    let id = try #require(fixture.profiles.activeID)
    let base = fixture.profiles.state
    let time = base.updatedAt.timeIntervalSince1970 + 10
    let left = edited(base, time: time, id: "A") { $0.settings.appearance = "Dark" }
    let right = edited(base, time: time, id: "B") { $0.settings.gapless = false }
    #expect(fixture.profiles.applyRemote(left, id: id))
    fixture.uploaded = []
    fixture.pages = [.init(records: [.success(try fixture.record(right, id: id))], token: Data("merged".utf8))]
    await fixture.sync.refresh(reason: "merge equal-date documents")
    let saved = try #require(fixture.uploaded.last)
    #expect(saved.settings.appearance == "Dark")
    #expect(!saved.settings.gapless)
    #expect(saved.syncDigest == left.merged(with: right).syncDigest)
    fixture.uploaded = []
    await fixture.sync.refresh(reason: "idempotent refresh")
    #expect(fixture.uploaded.isEmpty)
}

@Test @MainActor func profileCloudConflictsMergeLatestLocalEditsAcrossSuccessiveRetries() async throws {
    let fixture = try ProfileMergeFixture()
    defer { fixture.cleanUp() }
    await fixture.sync.refresh(reason: "baseline")
    let base = fixture.profiles.state
    let time = base.updatedAt.timeIntervalSince1970 + 10
    let remote = edited(base, time: time, id: "remote") { $0.settings.gapless = false }
    let newerRemote = edited(remote, time: time + 1, id: "newer-remote") { $0.settings.repeatMode = "all" }
    fixture.profiles.updateSettings { $0.appearance = "Dark" }
    fixture.uploaded = []
    fixture.conflicts = [remote, newerRemote]
    fixture.duringConflict = { fixture.profiles.updateSettings { $0.shuffle = true } }
    await fixture.sync.refresh(reason: "server moved twice")
    #expect(fixture.uploaded.count == 3)
    let saved = try #require(fixture.uploaded.last)
    #expect(saved.settings.appearance == "Dark")
    #expect(!saved.settings.gapless)
    #expect(saved.settings.shuffle)
    #expect(saved.settings.repeatMode == "all")
    #expect(fixture.profiles.state.syncDigest == saved.syncDigest)
}

@Test @MainActor func profileCloudRepeatedConflictsRemainDurableAndRetryOnNextRefresh() async throws {
    let fixture = try ProfileMergeFixture()
    defer { fixture.cleanUp() }
    await fixture.sync.refresh(reason: "baseline")
    let base = fixture.profiles.state
    fixture.profiles.updateSettings { $0.appearance = "Dark" }
    fixture.uploaded = []
    fixture.conflicts = Array(repeating: base, count: 4)
    await fixture.sync.refresh(reason: "busy server")
    #expect(fixture.uploaded.count == 4)
    if case .failed = fixture.sync.status {} else { Issue.record("Repeated conflicts should remain visible.") }
    let digest = fixture.profiles.state.syncDigest
    fixture.relaunch()
    fixture.uploaded = []
    await fixture.sync.refresh(reason: "retry next launch")
    #expect(fixture.uploaded.last?.syncDigest == digest)
}

@Test @MainActor func profileUnavailableSavedDocumentCannotBeOpenedOverwrittenOrDiscardedAsPristine() throws {
    let fixture = try ProfileMergeFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    fixture.profiles.lock()
    let file = fixture.directory.appending(path: "profiles/\(owner.id).json")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    fixture.relaunch()
    #expect(!fixture.profiles.activate(owner))
    #expect(!fixture.profiles.storedStateIsPristine(id: owner.id))
    #expect(!fixture.profiles.applyRemote(seedState(), id: owner.id))
    var isDirectory = ObjCBool(false)
    #expect(FileManager.default.fileExists(atPath: file.path, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func profileLargeCloudEnvelopeRetainsPreviouslySyncableFifteenThousandSongPlaylist() throws {
    let large = edited(ProfileState(), time: 20, id: "ordinary-large-library") {
        var library = LibraryState()
        library.playlists = [.init(id: "all", name: "All songs", trackIDs: (0..<15_000).map { "/Music/Artist/Album/Track-\($0).m4a" }, created: Date(timeIntervalSince1970: 1))]
        $0.libraries["drive"] = library
    }
    let bytes = try ProfileCloudDocument.encode(large)
    print("Ordinary 15000-song CloudKit payload bytes: \(bytes.count)")
    #expect(bytes.count <= ProfileCloudDocument.maximumRecordBytes)
    #expect(try ProfileCloudDocument.decode(bytes).syncDigest == large.syncDigest)
    let legacyEncoder = JSONEncoder()
    legacyEncoder.dateEncodingStrategy = .iso8601
    let oldJSON = try legacyEncoder.encode(ProfileState())
    #expect(try ProfileCloudDocument.decode(oldJSON).libraries.isEmpty)
}

@Test func profileHistoryRetainsFirstItemReplayAndIndependentOfflineEvents() {
    let base = seedState()
    let other = edited(base, time: 20, id: "other-device") { $0.libraries["drive"]?.played.insert("other", at: 0) }
    var replay = base
    replay.recordChanges(from: base, at: Date(timeIntervalSince1970: 30), operationID: "device-A", recordingHistory: ("drive", .played))
    #expect(replay.merged(with: other).libraries["drive"]?.played == ["a", "other", "b"])
    #expect(replay.merged(with: other) == other.merged(with: replay))
}

@Test func profileHistoryCompactionKeepsObservationClockAcrossFiveThousandPlays() {
    var history = ProfileHistorySync()
    var old: [String] = []
    var stale = history
    for index in 0..<5_000 {
        let new = Array((["song-\(index)"] + old).prefix(100))
        history.update(from: old, to: new, revision: .init(time: Double(index), operation: "device-A"), forceFirst: true)
        old = new
        if index == 50 { stale = history }
    }
    #expect(history.entries.count == 100)
    #expect(history.observed.count == 1)
    #expect(history.merged(with: stale) == history)
    let beforeClear = history
    history.update(from: old, to: [], revision: .init(time: 6_000, operation: "device-A"))
    #expect(history.entries.isEmpty)
    #expect(history.merged(with: beforeClear).entries.isEmpty)
}

@Test func profileHistoryCompactionAndConcurrentRepeatRemainAssociative() {
    let base = seedState()
    let left = edited(base, time: 20, id: "A") { $0.libraries["drive"]?.played.insert("c", at: 0) }
    var right = base
    right.recordChanges(from: base, at: Date(timeIntervalSince1970: 30), operationID: "B", recordingHistory: ("drive", .played))
    let cleared = edited(right, time: 40, id: "C") { $0.libraries["drive"]?.played = [] }
    let merged = left.merged(with: right).merged(with: cleared)
    #expect(merged == left.merged(with: right.merged(with: cleared)))
    #expect(merged == cleared.merged(with: left).merged(with: right))
    #expect(merged.libraries["drive"]?.played == ["c"])
}

@Test @MainActor func profileRecoveryKeepsTargetRemovalsAndReceiptAcrossRelaunch() throws {
    let fixture = try ProfileMergeFixture()
    defer { fixture.cleanUp() }
    let id = try #require(fixture.profiles.activeID)
    fixture.profiles.updateLibrary("target") {
        $0.favourites = ["removed", "kept"]
        $0.playlists = [.init(id: "list", name: "Current", trackIDs: ["removed", "kept"], created: Date(timeIntervalSince1970: 1))]
    }
    fixture.profiles.updateLibrary("target") {
        $0.favourites = ["kept"]
        $0.playlists[0].trackIDs = ["kept"]
    }
    fixture.profiles.updateLibrary("legacy") {
        $0.favourites = ["removed", "imported"]
        $0.playlists = [.init(id: "list", name: "Old", trackIDs: ["removed", "imported"], created: Date(timeIntervalSince1970: 2))]
    }
    let source = fixture.profiles.libraryState(for: "legacy")
    #expect(fixture.profiles.recoverLibrary(from: "legacy", to: "target"))
    let target = fixture.profiles.libraryState(for: "target")
    #expect(target.favourites == ["kept", "imported"])
    #expect(target.playlists[0].name == "Current")
    #expect(target.playlists[0].trackIDs == ["kept", "imported"])
    #expect(fixture.profiles.libraryState(for: "legacy") == source)
    let digest = fixture.profiles.state.syncDigest
    fixture.relaunch()
    #expect(fixture.profiles.activate(try #require(fixture.profiles.profiles.first { $0.id == id })))
    #expect(fixture.profiles.hasRecoveredLibrary(from: "legacy", to: "target"))
    #expect(fixture.profiles.recoverLibrary(from: "legacy", to: "target"))
    #expect(fixture.profiles.state.syncDigest == digest)
}
