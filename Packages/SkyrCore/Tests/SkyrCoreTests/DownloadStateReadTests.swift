import Foundation
import Testing
@testable import SkyrCore

@Test func backgroundDownloadSnapshotPreservesOccurrencesAndTerminalStates() throws {
    let first = SampleLibrary.catalogue.albums[0].tracks[0]
    let second = SampleLibrary.catalogue.albums[0].tracks[1]
    let playlist = Playlist(id: "duplicates", name: "Duplicates", summary: "", covers: [], tracks: [first, second, first])
    let owner = DownloadOwner(playlist: playlist, profileID: "profile")
    let firstKey = DownloadManager.cacheKey(trackID: first.id, driveID: "source")
    let secondKey = DownloadManager.cacheKey(trackID: second.id, driveID: "source")
    let record = DownloadRecord(trackID: first.id, driveID: "source", fileName: "first.wav", bytes: 4, owners: [owner.id])
    func snapshot(pending: Set<String> = [], cancelled: Bool = false, error: String? = nil) -> DownloadStateSnapshot {
        DownloadStateSnapshot(owner: owner, driveID: "source", records: [firstKey: record], simulatedKeys: [],
                              pending: pending, progress: [secondKey: 0.5], cancelled: cancelled,
                              errors: error.map { ["first": $0] } ?? [:], directory: URL(filePath: "/fixture"))
    }
    #expect(try snapshot().read { _ in true } == .partial(done: 2, total: 3, message: nil))
    #expect(try snapshot(pending: [secondKey]).read { _ in true } == .downloading(fraction: 2.5 / 3, done: 2, total: 3))
    #expect(try snapshot(cancelled: true).read { _ in true } == .cancelled(done: 2, total: 3))
    #expect(try snapshot(error: "Unavailable").read { _ in true } == .partial(done: 2, total: 3, message: "Unavailable"))
    #expect(try snapshot(error: "Unavailable").read { _ in false } == .failed(message: "Unavailable"))
    #expect(try snapshot().read { _ in false } == .none)
}

@Test func backgroundDownloadReadChecksActualFilesAgainAfterExternalRemoval() async throws {
    let fixture = try DownloadReadFixture()
    defer { fixture.cleanUp() }
    #expect(try await fixture.manager.readState(for: fixture.owner) == .downloaded)
    try FileManager.default.removeItem(at: fixture.audioURL)
    #expect(try await fixture.manager.readState(for: fixture.owner) == .none)
    #expect(fixture.manager.localURL(for: fixture.owner.tracks[0]) == nil)
    try Data([0, 0, 0, 0]).write(to: fixture.audioURL)
    #expect(try await fixture.manager.readState(for: fixture.owner) == .downloaded)
    fixture.manager.activeProfileID = "another-profile"
    await #expect(throws: CancellationError.self) { try await fixture.manager.readState(for: fixture.owner) }
}

@Test(arguments: ["source", "profile", "metadata", "cancel"])
func backgroundDownloadReadRejectsReplacedInputsAndCancellation(_ change: String) async throws {
    let fixture = try DownloadReadFixture()
    defer { fixture.cleanUp() }
    let gate = DownloadReadGate()
    let task = Task { try await fixture.manager.readState(for: fixture.owner, fileExists: { gate.check($0) }) }
    let deadline = ContinuousClock.now.advanced(by: .seconds(30))
    while !gate.started, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
    guard gate.started else {
        gate.release()
        task.cancel()
        Issue.record("Background file check never started")
        return
    }
    // The actor reached this point while the file checker was suspended on its worker thread.
    #expect(!gate.wasOnMainThread)
    switch change {
    case "source": fixture.manager.driveIDProvider = { "replacement-source" }
    case "profile": fixture.manager.activeProfileID = "replacement-profile"
    case "metadata": fixture.manager.adoptLegacyOwners(into: "profile")
    default: task.cancel()
    }
    gate.release()
    await #expect(throws: CancellationError.self) { try await task.value }
}

private struct DownloadReadFixture {
    let directory: URL
    let audioURL: URL
    let owner: DownloadOwner
    let manager: DownloadManager

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "skyr-state-read-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        audioURL = directory.appending(path: "fixture.wav")
        try Data([0, 0, 0, 0]).write(to: audioURL)
        let track = SampleLibrary.catalogue.albums[0].tracks[0]
        owner = DownloadOwner(playlist: Playlist(id: "fixture", name: "Fixture", summary: "", covers: [], tracks: [track, track]), profileID: "profile")
        let record = DownloadRecord(trackID: track.id, driveID: "source", fileName: "fixture.wav", bytes: 4, owners: [owner.id, "album:legacy"])
        try JSONEncoder().encode([record]).write(to: directory.appending(path: "downloads.json"))
        manager = DownloadManager(directory: directory, configuration: .ephemeral, restoreTasks: { _, _ in })
        manager.activeProfileID = "profile"
        manager.driveIDProvider = { "source" }
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

private nonisolated final class DownloadReadGate: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var didStart = false
    private var onMainThread = false
    var started: Bool { lock.withLock { didStart } }
    var wasOnMainThread: Bool { lock.withLock { onMainThread } }
    func check(_ url: URL) -> Bool {
        lock.withLock { didStart = true; onMainThread = Thread.isMainThread }
        _ = semaphore.wait(timeout: .now() + 30)
        return FileManager.default.fileExists(atPath: url.path)
    }
    func release() { semaphore.signal() }
}
