import Foundation
import Testing
@testable import SkyrCore

/// Holds only task enumeration. Completions still pass through the production URLSession delegate,
/// including its temporary-file move, and through the manager's asynchronous callback delivery.
@MainActor
private final class DownloadRestorationHarness {
    let directory: URL
    let delegate = DownloadDelegate()
    private(set) var manager: DownloadManager!
    private(set) var session: URLSession!
    private var completeRestoration: (@Sendable ([URLSessionTask]) -> Void)?

    init(pending: [String: Set<String>]? = nil) throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "SkyrDownloadRestoration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let pending {
            try JSONEncoder().encode(pending).write(to: directory.appending(path: "pending.json"))
        }
        manager = DownloadManager(directory: directory, configuration: .ephemeral, delegate: delegate,
                                  restoreTasks: { [weak self] session, completion in
            self?.session = session
            self?.completeRestoration = completion
        })
        manager.driveIDProvider = { "nas-a" }
        manager.activeProfileID = "listener"
    }

    func restoreWithoutActiveTasks() {
        completeRestoration?([])
        completeRestoration = nil
    }

    func deliverFile(for job: DownloadJob, contents: Data) throws {
        let temporary = directory.appending(path: "incoming-\(UUID().uuidString)")
        try contents.write(to: temporary)
        // The task is never resumed. Delivering the OS callback directly needs no network or NAS.
        let task = session.downloadTask(with: directory.appending(path: "unused-local-source"))
        task.taskDescription = job.encoded
        delegate.urlSession(session, downloadTask: task, didFinishDownloadingTo: temporary)
    }

    func deliverError(for job: DownloadJob) {
        let task = session.downloadTask(with: directory.appending(path: "unused-local-source"))
        task.taskDescription = job.encoded
        delegate.urlSession(session, task: task, didCompleteWithError: URLError(.timedOut))
    }

    func finishEvents() {
        delegate.urlSessionDidFinishEvents(forBackgroundURLSession: session)
    }

    func savedPending() throws -> [String: Set<String>] {
        try JSONDecoder().decode([String: Set<String>].self, from: Data(contentsOf: directory.appending(path: "pending.json")))
    }

    func close() {
        manager = nil
        session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: directory)
    }
}

private func restorationAlbum() -> Album {
    var album = SampleLibrary.catalogue.albums[0]
    album.tracks = Array(album.tracks.prefix(1))
    return album
}

private func restorationJob(ownerID: String, track: Track, bytes: Int) -> DownloadJob {
    DownloadJob(ownerID: ownerID, trackID: track.id, driveID: "nas-a",
                fileName: DownloadManager.fileName(for: track, driveID: "nas-a"), expectedBytes: Int64(bytes),
                ownerTitle: "Restored album", ownerSubtitle: "Artist", trackTitle: track.title, ownerTrackCount: 1)
}

@MainActor
private func callbacksHaveRun() async throws {
    try await Task.sleep(for: .milliseconds(20))
}

