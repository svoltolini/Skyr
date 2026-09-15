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
    if case .failed(let message) = manager.state(for: owner) { #expect(message.contains("Connect to your NAS")) }
    else { Issue.record("An offline download should expose a retryable failure") }
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

@Test @MainActor func renamedAlbumKeepsItsDownloadsUnderTheNewIdentity() throws {
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let album = singleTrackAlbum()
    let track = album.tracks[0]
    var renamed = album
    renamed.title = album.title + " (Remastered)"
    let renamedID = Album.makeID(title: renamed.title, artist: renamed.artist)
    let before = DownloadOwner(album: album, profileID: "sam")
    let other = DownloadOwner(album: album, profileID: "kid")
    let playlist = "profile:sam|playlist:mix"
    let record = DownloadRecord(trackID: track.id, driveID: "nas-a", fileName: "song.flac", bytes: 4, owners: [before.id, other.id, playlist])
    try Data("FLAC".utf8).write(to: directory.appending(path: record.fileName))
    try JSONEncoder().encode([record]).write(to: directory.appending(path: "downloads.json"))
    let manager = DownloadManager(directory: directory, configuration: .ephemeral)
    manager.driveIDProvider = { "nas-a" }
    manager.activeProfileID = "sam"
    var memberships: [[String]] = []
    manager.onMembershipChanged = { _, albums, _ in memberships.append(albums) }
    manager.reassignAlbum(from: album.id, to: renamedID)
    let owner = DownloadOwner(album: Album(
        id: renamedID, title: renamed.title, artist: renamed.artist, year: renamed.year, genre: renamed.genre, label: nil,
        tracks: renamed.tracks, colorA: renamed.colorA, colorB: renamed.colorB, addedRank: 0, folderPath: nil, coverPath: nil,
        folderTitle: renamed.title, folderArtist: renamed.artist, folderYear: nil
    ), profileID: "sam")
    #expect(manager.state(for: owner) == .downloaded)
    #expect(manager.state(for: before) == .none)
    #expect(manager.records.values.first?.owners == [owner.id, DownloadOwner.scope("kid") + DownloadOwner.albumPrefix + renamedID, playlist])
    #expect(memberships == [[renamedID]])
    let saved = try JSONDecoder().decode([DownloadRecord].self, from: Data(contentsOf: directory.appending(path: "downloads.json")))
    #expect(saved.first?.owners.contains(owner.id) == true)
    // The same rename again, or one to the same id, changes nothing.
    manager.reassignAlbum(from: album.id, to: renamedID)
    manager.reassignAlbum(from: renamedID, to: renamedID)
    #expect(memberships.count == 1)
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
    #expect(manager.state(for: first) == .cancelled(done: 0, total: 1))
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

// MARK: - Watch Manifest Validation Tests (Issue #16)

private func multiTrackPlaylist(driveID: String = "nas-a", profileID: String = "profile-a") -> WatchPlaylist {
    let tracks = [
        WatchTrack(id: "track-1", title: "Song One", artist: "Artist", album: "Album", duration: 180,
                   path: "/music/Album/01.wav", fileSize: Int64(watchAudioFixture.count), format: "WAV", isLossless: true),
        WatchTrack(id: "track-2", title: "Song Two", artist: "Artist", album: "Album", duration: 200,
                   path: "/music/Album/02.wav", fileSize: Int64(watchAudioFixture.count), format: "WAV", isLossless: true),
        WatchTrack(id: "track-3", title: "Song Three", artist: "Artist", album: "Album", duration: 220,
                   path: "/music/Album/03.wav", fileSize: Int64(watchAudioFixture.count), format: "WAV", isLossless: true),
    ]
    return WatchPlaylist(id: "test-playlist", name: "Test Playlist", isSmart: false, coverColours: [], tracks: tracks, totalSongs: 3,
                         driveID: driveID, profileID: profileID)
}

@Test func validatedFileIDsReturnsOnlyExistingValidFiles() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))
    manifest.generation = generation

    for track in playlist.tracks.prefix(2) {
        let job = try #require(WatchDownloadJob(playlist: playlist, track: track, generation: generation))
        let destination = job.destination(in: directory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try watchAudioFixture.write(to: destination)
        manifest.files[track.id] = generation.uuidString + "/" + job.fileName
    }

    let validated = manifest.validatedFileIDs(for: playlist, root: directory)
    #expect(validated.count == 2)
    #expect(validated.contains("track-1"))
    #expect(validated.contains("track-2"))
    #expect(!validated.contains("track-3"))
}

