import Foundation
import Testing
@testable import SkyrCore

/// Valid, synthetic MP4 tags and an in-memory remote listing. No NAS or media URL is used.
private actor MetadataFixtureDrive: RemoteDrive {
    let id: String
    let displayName = "Metadata fixture"
    let files: [RemoteEntry]
    let media: Data
    let failsListing: Bool
    let failsReads: Bool
    private(set) var reads = 0

    init(id: String = "metadata-fixture", files: [RemoteEntry], media: Data = Data(), failsListing: Bool = false, failsReads: Bool = false) {
        self.id = id
        self.files = files
        self.media = media
        self.failsListing = failsListing
        self.failsReads = failsReads
    }

    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] {
        if failsListing { throw URLError(.timedOut) }
        if path == "/music" {
            return [RemoteEntry(path: metadataFolder, name: "Fixture Album", isDirectory: true, size: nil, modified: nil)]
        }
        let directFiles = files.filter { ($0.path as NSString).deletingLastPathComponent == path }
        let prefix = path + "/"
        let subfolders = Set(files.compactMap { file -> String? in
            guard file.path.hasPrefix(prefix) else { return nil }
            let components = file.path.dropFirst(prefix.count).split(separator: "/")
            return components.count > 1 ? String(components[0]) : nil
        })
        return directFiles + subfolders.sorted().map {
            RemoteEntry(path: prefix + $0, name: $0, isDirectory: true, size: nil, modified: nil)
        }
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        reads += 1
        if failsReads { throw URLError(.timedOut) }
        let start = min(media.count, Int(range.lowerBound))
        let end = min(media.count, Int(range.upperBound))
        return media.subdata(in: start..<end)
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw URLError(.fileDoesNotExist) }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

private nonisolated let metadataFolder = "/music/Fixture Artist/Fixture Album"
private nonisolated let metadataTime = Date(timeIntervalSince1970: 1_700_000_000.125)

private nonisolated func metadataEntry(_ index: Int = 0, size: Int64 = 4096, modified: Date? = metadataTime) -> RemoteEntry {
    let name = "\(index + 1) Folder Song.m4a"
    return RemoteEntry(path: metadataFolder + "/" + name, name: name, isDirectory: false, size: size, modified: modified)
}

private nonisolated func metadataCatalogue(_ files: [RemoteEntry], existing: Catalogue? = nil, force: Bool = false, driveID: String = "metadata-fixture") -> Catalogue {
    Catalogue.build(folders: [ScannedFolder(path: metadataFolder, audio: files, cover: nil)], rootPath: "/music",
                    serverName: "Fixture NAS", driveID: driveID, existing: existing, forceMetadataReread: force)
}

private nonisolated func cachedMetadata(_ files: [RemoteEntry]) -> Catalogue {
    var catalogue = metadataCatalogue(files)
    for album in catalogue.albums.indices {
        for track in catalogue.albums[album].tracks.indices {
            catalogue.albums[album].tracks[track].isEnriched = true
            catalogue.albums[album].tracks[track].tagVersion = Track.currentTagVersion
            catalogue.albums[album].tracks[track].title = "Cached title \(track)"
            catalogue.albums[album].tracks[track].duration = 180
        }
    }
    return catalogue
}

@MainActor private func withMetadataStorage(_ body: @MainActor (LibraryIndexer) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-metadata-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    let indexer = LibraryIndexer(recordDiagnostics: { _ in })
    defer { indexer.cancel() }
    try await CoverStore.$directoryOverride.withValue(directory.appending(path: "covers")) {
        try await body(indexer)
    }
}

