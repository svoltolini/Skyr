import Foundation
import Testing
import SkyrShared
@testable import SkyrCore

/// URLSession owns the task descriptions and delegate callbacks; none of these tasks are resumed.
/// The fixture controls their delivery order without making a network request.
@MainActor
private final class TransferHarness {
    let directory: URL
    private(set) var manager: DownloadManager!
    private(set) var delegate: DownloadDelegate!
    private(set) var session: URLSession!
    private(set) var started: [URLSessionDownloadTask] = []
    private var restoreTasks: (@Sendable ([URLSessionTask]) -> Void)?
    private let isTransportAllowed: (URL) -> Bool

    init(isTransportAllowed: @escaping (URL) -> Bool = { NASTransportSecurity.isAllowed($0) }) throws {
        self.isTransportAllowed = isTransportAllowed
        directory = FileManager.default.temporaryDirectory.appending(path: "SkyrAttemptTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        open()
    }

    func open() {
        delegate = DownloadDelegate()
        manager = DownloadManager(directory: directory, configuration: .ephemeral, delegate: delegate,
            restoreTasks: { [weak self] session, completion in
                self?.session = session
                self?.restoreTasks = completion
            }, resumeTask: { [weak self] task in
                if self?.started.contains(where: { $0 === task }) == false { self?.started.append(task) }
            }, isTransportAllowed: isTransportAllowed)
        manager.driveIDProvider = { "nas-a" }
        manager.activeProfileID = "listener"
    }

    func restore(_ jobs: [DownloadJob] = []) async throws {
        restoreTasks?(jobs.map(task))
        restoreTasks = nil
        try await drain()
    }

    func task(_ job: DownloadJob) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: URL(string: "https://nas.example:5001/never-requested")!)
        task.taskDescription = job.encoded
        return task
    }

    func queue(_ owner: DownloadOwner, source: URL = URL(string: "https://nas.example:5001/never-requested")!) {
        manager.download(owner, driveID: "nas-a") { _ in source }
    }

    func startedJob(_ index: Int) throws -> DownloadJob {
        try #require(index < started.count ? DownloadJob.decode(started[index].taskDescription) : nil)
    }

    func deliver(_ job: DownloadJob, bytes: Data = transferBytes) throws {
        let temporary = directory.appending(path: "callback-\(UUID().uuidString)")
        try bytes.write(to: temporary)
        delegate.urlSession(session, downloadTask: task(job), didFinishDownloadingTo: temporary)
    }

    func fail(_ job: DownloadJob) {
        delegate.urlSession(session, task: task(job), didCompleteWithError: URLError(.timedOut))
    }

    func progress(_ job: DownloadJob, fraction: Double) {
        delegate.onProgress?(job, fraction)
    }

    func stop() {
        manager = nil
        session.invalidateAndCancel()
        started = []
    }

    func close() {
        stop()
        try? FileManager.default.removeItem(at: directory)
    }
}

private let transferBytes = Data(repeating: 0x5A, count: 8192)

private func transferAlbum(count: Int = 1) -> Album {
    var album = SampleLibrary.catalogue.albums[0]
    album.tracks = Array(album.tracks.prefix(count)).map { original in
        var track = original
        track.fileSize = Int64(transferBytes.count)
        return track
    }
    return album
}

@MainActor private func drain() async throws { try await Task.sleep(for: .milliseconds(30)) }

