import Foundation
import Testing
import SkyrShared
@testable import SkyrCore

/// Tests for disk reconciliation after reinstall (issue #78):
/// - Scanning on-disk cache
/// - Reconciling with restored CloudKit membership
/// - Reusing valid files without re-downloading
/// - Orphan cleanup

@MainActor
private final class ReconciliationHarness {
    let directory: URL
    private(set) var manager: DownloadManager!
    private(set) var delegate: DownloadDelegate!
    private(set) var session: URLSession!
    private(set) var started: [URLSessionDownloadTask] = []
    private var restoreTasks: (@Sendable ([URLSessionTask]) -> Void)?

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "SkyrReconciliationTests-\(UUID().uuidString)")
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
            })
        manager.driveIDProvider = { "nas-a" }
        manager.activeProfileID = "listener"
    }

    func restore() async throws {
        restoreTasks?([])
        restoreTasks = nil
        try await drain()
    }

    func queue(_ owner: DownloadOwner, source: URL = URL(string: "https://nas.example:5001/never-requested")!) {
        manager.download(owner, driveID: "nas-a") { _ in source }
    }

    func startedJob(_ index: Int) throws -> DownloadJob {
        try #require(index < started.count ? DownloadJob.decode(started[index].taskDescription) : nil)
    }

    func task(_ job: DownloadJob) -> URLSessionDownloadTask {
        let task = session.downloadTask(with: URL(string: "https://nas.example:5001/never-requested")!)
        task.taskDescription = job.encoded
        return task
    }

    func deliver(_ job: DownloadJob, bytes: Data = testBytes) throws {
        let temporary = directory.appending(path: "callback-\(UUID().uuidString)")
        try bytes.write(to: temporary)
        delegate.urlSession(session, downloadTask: task(job), didFinishDownloadingTo: temporary)
    }

    /// Simulates orphaned files on disk (from before reinstall) without records
    func createOrphanedFile(trackID: String, driveID: String = "nas-a", bytes: Data = testBytes) throws -> URL {
        let cacheKey = DownloadManager.cacheKey(trackID: trackID, driveID: driveID)
        let ext = DownloadManager.safeExtension("mp3")
        let filename = "\(cacheKey).\(ext)"
        let url = directory.appending(path: filename)
        try bytes.write(to: url)
        return url
    }

    /// Creates a file on disk that matches a track (simulating valid cached file)
    func createCachedFile(for track: Track, driveID: String = "nas-a", bytes: Data? = nil) throws -> URL {
        let cacheKey = DownloadManager.cacheKey(trackID: track.id, driveID: driveID)
        let ext = DownloadManager.safeExtension(track.fileExtension)
        let filename = "\(cacheKey).\(ext)"
        let url = directory.appending(path: filename)
        let data = bytes ?? Data(repeating: 0x5A, count: Int(track.fileSize ?? 8192))
        try data.write(to: url)
        return url
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

    /// Reopens manager to simulate app reinstall (clears manifest but keeps files)
    func simulateReinstall() {
        // Save which files exist
        let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { !$0.lastPathComponent.hasSuffix(".json") }
        
        stop()
        
        // Remove manifest and intent files (simulating reinstall)
        try? FileManager.default.removeItem(at: directory.appending(path: "downloads.json"))
        try? FileManager.default.removeItem(at: directory.appending(path: "pending.json"))
        try? FileManager.default.removeItem(at: directory.appending(path: "download-intent.json"))
        
        // Keep the audio files intact
        // Reopen manager
        open()
    }
}

private let testBytes = Data(repeating: 0x5A, count: 8192)

private func testAlbum(count: Int = 1) -> Album {
    var album = SampleLibrary.catalogue.albums[0]
    album.tracks = Array(album.tracks.prefix(count)).map { original in
        var track = original
        track.fileSize = Int64(testBytes.count)
        return track
    }
    return album
}

@MainActor private func drain() async throws { try await Task.sleep(for: .milliseconds(30)) }

@Suite(.serialized) @MainActor
struct DownloadReconciliationTests {
    
    // MARK: - Disk scanning
    
    @Test func scanDiskCacheFindsExistingFiles() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        // Create some orphaned files on disk
        let url1 = try harness.createOrphanedFile(trackID: "track-1")
        let url2 = try harness.createOrphanedFile(trackID: "track-2")
        
