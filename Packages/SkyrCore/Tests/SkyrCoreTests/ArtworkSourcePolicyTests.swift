import Foundation
import SkyrShared
import Testing
@testable import SkyrCore

private actor SourceArtworkDrive: RemoteDrive {
    let id = "source-artwork-fixture"
    let displayName = "Source artwork fixture"
    let folders: [ScannedFolder]
    let contents: [String: Data]
    private(set) var reads: [String] = []
    private(set) var downloads: [String] = []

    init(folders: [ScannedFolder], contents: [String: Data]) {
        self.folders = folders
        self.contents = contents
    }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] {
        if path == "/music" {
            return folders.map { RemoteEntry(path: $0.path, name: ($0.path as NSString).lastPathComponent, isDirectory: true, size: nil, modified: nil) }
        }
        guard let folder = folders.first(where: { $0.path == path }) else { return [] }
        return folder.audio + [folder.cover].compactMap { $0 }
    }
    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        reads.append(path)
        guard let data = contents[path] else { throw URLError(.fileDoesNotExist) }
        let lower = min(data.count, Int(range.lowerBound))
        let upper = min(data.count, Int(range.upperBound))
        return data.subdata(in: lower..<upper)
    }
    func download(_ path: String, maxBytes: Int64) async throws -> Data {
        downloads.append(path)
        guard let data = contents[path] else { throw URLError(.fileDoesNotExist) }
        return data
    }
    nonisolated func streamURL(for path: String) -> URL? { nil }
}

private nonisolated let sourceImage = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jRZkAAAAASUVORK5CYII=")!

private nonisolated func sourceFolder(_ name: String, folderCover: Bool) -> ScannedFolder {
    let path = "/music/Fixture Artist/" + name
    let audio = RemoteEntry(path: path + "/Song.flac", name: "Song.flac", isDirectory: false, size: 4096, modified: Date(timeIntervalSince1970: 1_700_000_000))
    let cover = folderCover ? RemoteEntry(path: path + "/cover.png", name: "cover.png", isDirectory: false, size: Int64(sourceImage.count), modified: nil) : nil
    return ScannedFolder(path: path, audio: [audio], cover: cover)
}

private nonisolated func sourceCatalogue(_ folders: [ScannedFolder]) -> Catalogue {
    var catalogue = Catalogue.build(folders: folders, rootPath: "/music", serverName: "Fixture NAS", driveID: "source-artwork-fixture", existing: nil)
    for index in catalogue.albums.indices {
        for track in catalogue.albums[index].tracks.indices {
            catalogue.albums[index].tracks[track].isEnriched = true
            catalogue.albums[index].tracks[track].tagVersion = Track.currentTagVersion
            catalogue.albums[index].tracks[track].title = "Preserved indexed title"
            catalogue.albums[index].tracks[track].duration = 180
        }
    }
    return catalogue
}

private nonisolated func sourceFLAC() -> Data {
    func number(_ value: Int) -> [UInt8] { [UInt8((value >> 24) & 255), UInt8((value >> 16) & 255), UInt8((value >> 8) & 255), UInt8(value & 255)] }
    let mime = Array("image/png".utf8)
    let picture = number(3) + number(mime.count) + mime + number(0) + number(1) + number(1) + number(24) + number(0) + number(sourceImage.count) + [UInt8](sourceImage)
    return Data(Array("fLaC".utf8) + [0x86, UInt8((picture.count >> 16) & 255), UInt8((picture.count >> 8) & 255), UInt8(picture.count & 255)] + picture)
}

