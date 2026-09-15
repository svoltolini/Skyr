import Foundation
import Testing
@testable import SkyrCore

/// A manager over a scratch folder whose transfers are captured rather than started, so a test can
/// tell a song that was attached from disk apart from one that would have been fetched again.
@MainActor
private final class ReconcileHarness {
    let directory: URL
    let delegate = DownloadDelegate()
    private(set) var manager: DownloadManager!
    private(set) var started: [URLSessionDownloadTask] = []
    private var session: URLSession?
    private var completeRestoration: (@Sendable ([URLSessionTask]) -> Void)?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "SkyrReconcile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        open()
    }

    func open() {
        manager = DownloadManager(directory: directory, configuration: .ephemeral, delegate: delegate,
                                  restoreTasks: { [weak self] session, completion in
            self?.session = session
            self?.completeRestoration = completion
        }, resumeTask: { [weak self] task in
            if self?.started.contains(where: { $0 === task }) == false { self?.started.append(task) }
        })
        manager.driveIDProvider = { "nas-a" }
        manager.activeProfileID = "listener"
        manager.knownProfileIDsProvider = { ["listener"] }
    }

    /// The session reports no tasks from an earlier launch; the manager's restoration completes.
    func restore() async throws {
        completeRestoration?([])
        completeRestoration = nil
        try await Task.sleep(for: .milliseconds(30))
    }

    @discardableResult
    func reconcile(albums: [Album], playlists: [Playlist] = [], unresolvedAlbumIDs: [String] = []) -> DownloadReconciliation {
        manager.reconcile(albums: albums.map(\.id) + unresolvedAlbumIDs, playlists: playlists.map(\.id), driveID: "nas-a",
                          album: { id in albums.first { $0.id == id } }, playlist: { id in playlists.first { $0.id == id } })
    }

    func queue(_ owner: DownloadOwner) {
        manager.download(owner, driveID: "nas-a") { _ in URL(string: "https://nas.example:5001/never-requested")! }
    }

    /// A finished song as the downloader names it, with the given contents.
    @discardableResult
    func writeFile(for track: Track, driveID: String = "nas-a", contents: Data, attempt: String? = UUID().uuidString) throws -> String {
        let name = (attempt.map { $0 + "-" } ?? "") + DownloadManager.fileName(for: track, driveID: driveID)
        try contents.write(to: directory.appending(path: name))
        return name
    }

    func writeManifest(_ records: [DownloadRecord]) throws {
        try JSONEncoder().encode(records).write(to: directory.appending(path: "downloads.json"))
    }

    func savedManifest() throws -> [DownloadRecord] {
        try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: directory.appending(path: "downloads.json")))
    }

    func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: directory.appending(path: name).path)
    }

    func stop() {
        manager = nil
        session?.invalidateAndCancel()
        session = nil
        started = []
    }

    func close() {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func bytes(_ count: Int, filler: UInt8 = 0x5A) -> Data { Data(repeating: filler, count: count) }

/// A sample album cut to a few songs of known size, so a file on disk can be judged complete or not.
/// Different seeds give different album and song ids.
private func reconcileAlbum(_ seed: Int = 0, sizes: [Int] = [8192, 4096]) -> Album {
    var album = SampleLibrary.catalogue.albums[seed]
    album.tracks = zip(album.tracks.prefix(sizes.count), sizes).map { track, size in
        var track = track
        track.fileSize = Int64(size)
        return track
    }
    return album
}

@Suite(.serialized) @MainActor
struct DownloadReconcileTests {
    @Test func fileNamesGiveBackTheSongTheyWereSavedFor() {
        let key = DownloadManager.cacheKey(trackID: "song", driveID: "nas-a")
        let attempt = UUID().uuidString
        #expect(DownloadCacheInventory.cacheKey(inFileName: "\(attempt)-\(key).flac") == key)
        #expect(DownloadCacheInventory.cacheKey(inFileName: "\(key).flac") == key)
        #expect(DownloadCacheInventory.cacheKey(inFileName: key) == key)
        #expect(DownloadCacheInventory.cacheKey(inFileName: "\(attempt)-\(key).audio") == key)
        #expect(DownloadCacheInventory.cacheKey(inFileName: "incoming-\(key)") == nil)
        #expect(DownloadCacheInventory.cacheKey(inFileName: "old-a.flac") == nil)
        #expect(DownloadCacheInventory.cacheKey(inFileName: "\(attempt)-\(key.uppercased()).flac") == nil)
        #expect(DownloadCacheInventory.cacheKey(inFileName: "\(key).flac.partial-with-a-long-suffix") == nil)
        #expect(DownloadCacheInventory.cacheKey(inFileName: "x\(key).flac") == nil)
        #expect(DownloadManager.profileID(inOwner: "profile:abc|album:1") == "abc")
        #expect(DownloadManager.profileID(inOwner: "album:1") == nil)
    }

    @Test func completeFilesOnDiskAreAttachedToRestoredMembershipAndNotFetchedAgain() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = reconcileAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let first = try harness.writeFile(for: album.tracks[0], contents: bytes(8192))
        let second = try harness.writeFile(for: album.tracks[1], contents: bytes(4096))

        let report = harness.reconcile(albums: [album])
        #expect(report.attachedFiles == 2)
        #expect(report.missingSongs == 0)
        #expect(report.unused.isEmpty)
        #expect(harness.manager.state(for: owner) == .downloaded)
        let displayed = try await harness.manager.readState(for: owner)
        #expect(displayed == .downloaded)
        #expect(harness.manager.localURL(for: album.tracks[0])?.lastPathComponent == first)
        #expect(harness.manager.localURL(for: album.tracks[1])?.lastPathComponent == second)
        #expect(harness.manager.totalBytes == 8192 + 4096)
        #expect(harness.manager.listedOwnerIDs.contains(owner.id))
        #expect(harness.manager.unusedStorage.isEmpty)
        let saved = try harness.savedManifest()
        #expect(saved.count == 2)
        #expect(saved.allSatisfy { $0.owners == [owner.id] && $0.driveID == "nas-a" })

        // A retry from the screen finds everything here and starts no transfer.
        harness.queue(owner)
        #expect(harness.started.isEmpty)
        #expect(harness.manager.pendingByOwner.isEmpty)
        #expect(harness.manager.state(for: owner) == .downloaded)
        #expect(harness.exists(first) && harness.exists(second))
    }

    @Test func incompleteAndServerMessageFilesAreNotAttachedButSurfacedForRemoval() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = reconcileAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let short = try harness.writeFile(for: album.tracks[0], contents: bytes(100))
        var page = Data("{\"error\":\"denied\"}".utf8)
        page.append(bytes(4096 - page.count))
        let message = try harness.writeFile(for: album.tracks[1], contents: page)
        try Data("not ours".utf8).write(to: harness.directory.appending(path: "stranger.bin"))

        let report = harness.reconcile(albums: [album])
        #expect(report.attachedFiles == 0)
        #expect(report.missingSongs == 2)
        #expect(harness.manager.records.isEmpty)
        #expect(harness.manager.state(for: owner) == .partial(done: 0, total: 2, message: nil))
        let displayed = try await harness.manager.readState(for: owner)
        #expect(displayed == .partial(done: 0, total: 2, message: nil))
        #expect(harness.manager.listedOwnerIDs.contains(owner.id))
        #expect(harness.manager.missingCount(for: owner) == 2)
        #expect(harness.manager.unusedStorage.bytes == 100 + 4096 + 8)
        #expect(harness.manager.unusedStorage.fileCount == 3)
        #expect(harness.manager.unusedStorage.otherLibraryBytes == 0)
        #expect(harness.exists(short) && harness.exists(message))

        harness.manager.removeUnused()
        #expect(!harness.exists(short) && !harness.exists(message) && !harness.exists("stranger.bin"))
        #expect(harness.manager.unusedStorage.isEmpty)
        #expect(harness.exists("downloads.json"))
        #expect(harness.manager.state(for: owner) == .partial(done: 0, total: 2, message: nil))
    }

    @Test func aRetryAdoptsAnUnclaimedCompleteFileInsteadOfFetching() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = reconcileAlbum(sizes: [8192])
        let owner = DownloadOwner(album: album, profileID: "listener")
        let name = try harness.writeFile(for: album.tracks[0], contents: bytes(8192))

        harness.queue(owner)
        #expect(harness.started.isEmpty)
        #expect(harness.manager.pendingByOwner.isEmpty)
        #expect(harness.manager.state(for: owner) == .downloaded)
        let key = DownloadManager.cacheKey(trackID: album.tracks[0].id, driveID: "nas-a")
        #expect(harness.manager.records[key]?.fileName == name)
        #expect(harness.manager.records[key]?.owners == [owner.id])
        #expect(try harness.savedManifest().count == 1)
    }

    @Test func savedSongsUnderAnotherProfileScopeAreSharedWithTheRestoredOwner() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        let album = reconcileAlbum(sizes: [8192])
        let track = album.tracks[0]
        let stale = "profile:before-reinstall|" + DownloadOwner.albumPrefix + album.id
        let name = try harness.writeFile(for: track, contents: bytes(8192))
        try harness.writeManifest([DownloadRecord(trackID: track.id, driveID: "nas-a", fileName: name, bytes: 8192, owners: [stale])])
        harness.stop()
        harness.open()
        try await harness.restore()
        let owner = DownloadOwner(album: album, profileID: "listener")
        #expect(harness.manager.state(for: owner) == .none)

        let report = harness.reconcile(albums: [album])
        #expect(report.sharedRecords == 1)
        #expect(report.attachedFiles == 0)
        let key = DownloadManager.cacheKey(trackID: track.id, driveID: "nas-a")
        #expect(harness.manager.records[key]?.owners == [stale, owner.id])
        #expect(harness.manager.state(for: owner) == .downloaded)
        #expect(harness.manager.unusedStorage.isEmpty)
        harness.queue(owner)
        #expect(harness.started.isEmpty)
    }

    @Test func songsOwnedOnlyByProfilesNotOnThisDeviceAreSurfacedNotDeleted() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        let album = reconcileAlbum(1, sizes: [8192])
        let track = album.tracks[0]
        let ghost = "profile:ghost|" + DownloadOwner.albumPrefix + album.id
        let name = try harness.writeFile(for: track, contents: bytes(8192))
        try harness.writeManifest([DownloadRecord(trackID: track.id, driveID: "nas-a", fileName: name, bytes: 8192, owners: [ghost])])
        harness.stop()
        harness.open()
        try await harness.restore()

        // Until the app knows which profiles exist, nothing is judged.
        harness.manager.knownProfileIDsProvider = { [] }
        var report = harness.reconcile(albums: [])
        #expect(report.unused.isEmpty)

        harness.manager.knownProfileIDsProvider = { ["listener", "second"] }
        report = harness.reconcile(albums: [])
        #expect(report.unused.bytes == 8192)
        #expect(report.unused.fileCount == 1)
        #expect(harness.exists(name))
        #expect(harness.manager.totalBytes == 8192)
        #expect(harness.manager.downloadMembership(driveID: "nas-a").albums.isEmpty)

        // A profile that is on this device keeps its songs, unseen by the active profile.
        harness.manager.knownProfileIDsProvider = { ["listener", "ghost"] }
        report = harness.reconcile(albums: [])
        #expect(report.unused.isEmpty)

        harness.manager.knownProfileIDsProvider = { ["listener"] }
        harness.manager.refreshUnusedStorage()
        #expect(harness.manager.unusedStorage.bytes == 8192)
        harness.manager.removeUnused()
        #expect(!harness.exists(name))
        #expect(harness.manager.records.isEmpty)
        #expect(harness.manager.totalBytes == 0)
        #expect(try harness.savedManifest().isEmpty)
    }

    @Test func songsSavedForAnotherLibraryCountAsUnusedWithTheirOwnFigure() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        let album = reconcileAlbum(sizes: [8192, 4096])
        let owner = DownloadOwner(album: album, profileID: "listener")
        let here = try harness.writeFile(for: album.tracks[0], contents: bytes(8192))
        let elsewhere = try harness.writeFile(for: album.tracks[1], driveID: "nas-b", contents: bytes(4096))
        try harness.writeManifest([
            DownloadRecord(trackID: album.tracks[0].id, driveID: "nas-a", fileName: here, bytes: 8192, owners: [owner.id]),
            DownloadRecord(trackID: album.tracks[1].id, driveID: "nas-b", fileName: elsewhere, bytes: 4096, owners: [owner.id]),
        ])
        harness.stop()
        harness.open()
        try await harness.restore()

        let report = harness.reconcile(albums: [album])
        #expect(report.unused.bytes == 4096)
        #expect(report.unused.otherLibraryBytes == 4096)
        #expect(report.unused.fileCount == 1)
        #expect(harness.manager.totalBytes == 8192 + 4096)
        #expect(harness.manager.state(for: owner) == .partial(done: 1, total: 2, message: nil))

        harness.manager.removeUnused()
        #expect(harness.exists(here))
        #expect(!harness.exists(elsewhere))
        #expect(harness.manager.totalBytes == 8192)
        #expect(harness.manager.unusedStorage.isEmpty)
    }

    @Test func restoredMembershipStaysListedAndSurvivesNewDownloadsUntilRemoved() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        try await harness.restore()
        let restored = reconcileAlbum(0)
        let fresh = reconcileAlbum(2, sizes: [8192])
        let elsewhere = "album-not-in-this-catalogue"
        let restoredOwner = DownloadOwner(album: restored, profileID: "listener")
        let freshOwner = DownloadOwner(album: fresh, profileID: "listener")
        var reported: [(albums: [String], playlists: [String])] = []
        harness.manager.onMembershipChanged = { driveID, albums, playlists in
            #expect(driveID == "nas-a")
            reported.append((albums, playlists))
        }

        // One restored album is not in this catalogue yet; its membership must not be dropped.
        let report = harness.reconcile(albums: [restored], unresolvedAlbumIDs: [elsewhere])
        #expect(report.missingSongs == 2)
        let scope = DownloadOwner.scope("listener")
        #expect(harness.manager.listedOwnerIDs == [restoredOwner.id, scope + DownloadOwner.albumPrefix + elsewhere])
        #expect(harness.manager.state(for: restoredOwner) == .partial(done: 0, total: 2, message: nil))
        #expect(harness.manager.downloadMembership(driveID: "nas-a").albums == [restored.id, elsewhere].sorted())
        #expect(reported.isEmpty)

        // Downloading something new reports the whole membership, not only what has files here.
        harness.queue(freshOwner)
        #expect(harness.started.count == 1)
        #expect(reported.last?.albums == [restored.id, elsewhere, fresh.id].sorted())

        harness.manager.remove(restoredOwner)
        #expect(reported.last?.albums == [elsewhere, fresh.id].sorted())
        #expect(!harness.manager.listedOwnerIDs.contains(restoredOwner.id))
        #expect(harness.manager.state(for: restoredOwner) == .none)

        // The next document from iCloud no longer lists the other album either; the local list follows.
        harness.reconcile(albums: [])
        #expect(harness.manager.downloadMembership(driveID: "nas-a").albums == [fresh.id])
    }

    @Test func restoredMembershipIsScopedToTheProfileThatOwnsIt() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        try await harness.restore()
        let albumA = reconcileAlbum(0)
        let albumB = reconcileAlbum(1)
        let listenerOwner = DownloadOwner(album: albumA, profileID: "listener")
        let secondOwner = DownloadOwner(album: albumB, profileID: "second")
        harness.manager.knownProfileIDsProvider = { ["listener", "second"] }

        harness.reconcile(albums: [albumA])
        harness.manager.activeProfileID = "second"
        harness.reconcile(albums: [albumB])
        #expect(harness.manager.listedOwnerIDs == [listenerOwner.id, secondOwner.id])
        #expect(harness.manager.downloadMembership(driveID: "nas-a").albums == [albumB.id])
        #expect(harness.manager.state(for: secondOwner) == .partial(done: 0, total: 2, message: nil))
        #expect(harness.manager.state(for: DownloadOwner(album: albumA, profileID: "second")) == .none)

        harness.manager.activeProfileID = "listener"
        #expect(harness.manager.downloadMembership(driveID: "nas-a").albums == [albumA.id])
        // A shorter list from iCloud replaces only this profile's restored membership.
        harness.reconcile(albums: [])
        #expect(harness.manager.listedOwnerIDs == [secondOwner.id])
        #expect(harness.manager.state(for: listenerOwner) == .none)
    }

    @Test func recordsWhoseFilesVanishedArePrunedAndCountedMissing() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        let album = reconcileAlbum(sizes: [8192])
        let track = album.tracks[0]
        let owner = DownloadOwner(album: album, profileID: "listener")
        let name = try harness.writeFile(for: track, contents: bytes(8192))
        try harness.writeManifest([DownloadRecord(trackID: track.id, driveID: "nas-a", fileName: name, bytes: 8192, owners: [owner.id])])
        harness.stop()
        harness.open()
        try await harness.restore()
        #expect(harness.manager.state(for: owner) == .downloaded)
        try FileManager.default.removeItem(at: harness.directory.appending(path: name))

        let report = harness.reconcile(albums: [album])
        #expect(report.missingSongs == 1)
        #expect(harness.manager.records.isEmpty)
        #expect(harness.manager.totalBytes == 0)
        #expect(harness.manager.state(for: owner) == .partial(done: 0, total: 1, message: nil))
        #expect(try harness.savedManifest().isEmpty)
    }

    @Test func partialTransfersAreDeletedOnceTasksAreKnownWhileLiveOnesAreKept() async throws {
        let harness = try ReconcileHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = reconcileAlbum(sizes: [8192])
        let owner = DownloadOwner(album: album, profileID: "listener")
        harness.queue(owner)
        let live = try #require(DownloadJob.decode(harness.started.first?.taskDescription))
        try bytes(1024).write(to: harness.directory.appending(path: live.incomingFileName))
        let stale = "incoming-" + String(repeating: "ab", count: 32)
        try bytes(2048).write(to: harness.directory.appending(path: stale))
        harness.stop()

        // Relaunched: the saved transfer still owns its partial file; the other belongs to nobody.
        harness.open()
        var report = harness.reconcile(albums: [album])
        #expect(report.removedPartialFiles == 0)
        #expect(harness.exists(stale) && harness.exists(live.incomingFileName))
        #expect(harness.manager.unusedStorage.isEmpty)

        try await harness.restore()
        #expect(!harness.exists(stale))
        #expect(harness.exists(live.incomingFileName))
        #expect(harness.manager.unusedStorage.isEmpty)

        // The system reports the saved transfer never finished: its partial file is no longer owned.
        harness.delegate.onEventsFinished?()
        try await Task.sleep(for: .milliseconds(30))
        report = harness.reconcile(albums: [album])
        #expect(report.removedPartialFiles == 1)
        #expect(!harness.exists(live.incomingFileName))
        #expect(report.missingSongs == 1)
    }
}