        // Check orphan info - should find the files
        let info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 2)
        #expect(info.bytes == Int64(testBytes.count * 2))
        
        // Verify files exist
        #expect(FileManager.default.fileExists(atPath: url1.path))
        #expect(FileManager.default.fileExists(atPath: url2.path))
    }
    
    @Test func scanIgnoresManifestAndPendingFiles() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        // Create a downloads.json-like file that should be ignored
        try "{}".data(using: .utf8)!.write(to: harness.directory.appending(path: "test.json"))
        try "{}".data(using: .utf8)!.write(to: harness.directory.appending(path: "incoming-test"))
        
        let info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 0)
    }
    
    // MARK: - Reconciliation with disk
    
    @Test func downloadReusesExistingFileOnDisk() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let album = testAlbum(count: 1)
        let owner = DownloadOwner(album: album, profileID: "listener")
        
        // Pre-create the file on disk (simulating leftover from previous install)
        let fileURL = try harness.createCachedFile(for: album.tracks[0])
        
        // Now trigger download - should reuse the file, not queue a new download
        harness.queue(owner)
        try await drain()
        
        // No download should have been started
        #expect(harness.started.isEmpty)
        
        // But the owner should show as downloaded
        #expect(harness.manager.state(for: owner) == .downloaded)
        
        // Record should exist
        let key = DownloadManager.cacheKey(trackID: album.tracks[0].id, driveID: "nas-a")
        #expect(harness.manager.records[key] != nil)
        #expect(harness.manager.records[key]?.owners.contains(owner.id) == true)
    }
    
    @Test func downloadReusesMultipleExistingFilesOnDisk() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let album = testAlbum(count: 3)
        let owner = DownloadOwner(album: album, profileID: "listener")
        
        // Pre-create all files on disk
        for track in album.tracks {
            _ = try harness.createCachedFile(for: track)
        }
        
        // Trigger download
        harness.queue(owner)
        try await drain()
        
        // No downloads started
        #expect(harness.started.isEmpty)
        
        // Should be fully downloaded
        #expect(harness.manager.state(for: owner) == .downloaded)
    }
    
    @Test func downloadQueuesOnlyMissingFilesWhenSomeExistOnDisk() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let album = testAlbum(count: 3)
        let owner = DownloadOwner(album: album, profileID: "listener")
        
        // Pre-create only the first file on disk
        _ = try harness.createCachedFile(for: album.tracks[0])
        
        // Trigger download
        harness.queue(owner)
        try await drain()
        
        // Should have started downloads for the 2 missing tracks
        #expect(harness.started.count == 1) // one at a time
        
        // Should be in downloading state (partial)
        let state = harness.manager.state(for: owner)
        if case .downloading(_, let done, let total) = state {
            #expect(done == 1) // one already on disk
            #expect(total == 3)
        } else {
            Issue.record("Expected downloading state, got \(state)")
        }
    }
    
    @Test func reconciliationSkipsFilesWithWrongSize() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let album = testAlbum(count: 1)
        let owner = DownloadOwner(album: album, profileID: "listener")
        
        // Create file with wrong size (simulating corrupt or incomplete download)
        let wrongSizeBytes = Data(repeating: 0x5A, count: 100) // Much smaller than expected
        _ = try harness.createCachedFile(for: album.tracks[0], bytes: wrongSizeBytes)
        
        // Trigger download
        harness.queue(owner)
        try await drain()
        
        // Should have queued a download because size didn't match
        #expect(harness.started.count == 1)
    }
    
    @Test func reconciliationWorksAfterSimulatedReinstall() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let album = testAlbum(count: 2)
        let owner = DownloadOwner(album: album, profileID: "listener")
        
        // First, do a normal download
        harness.queue(owner)
        let job1 = try harness.startedJob(0)
        try harness.deliver(job1)
        try await drain()
        
        // Deliver second track
        harness.started.removeAll()
        try await drain()
        if harness.started.count > 0 {
            let job2 = try harness.startedJob(0)
            try harness.deliver(job2)
            try await drain()
        }
        
        // Verify downloaded
        #expect(harness.manager.state(for: owner) == .downloaded)
        
        // Simulate reinstall (clears manifest but keeps files)
        harness.simulateReinstall()
        try await harness.restore()
        
        // Records should be empty after reinstall
        #expect(harness.manager.records.isEmpty)
        
        // Now trigger download again
        harness.queue(owner)
        try await drain()
        
        // Should NOT start new downloads - files were reconciled from disk
        #expect(harness.started.isEmpty)
        
        // Should be downloaded again
        #expect(harness.manager.state(for: owner) == .downloaded)
    }
    
    // MARK: - Orphan cleanup
    
    @Test func cleanupOrphanedFilesRemovesUnownedFiles() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        // Create orphaned files
        let url1 = try harness.createOrphanedFile(trackID: "orphan-1")
        let url2 = try harness.createOrphanedFile(trackID: "orphan-2")
        
        // Verify they exist
        #expect(FileManager.default.fileExists(atPath: url1.path))
        #expect(FileManager.default.fileExists(atPath: url2.path))
        
        // Check orphan info
        var info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 2)
        
        // Clean up orphans
        let result = harness.manager.cleanupOrphanedFiles()
        #expect(result.count == 2)
        #expect(result.bytes == Int64(testBytes.count * 2))
        
        // Files should be gone
        #expect(!FileManager.default.fileExists(atPath: url1.path))
        #expect(!FileManager.default.fileExists(atPath: url2.path))
        
        // No more orphans
        info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 0)
    }
    
    @Test func cleanupOrphanedFilesPreservesOwnedFiles() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let album = testAlbum(count: 1)
        let owner = DownloadOwner(album: album, profileID: "listener")
        
        // Create and download a file normally
        harness.queue(owner)
        let job = try harness.startedJob(0)
        try harness.deliver(job)
        try await drain()
        
        // Verify downloaded
        #expect(harness.manager.state(for: owner) == .downloaded)
        
        // Create an orphaned file
        let orphanURL = try harness.createOrphanedFile(trackID: "orphan-1")
        
        // Check orphan info - should only find the orphan, not the owned file
        let info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 1)
        
        // Clean up orphans
        let result = harness.manager.cleanupOrphanedFiles()
        #expect(result.count == 1)
        
        // Orphan gone
        #expect(!FileManager.default.fileExists(atPath: orphanURL.path))
        
        // Owned file still there
        #expect(harness.manager.state(for: owner) == .downloaded)
    }
    
    @Test func orphanedFilesInfoReturnsZeroForCleanDirectory() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 0)
        #expect(info.bytes == 0)
    }
    
    // MARK: - Profile scoping
    
    @Test func reconciliationRespectsProfileScoping() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        let album = testAlbum(count: 1)
        let owner1 = DownloadOwner(album: album, profileID: "listener")
        let owner2 = DownloadOwner(album: album, profileID: "other-listener")
        
        // Pre-create file on disk
        _ = try harness.createCachedFile(for: album.tracks[0])
        
        // Download for first profile
        harness.manager.activeProfileID = "listener"
        harness.queue(owner1)
        try await drain()
        
        // Should be downloaded for profile 1
        #expect(harness.manager.state(for: owner1) == .downloaded)
        
        // Now switch profiles and download
        harness.manager.activeProfileID = "other-listener"
        harness.started.removeAll()
        harness.queue(owner2)
        try await drain()
        
        // Should also be downloaded (shared file, different owner)
        #expect(harness.started.isEmpty) // No new download needed
        #expect(harness.manager.state(for: owner2) == .downloaded)
        
        // Both owners should be on the record
        let key = DownloadManager.cacheKey(trackID: album.tracks[0].id, driveID: "nas-a")
        #expect(harness.manager.records[key]?.owners.contains(owner1.id) == true)
        #expect(harness.manager.records[key]?.owners.contains(owner2.id) == true)
    }
    
    // MARK: - Edge cases
    
    @Test func emptyDirectoryDoesNotCrash() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        // Should handle empty directory gracefully
        let info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 0)
        
        let result = harness.manager.cleanupOrphanedFiles()
        #expect(result.count == 0)
    }
    
    @Test func malformedFilenamesAreIgnored() async throws {
        let harness = try ReconciliationHarness()
        defer { harness.close() }
        try await harness.restore()
        
        // Create files with malformed names
        try testBytes.write(to: harness.directory.appending(path: "short.mp3"))
        try testBytes.write(to: harness.directory.appending(path: "not-hex-GHIJKL0123456789012345678901234567890123456789012345678901.mp3"))
        
        // Should not be detected as orphans (not valid cache keys)
        let info = harness.manager.orphanedFilesInfo()
        #expect(info.count == 0)
    }
}