@MainActor
private func eventually(_ condition: () -> Bool) async throws -> Bool {
    for _ in 0..<100 {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@Suite(.serialized)
@MainActor
struct DownloadRestorationTests {
    @Test func completedLegacyTaskWaitsForRestorationAndPersistsBeforeBackgroundCompletion() async throws {
        let harness = try DownloadRestorationHarness()
        defer { harness.close() }
        let album = restorationAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let contents = Data(repeating: 0x5A, count: 8192)
        let job = restorationJob(ownerID: DownloadOwner.albumPrefix + album.id, track: album.tracks[0], bytes: contents.count)
        let destination = harness.directory.appending(path: job.fileName)
        var backgroundCompleted = false
        var recordsAtBackgroundCompletion: [DownloadRecord] = []
        let previousCompletion = DownloadManager.backgroundCompletionHandler
        defer { DownloadManager.backgroundCompletionHandler = previousCompletion }
        DownloadManager.backgroundCompletionHandler = {
            recordsAtBackgroundCompletion = (try? JSONDecoder().decode([DownloadRecord].self,
                from: Data(contentsOf: harness.directory.appending(path: "downloads.json")))) ?? []
            backgroundCompleted = true
        }

        try harness.deliverFile(for: job, contents: contents)
        harness.finishEvents()
        try await callbacksHaveRun()
        #expect(!backgroundCompleted)
        #expect(harness.manager.records.isEmpty)
        #expect(FileManager.default.fileExists(atPath: destination.path))

        // Finished tasks may already be absent from URLSession's active-task enumeration.
        harness.restoreWithoutActiveTasks()
        #expect(try await eventually { backgroundCompleted })
        #expect(harness.manager.state(for: owner) == .downloaded)
        #expect(harness.manager.records[job.cacheKey]?.owners == [owner.id])
        #expect(recordsAtBackgroundCompletion.count == 1)
        #expect(recordsAtBackgroundCompletion.first?.owners == [owner.id])
        #expect(try Data(contentsOf: destination) == contents)
        #expect(try harness.savedPending().isEmpty)
    }

    @Test func earlyErrorDoesNotPreventAnotherLegacyCompletionFromBeingAdopted() async throws {
        let harness = try DownloadRestorationHarness()
        defer { harness.close() }
        let album = restorationAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let contents = Data(repeating: 0x5A, count: 8192)
        let success = restorationJob(ownerID: owner.id, track: album.tracks[0], bytes: contents.count)
        let failure = DownloadJob(ownerID: owner.id, trackID: "failed-before-restore", driveID: "nas-a",
                                  fileName: "failed.audio", expectedBytes: nil, ownerTitle: owner.title,
                                  ownerSubtitle: owner.subtitle, trackTitle: "Failed song", ownerTrackCount: 2)

        harness.deliverError(for: failure)
        try harness.deliverFile(for: success, contents: contents)
        try await callbacksHaveRun()
        #expect(harness.manager.lastError == nil)
        #expect(harness.manager.records.isEmpty)

        harness.restoreWithoutActiveTasks()
        #expect(try await eventually { harness.manager.records[success.cacheKey] != nil })
        #expect(harness.manager.records[success.cacheKey]?.owners == [owner.id])
        #expect(harness.manager.lastError != nil)
        #expect(try harness.savedPending().isEmpty)
    }

    @Test func persistedCancellationNeverFallsBackToLegacyJobOwner() async throws {
        let harness = try DownloadRestorationHarness(pending: [:])
        defer { harness.close() }
        let album = restorationAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let contents = Data(repeating: 0x5A, count: 8192)
        let job = restorationJob(ownerID: owner.id, track: album.tracks[0], bytes: contents.count)
        let destination = harness.directory.appending(path: job.fileName)
        try harness.deliverFile(for: job, contents: contents)

        harness.restoreWithoutActiveTasks()
        #expect(try await eventually { !FileManager.default.fileExists(atPath: destination.path) })
        #expect(harness.manager.records.isEmpty)
        #expect(try harness.savedPending().isEmpty)
    }

    @Test func cancellationBeforeLegacyRestorationPreventsOwnershipResurrection() async throws {
        let harness = try DownloadRestorationHarness()
        defer { harness.close() }
        let album = restorationAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let contents = Data(repeating: 0x5A, count: 8192)
        let job = restorationJob(ownerID: owner.id, track: album.tracks[0], bytes: contents.count)
        let destination = harness.directory.appending(path: job.fileName)
        harness.manager.cancel(owner)
        try harness.deliverFile(for: job, contents: contents)

        harness.restoreWithoutActiveTasks()
        #expect(try await eventually { !FileManager.default.fileExists(atPath: destination.path) })
        #expect(harness.manager.records.isEmpty)
        #expect(try harness.savedPending().isEmpty)
    }

    @Test func cancellationDuringRestorationRetainsOnlyTheOtherSavedOwner() async throws {
        let album = restorationAlbum()
        let first = DownloadOwner(album: album, profileID: "listener")
        let second = DownloadOwner(album: album, profileID: "other-listener")
        let contents = Data(repeating: 0x5A, count: 8192)
        let job = restorationJob(ownerID: first.id, track: album.tracks[0], bytes: contents.count)
        let harness = try DownloadRestorationHarness(pending: [first.id: [job.cacheKey], second.id: [job.cacheKey]])
        defer { harness.close() }
        harness.manager.cancel(first)
        #expect(try harness.savedPending() == [second.id: [job.cacheKey]])
        try harness.deliverFile(for: job, contents: contents)

        harness.restoreWithoutActiveTasks()
        #expect(try await eventually { harness.manager.records[job.cacheKey] != nil })
        #expect(harness.manager.records[job.cacheKey]?.owners == [second.id])
        #expect(harness.manager.state(for: first) == .none)
        #expect(harness.manager.state(for: second) == .downloaded)
        #expect(try harness.savedPending().isEmpty)
    }

    @Test func completedTaskArrivingAfterEnumerationKeepsItsPersistedOwnerIntent() async throws {
        let album = restorationAlbum()
        let owner = DownloadOwner(album: album, profileID: "listener")
        let contents = Data(repeating: 0x5A, count: 8192)
        let job = restorationJob(ownerID: owner.id, track: album.tracks[0], bytes: contents.count)
        let harness = try DownloadRestorationHarness(pending: [owner.id: [job.cacheKey]])
        defer { harness.close() }
        harness.restoreWithoutActiveTasks()
        #expect(try await eventually { harness.manager.pendingByOwner.isEmpty })
        // A second process exit here must not persist an empty cancellation marker.
        #expect(try harness.savedPending() == [owner.id: [job.cacheKey]])

        try harness.deliverFile(for: job, contents: contents)
        #expect(try await eventually { harness.manager.records[job.cacheKey] != nil })
        #expect(harness.manager.records[job.cacheKey]?.owners == [owner.id])
        #expect(try harness.savedPending().isEmpty)
    }
}