@Test func validatedFileIDsExcludesMissingFiles() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))

    for track in playlist.tracks {
        let job = try #require(WatchDownloadJob(playlist: playlist, track: track, generation: generation))
        manifest.files[track.id] = generation.uuidString + "/" + job.fileName
    }

    let validated = manifest.validatedFileIDs(for: playlist, root: directory)
    #expect(validated.isEmpty, "Files that don't exist on disk should not be validated")
}

@Test func validatedFileIDsExcludesCorruptFiles() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))

    for (index, track) in playlist.tracks.enumerated() {
        let job = try #require(WatchDownloadJob(playlist: playlist, track: track, generation: generation))
        let destination = job.destination(in: directory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if index == 0 {
            try watchAudioFixture.write(to: destination)
        } else {
            try watchAudioFixture.dropLast().write(to: destination)
        }
        manifest.files[track.id] = generation.uuidString + "/" + job.fileName
    }

    let validated = manifest.validatedFileIDs(for: playlist, root: directory)
    #expect(validated.count == 1)
    #expect(validated.contains("track-1"), "Only the valid file should be counted")
}

@Test func invalidFileIDsIdentifiesMissingAndCorruptFiles() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))

    let validTrack = playlist.tracks[0]
    let missingTrack = playlist.tracks[1]
    let corruptTrack = playlist.tracks[2]

    let validJob = try #require(WatchDownloadJob(playlist: playlist, track: validTrack, generation: generation))
    let validDest = validJob.destination(in: directory)
    try FileManager.default.createDirectory(at: validDest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try watchAudioFixture.write(to: validDest)
    manifest.files[validTrack.id] = generation.uuidString + "/" + validJob.fileName

    let missingJob = try #require(WatchDownloadJob(playlist: playlist, track: missingTrack, generation: generation))
    manifest.files[missingTrack.id] = generation.uuidString + "/" + missingJob.fileName

    let corruptJob = try #require(WatchDownloadJob(playlist: playlist, track: corruptTrack, generation: generation))
    let corruptDest = corruptJob.destination(in: directory)
    try FileManager.default.createDirectory(at: corruptDest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try watchAudioFixture.dropLast().write(to: corruptDest)
    manifest.files[corruptTrack.id] = generation.uuidString + "/" + corruptJob.fileName

    let invalid = manifest.invalidFileIDs(for: playlist, root: directory)
    #expect(invalid.count == 2)
    #expect(invalid.contains(missingTrack.id))
    #expect(invalid.contains(corruptTrack.id))
    #expect(!invalid.contains(validTrack.id))
}

@Test func outstandingTrackIDsReturnsDesiredMinusValidated() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))
    manifest.generation = generation

    let job = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[0], generation: generation))
    let destination = job.destination(in: directory)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try watchAudioFixture.write(to: destination)
    manifest.files[playlist.tracks[0].id] = generation.uuidString + "/" + job.fileName

    let outstanding = manifest.outstandingTrackIDs(for: playlist, root: directory)
    #expect(outstanding.count == 2)
    #expect(!outstanding.contains("track-1"))
    #expect(outstanding.contains("track-2"))
    #expect(outstanding.contains("track-3"))
}

@Test func pruneInvalidFilesRemovesStaleEntries() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))

    let validJob = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[0], generation: generation))
    let validDest = validJob.destination(in: directory)
    try FileManager.default.createDirectory(at: validDest.deletingLastPathComponent(), withIntermediateDirectories: true)
    try watchAudioFixture.write(to: validDest)
    manifest.files[playlist.tracks[0].id] = generation.uuidString + "/" + validJob.fileName

    let missingJob = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[1], generation: generation))
    manifest.files[playlist.tracks[1].id] = generation.uuidString + "/" + missingJob.fileName

    #expect(manifest.files.count == 2)
    let pruned = manifest.pruneInvalidFiles(for: playlist, root: directory)
    #expect(pruned.count == 1)
    #expect(pruned.contains("track-2"))
    #expect(manifest.files.count == 1)
    #expect(manifest.files["track-1"] != nil)
    #expect(manifest.files["track-2"] == nil)
}

