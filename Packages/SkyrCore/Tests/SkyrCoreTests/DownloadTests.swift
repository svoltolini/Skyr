import Foundation
import Testing
@testable import SkyrCore

private func downloadTestDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appending(path: "SkyrDownloadTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

private func singleTrackAlbum() -> Album {
    var album = SampleLibrary.catalogue.albums[0]
    album.tracks = Array(album.tracks.prefix(1))
    return album
}

@Test @MainActor func offlineRealDownloadDoesNotPretendToComplete() throws {
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = DownloadManager(directory: directory, configuration: .ephemeral)
    manager.driveIDProvider = { "nas-a" }
    let owner = manager.owner(for: singleTrackAlbum())
    manager.download(owner, driveID: "nas-a") { _ in nil }
    #expect(manager.state(for: owner) == .none)
    #expect(manager.records.isEmpty)
    #expect(manager.pendingByOwner.isEmpty)
    #expect(manager.lastError?.contains("Connect to your NAS") == true)
    manager.clearError()
    #expect(manager.lastError == nil)
}

@Test @MainActor func cacheMigrationKeepsRealFilesAndScopesIdenticalTracksToTheirNAS() throws {
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let album = singleTrackAlbum()
    let track = album.tracks[0]
    let owner = DownloadOwner(album: album, profileID: "default")
    let a = DownloadRecord(trackID: track.id, driveID: "nas-a", fileName: "old-a.flac", bytes: 4, owners: [owner.id])
    let b = DownloadRecord(trackID: track.id, driveID: "nas-b", fileName: "old-b.flac", bytes: 4, owners: [owner.id])
    let invalid = DownloadRecord(trackID: "missing", driveID: "nas-a", fileName: "", bytes: 100, owners: [owner.id])
    try Data("NAS A".utf8).write(to: directory.appending(path: a.fileName))
    try Data("NAS B".utf8).write(to: directory.appending(path: b.fileName))
    try JSONEncoder().encode([a, b, invalid]).write(to: directory.appending(path: "downloads.json"))
    let manager = DownloadManager(directory: directory, configuration: .ephemeral)
    manager.driveIDProvider = { "nas-a" }
    #expect(try Data(contentsOf: #require(manager.localURL(for: track))) == Data("NAS A".utf8))
    #expect(manager.downloadedCount(for: owner) == 1)
    manager.driveIDProvider = { "nas-b" }
    #expect(try Data(contentsOf: #require(manager.localURL(for: track))) == Data("NAS B".utf8))
    manager.driveIDProvider = { "nas-c" }
    #expect(manager.localURL(for: track) == nil)
    #expect(!manager.isDownloaded(track))
    #expect(manager.state(for: owner) == .none)
    #expect(DownloadManager.fileName(for: track, driveID: "nas-a") != DownloadManager.fileName(for: track, driveID: "nas-b"))
    let repaired = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: directory.appending(path: "downloads.json")))
    #expect(repaired.count == 2)
    #expect(repaired.allSatisfy { !$0.fileName.isEmpty })
    manager.driveIDProvider = { "nas-a" }
    try FileManager.default.removeItem(at: directory.appending(path: a.fileName))
    #expect(!manager.isDownloaded(track))
    #expect(manager.state(for: owner) == .none)
}

@Test @MainActor func explicitSampleDownloadKeepsOnlyCurrentOwnersAndDoesNotPersistFakeFiles() async throws {
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let manager = DownloadManager(directory: directory, configuration: .ephemeral)
    let album = singleTrackAlbum()
    let first = DownloadOwner(album: album, profileID: "first")
    let second = DownloadOwner(album: album, profileID: "second")
    manager.download(first, driveID: "", isSample: true) { _ in nil }
    manager.download(second, driveID: "", isSample: true) { _ in nil }
    let waiting = try JSONDecoder().decode([String: Set<String>].self, from: Data(contentsOf: directory.appending(path: "pending.json")))
    #expect(waiting[first.id]?.count == 1)
    #expect(waiting[second.id]?.count == 1)
    manager.cancel(first)
    for _ in 0..<40 {
        if manager.state(for: second) == .downloaded { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    #expect(manager.state(for: first) == .none)
    #expect(manager.state(for: second) == .downloaded)
    #expect(manager.records.values.first?.owners == [second.id])
    let saved = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: directory.appending(path: "downloads.json")))
    #expect(saved.isEmpty)
}

private func watchPlaylist(driveID: String = "nas-a", profileID: String = "profile-a") -> WatchPlaylist {
    let path = "/music/Björk/Album/01 Song | Live.wav"
    let first = WatchTrack(id: path, title: "Song | Live", artist: "Björk", album: "Album", duration: 240,
                           path: path, fileSize: Int64(watchAudioFixture.count), format: "WAV", isLossless: true)
    return WatchPlaylist(id: "favourites", name: "Favourites", isSmart: true, coverColours: [], tracks: [first], totalSongs: 1,
                         driveID: driveID, profileID: profileID)
}

/// A complete PCM WAV with one silent 16-bit mono sample at 8 kHz.
private let watchAudioFixture = Data([
    0x52, 0x49, 0x46, 0x46, 38, 0, 0, 0, 0x57, 0x41, 0x56, 0x45,
    0x66, 0x6d, 0x74, 0x20, 16, 0, 0, 0, 1, 0, 1, 0,
    0x40, 0x1f, 0, 0, 0x80, 0x3e, 0, 0, 2, 0, 16, 0,
    0x64, 0x61, 0x74, 0x61, 2, 0, 0, 0, 0, 0,
])