@Suite(.serialized) @MainActor
struct DownloadAttemptTests {
    @Test func HTTPApprovalRevokedBetweenSongsStopsQueuedTransfersAndKeepsSharedRetry() async throws {
        let suite = "skyr.download.transport.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let source = URL(string: "http://nas.example:5000/never-requested")!
        NASTransportSecurity.allowHTTP(source, defaults: defaults)
        let harness = try TransferHarness(isTransportAllowed: { NASTransportSecurity.isAllowed($0, defaults: defaults) })
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum(count: 2)
        let firstOwner = DownloadOwner(album: album, profileID: "listener")
        let secondOwner = DownloadOwner(album: album, profileID: "second")
        harness.queue(firstOwner, source: source)
        harness.queue(secondOwner, source: source)
        #expect(harness.started.count == 1)
        let firstSong = try harness.startedJob(0)

        NASTransportSecurity.revokeHTTP(source, defaults: defaults)
        try harness.deliver(firstSong)
        try await drain()
        #expect(harness.started.count == 1)
        #expect(harness.manager.pendingByOwner.isEmpty)
        #expect(harness.manager.progressSnapshot(ownerID: firstOwner.id, driveID: "nas-a")?.outcome == .partial)
        #expect(harness.manager.progressSnapshot(ownerID: secondOwner.id, driveID: "nas-a")?.outcome == .partial)
        #expect(harness.manager.lastError?.contains("no longer allowed") == true)
        #expect(harness.manager.records[firstSong.cacheKey]?.owners == [firstOwner.id, secondOwner.id])

        NASTransportSecurity.allowHTTP(source, defaults: defaults)
        harness.queue(firstOwner, source: source)
        harness.queue(secondOwner, source: source)
        #expect(harness.started.count == 2)
        let retry = try harness.startedJob(1)
        #expect(retry.trackID != firstSong.trackID)
        try harness.deliver(retry)
        try await drain()
        #expect(harness.manager.state(for: firstOwner) == .downloaded)
        #expect(harness.manager.state(for: secondOwner) == .downloaded)
        #expect(harness.manager.records[retry.cacheKey]?.owners == [firstOwner.id, secondOwner.id])
    }