@Test func manifestValidationHandlesSmartPlaylistChanges() throws {
    var playlist = multiTrackPlaylist()
    playlist.isSmart = true
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))
    manifest.generation = generation

    for track in playlist.tracks {
        let job = try #require(WatchDownloadJob(playlist: playlist, track: track, generation: generation))
        let destination = job.destination(in: directory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try watchAudioFixture.write(to: destination)
        manifest.files[track.id] = generation.uuidString + "/" + job.fileName
    }

    #expect(manifest.availableFiles(for: playlist, root: directory).count == 3)
    #expect(manifest.validatedFileIDs(for: playlist, root: directory).count == 3)
    #expect(manifest.outstandingTrackIDs(for: playlist, root: directory).isEmpty)

    var changedPlaylist = playlist
    changedPlaylist.tracks = Array(playlist.tracks.prefix(1))
    changedPlaylist.tracks.append(WatchTrack(
        id: "track-new", title: "New Song", artist: "Artist", album: "Album", duration: 150,
        path: "/music/Album/new.wav", fileSize: Int64(watchAudioFixture.count), format: "WAV", isLossless: true
    ))

    let validatedAfterChange = manifest.validatedFileIDs(for: changedPlaylist, root: directory)
    #expect(validatedAfterChange.count == 1, "Only track-1 is both in files and current playlist")
    #expect(validatedAfterChange.contains("track-1"))

    let availableAfterChange = manifest.availableFiles(for: changedPlaylist, root: directory)
    #expect(availableAfterChange.count == 1)
    #expect(availableAfterChange[0].track.id == "track-1")
}

@Test func manifestValidationHandlesDeletedFilesOnRelaunch() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))
    manifest.generation = nil

    for track in playlist.tracks {
        let job = try #require(WatchDownloadJob(playlist: playlist, track: track, generation: generation))
        let destination = job.destination(in: directory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try watchAudioFixture.write(to: destination)
        manifest.files[track.id] = generation.uuidString + "/" + job.fileName
    }

    #expect(manifest.validatedFileIDs(for: playlist, root: directory).count == 3)

    let deletedJob = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[1], generation: generation))
    try FileManager.default.removeItem(at: deletedJob.destination(in: directory))

    let validatedAfterDelete = manifest.validatedFileIDs(for: playlist, root: directory)
    #expect(validatedAfterDelete.count == 2)
    #expect(!validatedAfterDelete.contains("track-2"))

    let outstanding = manifest.outstandingTrackIDs(for: playlist, root: directory)
    #expect(outstanding.count == 1)
    #expect(outstanding.contains("track-2"))

    let invalid = manifest.invalidFileIDs(for: playlist, root: directory)
    #expect(invalid.count == 1)
    #expect(invalid.contains("track-2"))
}

@Test func manifestPersistencePreservesValidationState() throws {
    let playlist = multiTrackPlaylist()
    let directory = try downloadTestDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let generation = UUID()
    var manifest = WatchDownloadManifest()
    manifest.desired = Set(playlist.tracks.map(\.id))
    manifest.generation = generation

    let job = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[0], generation: generation))
    let destination = job.destination(in: directory)
    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
    try watchAudioFixture.write(to: destination)
    manifest.files[playlist.tracks[0].id] = generation.uuidString + "/" + job.fileName

    let encoded = try JSONEncoder().encode(manifest)
    let decoded = try JSONDecoder().decode(WatchDownloadManifest.self, from: encoded)

    #expect(decoded.desired == manifest.desired)
    #expect(decoded.files == manifest.files)
    #expect(decoded.generation == manifest.generation)
    #expect(decoded.validatedFileIDs(for: playlist, root: directory) == manifest.validatedFileIDs(for: playlist, root: directory))
    #expect(decoded.outstandingTrackIDs(for: playlist, root: directory) == manifest.outstandingTrackIDs(for: playlist, root: directory))
}
