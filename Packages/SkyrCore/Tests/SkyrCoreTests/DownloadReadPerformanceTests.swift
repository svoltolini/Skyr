import CryptoKit
import Foundation
import Testing
@testable import SkyrCore

@Test func downloadCacheKeysRemainByteCompatibleWithExistingManifests() throws {
    let values = ["", "a", "a|b", "a/b", "Björk 音楽 🎵", "quoted\"\\", String(repeating: "long/path/", count: 100)]
    for source in values {
        for track in values {
            let data = try JSONEncoder().encode([source, track])
            let expected = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            #expect(DownloadManager.cacheKey(trackID: track, driveID: source) == expected)
        }
    }
    #expect(DownloadManager.cacheKey(trackID: "a|b", driveID: "c") != DownloadManager.cacheKey(trackID: "b", driveID: "c|a"))
}

@Test @MainActor func emptyDownloadStatusDoesNotReadTheSourceForEveryPlaylistSong() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-download-read-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: directory) }
    var sourceReads = 0
    let manager = DownloadManager(directory: directory, configuration: .ephemeral, restoreTasks: { _, completion in completion([]) })
    manager.driveIDProvider = { sourceReads += 1; return "performance-source" }
    let track = SampleLibrary.catalogue.albums[0].tracks[0]
    let playlist = Playlist(id: "large", name: "Large", summary: "", covers: [], tracks: Array(repeating: track, count: 15_000))
    let owner = manager.owner(for: playlist)
    #expect(manager.state(for: owner) == .none)
    #expect(manager.downloadedCount(for: owner) == 0)
    #expect(sourceReads == 1, "An empty download collection should use one owner-level lookup, independent of playlist size")
}