@MainActor private func sourceScan(_ indexer: LibraryIndexer, drive: SourceArtworkDrive, existing: Catalogue) async throws -> Catalogue {
    var latest: Catalogue?
    indexer.start(drive: drive, rootPath: "/music", serverName: "Fixture NAS", existing: existing) { latest = $0 }
    for _ in 0..<1000 {
        if !indexer.isRunning { break }
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(indexer.phase == .done)
    return try #require(latest)
}

@Suite @MainActor struct ArtworkSourcePolicyTests {
    @Test(arguments: [false, true]) func enrichedCatalogueRegeneratesSourceCoverWithoutRereadingTags(folderCover: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-source-artwork-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let folder = sourceFolder("Existing Album", folderCover: folderCover)
        let existing = sourceCatalogue([folder])
        let albumID = try #require(existing.albums.first?.id)
        let legacy = directory.appending(path: "Skyr/covers")
        let legacyImage = await CoverStore.$directoryOverride.withValue(legacy) { () async -> URL in
            CoverStore.save(Data([9, 8, 7]), for: albumID)
            CoverStore.noteMissingCover(for: albumID)
            return CoverStore.fileURL(for: albumID)
        }
        let consent = directory.appending(path: "Skyr/ArtworkPrivacy/apple-artwork-v1")
        try FileManager.default.createDirectory(at: consent.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("enabled-v1".utf8).write(to: consent)
        let source = folderCover ? folder.cover!.path : folder.audio[0].path
        let drive = SourceArtworkDrive(folders: [folder], contents: [source: folderCover ? sourceImage : sourceFLAC()])
        let indexer = LibraryIndexer(recordDiagnostics: { _ in })
        defer { indexer.cancel() }
        try await CoverStore.$directoryOverride.withValue(CoverStore.sourceDirectory(in: directory)) {
            #expect(!CoverStore.hasCover(for: albumID))
            #expect(CoverStore.missingCoverDate(for: albumID) == nil)
            #expect(CoverStore.palette(for: albumID) == nil)
            let regenerated = try await sourceScan(indexer, drive: drive, existing: existing)
            #expect(indexer.enrichTotal == 0)
            let album = try #require(regenerated.albums.first)
            #expect(album.tracks.first?.title == "Preserved indexed title")
            #expect(album.tracks.first?.duration == 180)
            #expect(try Data(contentsOf: CoverStore.fileURL(for: album.id)) == sourceImage)
            let firstReads = await drive.reads
            let firstDownloads = await drive.downloads
            #expect(folderCover ? firstReads.isEmpty : !firstReads.isEmpty)
            #expect(folderCover ? firstDownloads == [source] : firstDownloads.isEmpty)
            _ = try await sourceScan(indexer, drive: drive, existing: regenerated)
            #expect(await drive.reads == firstReads)
            #expect(await drive.downloads == firstDownloads)
            #expect(try Data(contentsOf: legacyImage) == Data([9, 8, 7]))
            #expect(try Data(contentsOf: consent) == Data("enabled-v1".utf8))
        }
    }

    @Test func repeatedNASImagesStayAsSourceCoversOnScanAndManualRefresh() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-source-artwork-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await CoverStore.$directoryOverride.withValue(directory) {
            let folders = [sourceFolder("First Album", folderCover: true), sourceFolder("Second Album", folderCover: true)]
            let drive = SourceArtworkDrive(folders: folders, contents: Dictionary(uniqueKeysWithValues: folders.map { ($0.cover!.path, sourceImage) }))
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            defer { indexer.cancel() }
            let catalogue = try await sourceScan(indexer, drive: drive, existing: sourceCatalogue(folders))
            #expect(catalogue.albums.count == 2)
            for album in catalogue.albums { #expect(try Data(contentsOf: CoverStore.fileURL(for: album.id)) == sourceImage) }
            let library = LibraryStore()
            library.replace(with: catalogue, drive: drive)
            let album = try #require(library.albums.first)
            let result = await library.refreshCover(for: album)
            #expect(result.hasPrefix("Cover taken from folder image"))
            #expect(try Data(contentsOf: CoverStore.fileURL(for: album.id)) == sourceImage)
        }
    }

    @Test func sourceCacheClearDoesNotTouchLegacyCoversOrMusic() throws {
        let support = FileManager.default.temporaryDirectory.appending(path: "skyr-source-artwork-\(UUID())")
        defer { try? FileManager.default.removeItem(at: support) }
        let legacy = support.appending(path: "Skyr/covers")
        let downloadedMusic = support.appending(path: "Skyr/downloads/saved.flac")
        try FileManager.default.createDirectory(at: downloadedMusic.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([1, 2, 3, 4]).write(to: downloadedMusic)
        CoverStore.$directoryOverride.withValue(legacy) { CoverStore.save(sourceImage, for: "legacy") }
        let legacyImage = CoverStore.$directoryOverride.withValue(legacy) { CoverStore.fileURL(for: "legacy") }
        try CoverStore.$directoryOverride.withValue(CoverStore.sourceDirectory(in: support)) {
            CoverStore.save(sourceImage, for: "new")
            CoverStore.clear()
            #expect(!CoverStore.hasCover(for: "new"))
            let oldImage = try Data(contentsOf: legacyImage)
            let audio = try Data(contentsOf: downloadedMusic)
            #expect(oldImage == sourceImage)
            #expect(audio == Data([1, 2, 3, 4]))
        }
    }
}