@MainActor private func awaitMetadataScan(_ indexer: LibraryIndexer) async throws {
    for _ in 0..<1000 {
        if !indexer.isRunning { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("Synthetic metadata scan did not finish")
}

@MainActor private func runMetadataScan(_ indexer: LibraryIndexer, drive: MetadataFixtureDrive, existing: Catalogue? = nil, force: Bool = false) async throws -> Catalogue {
    var latest: Catalogue?
    indexer.start(drive: drive, rootPath: "/music", serverName: "Fixture NAS", existing: existing, forceMetadataReread: force) { catalogue in
        latest = catalogue
        // A known missing cover should not cause extra media reads in a tag-reuse assertion.
        for album in catalogue.albums { CoverStore.noteMissingCover(for: album.id) }
    }
    try await awaitMetadataScan(indexer)
    #expect(indexer.phase == .done)
    return try #require(latest)
}

@Suite @MainActor struct MetadataRefreshTests {
    @Test func sameSizeEditedTagsReachTheCatalogueAfterTimestampChange() async throws {
        try await withMetadataStorage { indexer in
            let first = metadataMedia(title: "First Title", artist: "First Artist", album: "First Album", genre: "Ambient", year: "2001")
            let second = metadataMedia(title: "Other Title", artist: "Other Artist", album: "Other Album", genre: "New Age", year: "2024")
            #expect(first.count == second.count)
            let old = try await runMetadataScan(indexer, drive: MetadataFixtureDrive(files: [metadataEntry(size: Int64(first.count))], media: first))
            #expect(old.albums.first?.tracks.first?.title == "First Title")
            let changed = metadataEntry(size: Int64(second.count), modified: metadataTime.addingTimeInterval(1))
            let drive = MetadataFixtureDrive(files: [changed], media: second)
            let refreshed = try await runMetadataScan(indexer, drive: drive, existing: old)
            let album = try #require(refreshed.albums.first)
            let track = try #require(album.tracks.first)
            #expect(track.id == old.albums.first?.tracks.first?.id)
            #expect(track.title == "Other Title")
            #expect(track.artist == "Other Artist")
            #expect(album.title == "Other Album")
            #expect(album.artist == "Other Artist")
            #expect(album.genre == "New Age")
            #expect(album.year == 2024)
            #expect(indexer.enrichTotal == 1)
            #expect(await drive.reads > 0)
        }
    }

    @Test(arguments: [false, true]) func explicitRereadBypassesMatchingOrAbsentRevision(hasTimestamp: Bool) async throws {
        try await withMetadataStorage { indexer in
            let file = metadataEntry(modified: hasTimestamp ? metadataTime : nil)
            let old = cachedMetadata([file])
            let media = metadataMedia(title: "Fresh title", artist: "Fresh Artist", album: "Fresh Album", genre: "Ambient", year: "2024")
            let unchanged = MetadataFixtureDrive(files: [file], media: media)
            let cached = try await runMetadataScan(indexer, drive: unchanged, existing: old)
            #expect(cached.albums.first?.tracks.first?.title == "Cached title 0")
            #expect(indexer.enrichTotal == 0)
            #expect(await unchanged.reads == 0)
            let forced = MetadataFixtureDrive(files: [file], media: media)
            let refreshed = try await runMetadataScan(indexer, drive: forced, existing: cached, force: true)
            #expect(refreshed.albums.first?.tracks.first?.title == "Fresh title")
            #expect(indexer.enrichTotal == 1)
            #expect(await forced.reads > 0)
        }
    }

    @Test(arguments: [5000, 15000]) func unchangedLargeLibrariesReuseTagsWithoutReadingMedia(count: Int) async throws {
        try await withMetadataStorage { indexer in
            let files = (0..<count).map { metadataEntry($0) }
            let old = cachedMetadata(files)
            let drive = MetadataFixtureDrive(files: files)
            let refreshed = try await runMetadataScan(indexer, drive: drive, existing: old)
            #expect(refreshed.enrichedTrackCount == count)
            #expect(indexer.enrichTotal == 0)
            #expect(await drive.reads == 0)
        }
    }

    @Test func fractionalModificationTimeSurvivesCataloguePersistence() throws {
        let file = metadataEntry()
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let restored = try decoder.decode(Catalogue.self, from: encoder.encode(cachedMetadata([file])))
        #expect(restored.albums[0].tracks[0].sourceModifiedAt == file.modified?.timeIntervalSince1970)
        #expect(metadataCatalogue([file], existing: restored).enrichedTrackCount == 1)
    }

    @Test func legacyCatalogueIsReadableAndAcquiresItsFirstRevisionOnRefresh() throws {
        let encoder = JSONEncoder()
        var object = try #require(try JSONSerialization.jsonObject(with: encoder.encode(cachedMetadata([metadataEntry()]))) as? [String: Any])
        var albums = try #require(object["albums"] as? [[String: Any]])
        var tracks = try #require(albums[0]["tracks"] as? [[String: Any]])
        tracks[0].removeValue(forKey: "sourceModifiedAt")
        albums[0]["tracks"] = tracks
        object["albums"] = albums
        let old = try JSONDecoder().decode(Catalogue.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.albums[0].tracks[0].sourceModifiedAt == nil)
        let fresh = metadataCatalogue([metadataEntry()], existing: old)
        #expect(fresh.albums[0].tracks[0].tagVersion == nil)
        #expect(fresh.albums[0].tracks[0].title == "Cached title 0")
        #expect(fresh.albums[0].tracks[0].sourceModifiedAt == metadataTime.timeIntervalSince1970)
    }

    @Test func changedRevisionOrExplicitRereadResetsFailureBackoff() {
        let file = metadataEntry()
        var old = metadataCatalogue([file])
        old.albums[0].tracks[0].enrichAttempts = 3
        old.albums[0].tracks[0].enrichAttemptedAt = .now
        #expect(metadataCatalogue([file], existing: old).albums[0].tracks[0].enrichAttempts == 3)
        #expect(metadataCatalogue([file], existing: old, force: true).albums[0].tracks[0].enrichAttempts == nil)
        let changed = metadataEntry(modified: metadataTime.addingTimeInterval(1))
        #expect(metadataCatalogue([changed], existing: old).albums[0].tracks[0].enrichAttempts == nil)
    }

    @Test func sizeTimestampAvailabilityAndSourceChangesInvalidateCachedTags() {
        let old = cachedMetadata([metadataEntry()])
        #expect(metadataCatalogue([metadataEntry(size: 4097)], existing: old).albums[0].tracks[0].tagVersion == nil)
        #expect(metadataCatalogue([metadataEntry(modified: nil)], existing: old).albums[0].tracks[0].tagVersion == nil)
        #expect(metadataCatalogue([metadataEntry()], existing: old, driveID: "another-source").enrichedTrackCount == 0)
    }

    @Test(arguments: [false, true]) func failedTagRereadRetainsLastGoodMetadataAndCanRetry(force: Bool) async throws {
        try await withMetadataStorage { indexer in
            let media = metadataMedia(title: "Last good title", artist: "Last good artist", album: "Last good album", genre: "Jazz", year: "2022")
            let file = metadataEntry(size: Int64(media.count))
            let old = try await runMetadataScan(indexer, drive: MetadataFixtureDrive(files: [file], media: media))
            let listed = metadataEntry(size: file.size!, modified: force ? metadataTime : metadataTime.addingTimeInterval(1))
            let pending = metadataCatalogue([listed], existing: old, force: force).albums[0].tracks[0]
            #expect(pending.title == "Last good title")
            #expect(pending.tagVersion == nil)
            let failedDrive = MetadataFixtureDrive(files: [listed], failsReads: true)
            let failed = try await runMetadataScan(indexer, drive: failedDrive, existing: old, force: force)
            let album = try #require(failed.albums.first)
            let track = try #require(album.tracks.first)
            #expect(album.id == old.albums.first?.id)
            #expect(album.title == "Last good album")
            #expect(album.artist == "Last good artist")
            #expect(album.genre == "Jazz")
            #expect(album.year == 2022)
            #expect(track.title == "Last good title")
            #expect(track.duration == 180)
            #expect(track.tagVersion == nil)
            #expect(track.enrichAttempts == 1)
            #expect(await failedDrive.reads > 0)
            let retried = try await runMetadataScan(indexer, drive: MetadataFixtureDrive(files: [listed], media: media), existing: failed)
            #expect(retried.albums[0].tracks[0].tagVersion == Track.currentTagVersion)
            #expect(indexer.enrichTotal == 1)
        }
    }

    @Test(arguments: ["numbered", "unnumbered", "disc-filename", "disc-folder"])
    func successfulRereadClearsRemovedTagsAndRestoresFilenameAndFolderDefaults(layout: String) async throws {
        try await withMetadataStorage { indexer in
            let media = metadataMedia(title: "Tagged title", artist: "Tagged artist", album: "Tagged album", genre: "Jazz", year: "2022", number: 29, disc: 8)
            let filename = layout == "disc-filename" ? "2-03 Folder Song.m4a"
                : layout == "unnumbered" ? "Folder Song.m4a" : "1 Folder Song.m4a"
            let folder = layout == "disc-folder" ? metadataFolder + "/CD4" : metadataFolder
            let file = RemoteEntry(path: folder + "/" + filename, name: filename, isDirectory: false, size: Int64(media.count), modified: metadataTime)
            let old = try await runMetadataScan(indexer, drive: MetadataFixtureDrive(files: [file], media: media))
            #expect(old.albums[0].tracks[0].number == 29)
            #expect(old.albums[0].tracks[0].disc == 8)
            let untagged = metadataMedia(title: nil, artist: nil, album: nil, genre: nil, year: nil)
            let refreshed = try await runMetadataScan(indexer, drive: MetadataFixtureDrive(files: [file], media: untagged), existing: old, force: true)
            let album = try #require(refreshed.albums.first)
            let track = try #require(album.tracks.first)
            #expect(track.tagVersion == Track.currentTagVersion)
            #expect(track.title == "Folder Song")
            #expect(track.number == (layout == "disc-filename" ? 3 : 1))
            #expect(track.disc == (layout == "disc-filename" ? 2 : layout == "disc-folder" ? 4 : 1))
            #expect(track.artist == nil)
            #expect(track.albumTitleTag == nil)
            #expect(track.albumArtistTag == nil)
            #expect(track.genreTag == nil)
            #expect(track.yearTag == nil)
            #expect(album.title == "Fixture Album")
            #expect(album.artist == "Fixture Artist")
            #expect(album.genre == "Unknown genre")
            #expect(album.year == 0)
        }
    }

    @Test func failedForcedListingKeepsTheCompleteExistingCatalogue() async throws {
        try await withMetadataStorage { indexer in
            let old = cachedMetadata([metadataEntry()])
            var publications = 0
            indexer.start(drive: MetadataFixtureDrive(files: [], failsListing: true), rootPath: "/music", serverName: "Fixture NAS", existing: old, forceMetadataReread: true) { _ in publications += 1 }
            try await awaitMetadataScan(indexer)
            #expect(publications == 0)
            #expect(indexer.phase != .done)
            #expect(old.albums[0].tracks[0].title == "Cached title 0")
        }
    }
}

private nonisolated func metadataMedia(title: String?, artist: String?, album: String?, genre: String?, year: String?, number: UInt8? = nil, disc: UInt8? = nil) -> Data {
    func bytes(_ value: UInt32) -> [UInt8] { [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
    func atom(_ name: String, _ payload: [UInt8]) -> [UInt8] {
        bytes(UInt32(payload.count + 8)) + Array(name.data(using: .isoLatin1)!) + payload
    }
    func text(_ name: String, _ value: String?) -> [UInt8] {
        guard let value else { return [] }
        return atom(name, atom("data", bytes(1) + bytes(0) + Array(value.utf8)))
    }
    func numeric(_ name: String, _ value: UInt8?) -> [UInt8] {
        guard let value else { return [] }
        return atom(name, atom("data", bytes(0) + bytes(0) + [0, 0, 0, value, 0, 0, 0, 0]))
    }
    var header = [UInt8](repeating: 0, count: 100)
    header.replaceSubrange(12..<16, with: bytes(1000))
    header.replaceSubrange(16..<20, with: bytes(180_000))
    let textTags = text("©nam", title) + text("©ART", artist) + text("aART", artist) + text("©alb", album) + text("©gen", genre) + text("©day", year)
    let tags = textTags + numeric("trkn", number) + numeric("disk", disc)
    return Data(atom("ftyp", Array("M4A ".utf8) + bytes(0)) + atom("moov", atom("mvhd", header) + atom("udta", atom("meta", bytes(0) + atom("ilst", tags)))))
}