    @Test(arguments: [false, true])
    func plainRetryAfterEmptyRestorationStartsANewTaskAndKeepsBothOwners(requestedDuringEnumeration: Bool) async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        harness.queue(first)
        harness.queue(second)
        let old = try harness.startedJob(0)
        harness.stop()
        harness.open()
        if requestedDuringEnumeration { harness.queue(first) }
        // No live tasks and no background events-finished notification: a normal foreground launch.
        try await harness.restore()
        #expect(harness.manager.pendingByOwner.isEmpty)
        harness.queue(first)
        let retry = try harness.startedJob(0)
        #expect(retry.attemptID != old.attemptID)
        #expect(harness.manager.state(for: first).isDownloading)
        #expect(harness.manager.state(for: second).isDownloading)
        try harness.deliver(old)
        try await drain()
        #expect(harness.manager.records.isEmpty)
        #expect(harness.manager.state(for: first).isDownloading)
        try harness.deliver(retry)
        try await drain()
        #expect(harness.manager.records[retry.cacheKey]?.owners == [first.id, second.id])
        #expect(harness.manager.state(for: first) == .downloaded)
        #expect(harness.manager.state(for: second) == .downloaded)
    }

    @Test(arguments: [false, true])
    func cancellationAroundRestorationStillAllowsAnImmediateRetry(enumerated: Bool) async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let owner = harness.manager.owner(for: transferAlbum())
        harness.queue(owner)
        let old = try harness.startedJob(0)
        harness.stop()
        harness.open()
        if enumerated { try await harness.restore() }
        harness.manager.cancel(owner)
        harness.queue(owner)
        let retry = try harness.startedJob(0)
        #expect(retry.attemptID != old.attemptID)
        try harness.deliver(old)
        if !enumerated { try await harness.restore([old]) }
        try await drain()
        #expect(harness.manager.state(for: owner).isDownloading)
        #expect(harness.manager.records.isEmpty)
        try harness.deliver(retry)
        try await drain()
        #expect(harness.manager.state(for: owner) == .downloaded)
        #expect(harness.manager.records[retry.cacheKey]?.fileName == retry.fileName)
    }

    @Test func cancelAndImmediateRetryUseSeparateAttemptsAndIgnoreEveryOldCallback() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let owner = harness.manager.owner(for: album)
        harness.queue(owner)
        let old = try harness.startedJob(0)
        harness.manager.cancel(owner)
        #expect(harness.manager.state(for: owner) == .cancelled(done: 0, total: 1))
        harness.queue(owner)
        let retry = try harness.startedJob(1)
        #expect(old.attemptID != retry.attemptID)
        #expect(old.incomingFileName != retry.incomingFileName)
        #expect(old.fileName != retry.fileName)

        harness.progress(old, fraction: 0.9)
        harness.fail(old)
        try harness.deliver(old)
        try await drain()
        #expect(harness.manager.state(for: owner).isDownloading)
        #expect(harness.manager.progress[old.trackID] == 0)
        #expect(harness.manager.lastError == nil)
        #expect(harness.manager.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: old.incomingFileName).path))

        try harness.deliver(retry)
        try await drain()
        #expect(harness.manager.state(for: owner) == .downloaded)
        let saved = try #require(harness.manager.localURL(for: album.tracks[0]))
        #expect(try Data(contentsOf: saved) == transferBytes)
        try harness.deliver(old, bytes: Data(repeating: 0x42, count: transferBytes.count))
        harness.fail(old)
        try await drain()
        #expect(harness.manager.state(for: owner) == .downloaded)
        #expect(try Data(contentsOf: saved) == transferBytes)
        #expect(harness.manager.lastError == nil)
    }

    @Test func retryIdentityAndSharedOwnersSurviveRelaunch() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        harness.queue(first)
        let old = try harness.startedJob(0)
        harness.manager.cancel(first)
        harness.queue(first)
        harness.queue(second)
        let retry = try harness.startedJob(1)
        harness.stop()
        harness.open()
        try await harness.restore([retry])
        try harness.deliver(old)
        harness.fail(old)
        try await drain()
        #expect(harness.manager.state(for: first).isDownloading)
        #expect(harness.manager.state(for: second).isDownloading)
        #expect(harness.manager.records.isEmpty)
        try harness.deliver(retry)
        try await drain()
        #expect(harness.manager.records[retry.cacheKey]?.owners == [first.id, second.id])
        #expect(harness.manager.state(for: first) == .downloaded)
        #expect(harness.manager.state(for: second) == .downloaded)
    }

    @Test func cancellingOneOwnerKeepsTheSharedTransferForTheOther() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        harness.queue(first)
        harness.queue(second)
        let job = try harness.startedJob(0)
        harness.manager.cancel(first)
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records[job.cacheKey]?.owners == [second.id])
        #expect(harness.manager.state(for: first) == .cancelled(done: 0, total: 1))
        #expect(harness.manager.state(for: second) == .downloaded)
        #expect(harness.manager.progressSnapshot(ownerID: first.id, driveID: "nas-a")?.outcome == .cancelled)
        #expect(harness.manager.progressSnapshot(ownerID: second.id, driveID: "nas-a")?.outcome == .downloaded)
    }

    @Test func partialFailureRemainsVisibleAndRetryFetchesOnlyTheMissingSong() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum(count: 2)
        let owner = harness.manager.owner(for: album)
        harness.queue(owner)
        let first = try harness.startedJob(0)
        try harness.deliver(first)
        try await drain()
        let second = try harness.startedJob(1)
        harness.fail(second)
        try await drain()
        if case .partial(let done, let total, let message) = harness.manager.state(for: owner) {
            #expect(done == 1 && total == 2)
            #expect(message?.contains(second.trackTitle) == true)
        } else { Issue.record("The successful file must remain available after a later failure") }
        let partial = try #require(harness.manager.progressSnapshot(ownerID: owner.id, driveID: "nas-a"))
        #expect(partial.outcome == .partial && partial.done == 1 && partial.total == 2 && partial.fraction == 0.5)
        #expect(!partial.statusLine.contains("Downloaded"))
        #expect(harness.manager.listedOwnerIDs.contains(owner.id))
        let saved = try #require(harness.manager.localURL(for: album.tracks[0]))
        harness.queue(owner)
        #expect(harness.started.count == 3)
        let retry = try harness.startedJob(2)
        #expect(retry.trackID == second.trackID)
        #expect(retry.attemptID != second.attemptID)
        try harness.deliver(retry)
        try await drain()
        #expect(harness.manager.state(for: owner) == .downloaded)
        #expect(harness.manager.localURL(for: album.tracks[0]) == saved)
        let complete = try #require(harness.manager.progressSnapshot(ownerID: owner.id, driveID: "nas-a"))
        #expect(complete.outcome == .downloaded && complete.done == 2 && complete.total == 2 && complete.fraction == 1)
    }

    @Test func terminalFailurePersistsAndRemovalClearsItsRetryEntry() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let owner = harness.manager.owner(for: album)
        harness.queue(owner)
        harness.fail(try harness.startedJob(0))
        try await drain()
        harness.stop()
        harness.open()
        try await harness.restore()
        if case .failed = harness.manager.state(for: owner) {} else { Issue.record("Failure state should survive relaunch") }
        let state = try #require(harness.manager.progressSnapshot(ownerID: owner.id, driveID: "nas-a"))
        #expect(state.outcome == .failed && state.done == 0 && state.total == 1 && state.fraction == 0)
        #expect(harness.manager.listedOwnerIDs.contains(owner.id))
        harness.manager.remove(owner)
        #expect(harness.manager.state(for: owner) == .none)
        #expect(!harness.manager.listedOwnerIDs.contains(owner.id))
    }

    @Test func incompleteFileIsNeverMarkedDownloaded() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let owner = harness.manager.owner(for: transferAlbum())
        harness.queue(owner)
        let job = try harness.startedJob(0)
        try harness.deliver(job, bytes: transferBytes.dropLast())
        try await drain()
        if case .failed = harness.manager.state(for: owner) {} else { Issue.record("Even a small incomplete transfer must be retryable") }
        #expect(harness.manager.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: job.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: job.incomingFileName).path))
    }

    @Test func cancellationAfterOneFileReportsTheSavedCountAndRetainsIt() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum(count: 2)
        let owner = harness.manager.owner(for: album)
        harness.queue(owner)
        try harness.deliver(try harness.startedJob(0))
        try await drain()
        harness.manager.cancel(owner)
        #expect(harness.manager.state(for: owner) == .cancelled(done: 1, total: 2))
        let state = try #require(harness.manager.progressSnapshot(ownerID: owner.id, driveID: "nas-a"))
        #expect(state.outcome == .cancelled && state.done == 1 && state.total == 2 && state.fraction == 0.5)
        #expect(state.statusLine == "Cancelled · 1 of 2 saved")
        #expect(harness.manager.localURL(for: album.tracks[0]) != nil)
        harness.manager.remove(owner)
        #expect(harness.manager.records.isEmpty)
        #expect(harness.manager.state(for: owner) == .none)
    }

    // MARK: - Shared ownership edge cases (issue #17)

    @Test func cancellingSecondOwnerKeepsTheTransferForTheOriginalOwner() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        harness.queue(first)
        harness.queue(second)
        let job = try harness.startedJob(0)
        harness.manager.cancel(second)
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records[job.cacheKey]?.owners == [first.id])
        #expect(harness.manager.state(for: first) == .downloaded)
        #expect(harness.manager.state(for: second) == .cancelled(done: 0, total: 1))
        #expect(harness.manager.progressSnapshot(ownerID: first.id, driveID: "nas-a")?.outcome == .downloaded)
        #expect(harness.manager.progressSnapshot(ownerID: second.id, driveID: "nas-a")?.outcome == .cancelled)
    }

    @Test func cancellingBothOwnersDeletesTheFileOnCompletion() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        harness.queue(first)
        harness.queue(second)
        let job = try harness.startedJob(0)
        harness.manager.cancel(first)
        harness.manager.cancel(second)
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records.isEmpty)
        #expect(harness.manager.state(for: first) == .cancelled(done: 0, total: 1))
        #expect(harness.manager.state(for: second) == .cancelled(done: 0, total: 1))
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: job.fileName).path))
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: job.incomingFileName).path))
    }

    @Test func overlappingAlbumAndPlaylistOwnersShareTheDownload() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let playlist = Playlist(id: "favourites", name: "Favourites", tracks: album.tracks, isSmart: false, isDownloaded: false)
        let albumOwner = DownloadOwner(album: album, profileID: "listener")
        let playlistOwner = DownloadOwner(playlist: playlist, profileID: "listener")
        harness.queue(albumOwner)
        harness.queue(playlistOwner)
        #expect(harness.started.count == 1)
        let job = try harness.startedJob(0)
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records[job.cacheKey]?.owners == [albumOwner.id, playlistOwner.id])
        #expect(harness.manager.state(for: albumOwner) == .downloaded)
        #expect(harness.manager.state(for: playlistOwner) == .downloaded)
    }

    @Test func removingOneOverlappingOwnerKeepsFileForTheOther() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let playlist = Playlist(id: "favourites", name: "Favourites", tracks: album.tracks, isSmart: false, isDownloaded: false)
        let albumOwner = DownloadOwner(album: album, profileID: "listener")
        let playlistOwner = DownloadOwner(playlist: playlist, profileID: "listener")
        harness.queue(albumOwner)
        harness.queue(playlistOwner)
        let job = try harness.startedJob(0)
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records[job.cacheKey]?.owners == [albumOwner.id, playlistOwner.id])
        harness.manager.remove(albumOwner)
        #expect(harness.manager.records[job.cacheKey]?.owners == [playlistOwner.id])
        #expect(harness.manager.state(for: albumOwner) == .none)
        #expect(harness.manager.state(for: playlistOwner) == .downloaded)
        #expect(FileManager.default.fileExists(atPath: harness.directory.appending(path: job.fileName).path))
    }

    @Test func removingBothOverlappingOwnersDeletesTheFile() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let playlist = Playlist(id: "favourites", name: "Favourites", tracks: album.tracks, isSmart: false, isDownloaded: false)
        let albumOwner = DownloadOwner(album: album, profileID: "listener")
        let playlistOwner = DownloadOwner(playlist: playlist, profileID: "listener")
        harness.queue(albumOwner)
        harness.queue(playlistOwner)
        let job = try harness.startedJob(0)
        try harness.deliver(job)
        try await drain()
        let filePath = harness.directory.appending(path: job.fileName).path
        #expect(FileManager.default.fileExists(atPath: filePath))
        harness.manager.remove(albumOwner)
        #expect(FileManager.default.fileExists(atPath: filePath))
        harness.manager.remove(playlistOwner)
        #expect(!FileManager.default.fileExists(atPath: filePath))
        #expect(harness.manager.records.isEmpty)
    }

    @Test func sharedOwnershipSurvivesRelaunchWithCancelledOriginalOwner() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        harness.queue(first)
        harness.queue(second)
        let job = try harness.startedJob(0)
        harness.manager.cancel(first)
        harness.stop()
        harness.open()
        try await harness.restore([job])
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records[job.cacheKey]?.owners == [second.id])
        #expect(harness.manager.state(for: first) == .cancelled(done: 0, total: 1))
        #expect(harness.manager.state(for: second) == .downloaded)
    }

    @Test func lateCompletionAfterBothOwnersCancelledDeletesFile() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "second")
        harness.queue(first)
        harness.queue(second)
        let job = try harness.startedJob(0)
        harness.manager.cancel(first)
        harness.manager.cancel(second)
        harness.stop()
        harness.open()
        try await harness.restore([job])
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: harness.directory.appending(path: job.fileName).path))
    }

    @Test func multipleProfilesSamePlaylistMaintainSeparateOwnership() async throws {
        let harness = try TransferHarness()
        defer { harness.close() }
        try await harness.restore()
        let album = transferAlbum()
        let playlist = Playlist(id: "shared-playlist", name: "Shared", tracks: album.tracks, isSmart: false, isDownloaded: false)
        let profile1 = DownloadOwner(playlist: playlist, profileID: "listener")
        let profile2 = DownloadOwner(playlist: playlist, profileID: "other")
        harness.queue(profile1)
        harness.queue(profile2)
        #expect(harness.started.count == 1)
        let job = try harness.startedJob(0)
        try harness.deliver(job)
        try await drain()
        #expect(harness.manager.records[job.cacheKey]?.owners == [profile1.id, profile2.id])
        harness.manager.remove(profile1)
        #expect(harness.manager.records[job.cacheKey]?.owners == [profile2.id])
        harness.manager.driveIDProvider = { "nas-a" }
        harness.manager.activeProfileID = "other"
        #expect(harness.manager.state(for: profile2) == .downloaded)
    }
}