@Test func watchTaskMetadataPreservesNestedUnicodeNamesAndSeparatesSources() throws {
    let playlist = watchPlaylist()
    let job = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[0], generation: UUID()))
    #expect(WatchDownloadJob.decode(job.encoded) == job)
    #expect(job.fileName.hasSuffix(".wav"))
    #expect(job.expectedBytes == Int64(watchAudioFixture.count))
    #expect(!job.fileName.contains("/"))
    #expect(!job.fileName.contains("|"))
    #expect(playlist.cacheID != watchPlaylist(driveID: "nas-b").cacheID)
    #expect(playlist.cacheID != watchPlaylist(profileID: "profile-b").cacheID)
    let credentials = WatchCredentials(baseURL: URL(string: "https://nas.example")!, account: "listener", password: "test-only", driveID: "nas-a")
    #expect(credentials.matches(playlist))
    #expect(!credentials.matches(watchPlaylist(driveID: "nas-b")))
    #expect(!WatchCredentials(baseURL: credentials.baseURL, account: "listener", password: "test-only").matches(playlist))
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = job.destination(in: directory)
    #expect(destination.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path + "/"))
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try watchAudioFixture.write(to: destination)
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))
    manifest.generation = job.generation
    manifest.files[job.trackID] = job.generation.uuidString + "/" + job.fileName
    let saved = try JSONDecoder().decode(WatchDownloadManifest.self, from: JSONEncoder().encode(manifest))
    #expect(saved.availableFiles(for: playlist, root: directory).count == 1)
    #expect(saved.hasStoredFiles)
    #expect(saved.availableFiles(for: watchPlaylist(driveID: "nas-b"), root: directory).isEmpty)
    #expect(saved.availableFiles(for: watchPlaylist(profileID: "profile-b"), root: directory).isEmpty)
    try FileManager.default.removeItem(at: destination)
    #expect(saved.availableFiles(for: playlist, root: directory).isEmpty)
    // Retrying reuses a safe destination after an interrupted/failed save.
    try watchAudioFixture.write(to: destination)
    #expect(saved.availableFiles(for: playlist, root: directory).count == 1)
    var changed = playlist
    changed.tracks.append(WatchTrack(id: "/music/Björk/Album/02 Encore.flac", title: "Encore", artist: "Björk", album: "Album", duration: 120,
                                     path: "/music/Björk/Album/02 Encore.flac", fileSize: 32, format: "FLAC", isLossless: true))
    #expect(saved.availableFiles(for: changed, root: directory).count == 1)
    #expect(saved.availableFiles(for: changed, root: directory).count != changed.tracks.count)
}

@Test func watchAudioValidationRejectsIncompleteFilesAndOrdinaryServerErrors() throws {
    let playlist = watchPlaylist()
    let job = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[0], generation: UUID()))
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = job.destination(in: directory)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    var manifest = WatchDownloadManifest()
    manifest.files[job.trackID] = job.generation.uuidString + "/" + job.fileName
    manifest.desired = [job.trackID]

    try watchAudioFixture.write(to: destination)
    #expect(WatchDownloadValidation.failure(for: destination, expectedBytes: job.expectedBytes, contentType: "audio/wav") == nil)
    #expect(manifest.availableFiles(for: playlist, root: directory).count == 1)
    try watchAudioFixture.dropLast().write(to: destination)
    #expect(WatchDownloadValidation.failure(for: destination, expectedBytes: job.expectedBytes) == .sizeMismatch)
    #expect(manifest.availableFiles(for: playlist, root: directory).isEmpty)
    #expect(manifest.hasStoredFiles, "Incomplete files must still expose a removal action")

    try Data("{\"success\":false,\"message\":\"Please sign in again\"}".utf8).write(to: destination)
    #expect(WatchDownloadValidation.failure(for: destination, expectedBytes: nil, statusCode: 200) == .serverMessage)
    #expect(manifest.availableFiles(for: playlist, root: directory).isEmpty)
    try Data("<html><body>Service unavailable</body></html>".utf8).write(to: destination)
    #expect(WatchDownloadValidation.failure(for: destination, expectedBytes: nil, statusCode: 200) == .serverMessage)
    #expect(WatchDownloadValidation.failure(for: destination, expectedBytes: nil, statusCode: 503) == .serverStatus(503))
    try watchAudioFixture.write(to: destination)
    #expect(WatchDownloadValidation.failure(for: destination, expectedBytes: job.expectedBytes, contentType: "application/json") == .serverMessage)
    try Data().write(to: destination)
    #expect(WatchDownloadValidation.failure(for: destination, expectedBytes: job.expectedBytes) == .missingOrEmpty)
    #expect(manifest.availableFiles(for: playlist, root: directory).isEmpty)
}

@Test func watchNavigationResolvesLatestMembershipWithinTheSameSourceAndProfile() throws {
    let snapshot = watchPlaylist()
    var updated = snapshot
    updated.name = "Updated favourites"
    updated.tracks.append(WatchTrack(id: "encore", title: "Encore", artist: "Björk", album: "Album", duration: 120,
                                     path: "/music/Björk/Album/02 Encore.wav", fileSize: 46, format: "WAV", isLossless: true))
    var catalogue = WatchCatalogue(serverName: "NAS", profileName: "Me", playlists: [updated])
    #expect(catalogue.playlist(matching: snapshot) == updated)
    #expect(catalogue.playlist(matching: snapshot)?.tracks.count == 2)
    catalogue.playlists = [watchPlaylist(driveID: "nas-b")]
    #expect(catalogue.playlist(matching: snapshot) == nil)
    catalogue.playlists = [watchPlaylist(profileID: "profile-b")]
    #expect(catalogue.playlist(matching: snapshot) == nil)
    catalogue.playlists = []
    #expect(catalogue.playlist(matching: snapshot) == nil)
}
