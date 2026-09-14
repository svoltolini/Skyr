import Foundation
import Testing
@testable import SkyrCore

@Test @MainActor func searchRevisionPublishesAddedRemovedAndRetaggedMatches() async {
    let store = LibraryStore()
    var catalogue = Catalogue.build(
        folders: [ScannedFolder(path: "/music/Artist/First", audio: [
            RemoteEntry(path: "/music/Artist/First/01 Song.flac", name: "01 Song.flac",
                        isDirectory: false, size: 1024, modified: nil)
        ], cover: nil)],
        rootPath: "/music", serverName: "Search test", driveID: "", existing: nil
    )
    store.replace(with: catalogue, drive: nil)
    let initialRevision = store.contentRevision
    #expect(initialRevision > 0)
    #expect(store.searchResults("signal").isEmpty)

    // Enrichment changes names while the user's query remains the same.
    catalogue.albums[0].title = "Signal Album"
    catalogue.albums[0].artist = "Signal Artist"
    catalogue.albums[0].tracks[0].title = "Signal Song"
    store.replace(with: catalogue, drive: nil)
    await store.derivationTask?.value
    #expect(store.contentRevision > initialRevision)
    let added = store.searchResults("signal")
    #expect(added.albums.map(\.title) == ["Signal Album"])
    #expect(added.artists.map(\.name) == ["Signal Artist"])
    #expect(added.tracks.map(\.title) == ["Signal Song"])

    let enrichedRevision = store.contentRevision
    catalogue.albums[0].title = "Retagged Album"
    catalogue.albums[0].artist = "Retagged Artist"
    catalogue.albums[0].tracks[0].title = "Retagged Song"
    store.replace(with: catalogue, drive: nil)
    await store.derivationTask?.value
    #expect(store.contentRevision > enrichedRevision)
    #expect(store.searchResults("signal").isEmpty)
    #expect(store.searchResults("retagged").tracks.count == 1)

    let retaggedRevision = store.contentRevision
    catalogue.albums = []
    store.replace(with: catalogue, drive: nil)
    #expect(store.contentRevision > retaggedRevision)
    #expect(store.searchResults("retagged").isEmpty)
}

@Test @MainActor func clearingLibrarySupersedesPendingDerivedContent() async throws {
    let store = LibraryStore()
    var catalogue = Catalogue.build(
        folders: [ScannedFolder(path: "/music/Artist/Album", audio: [
            RemoteEntry(path: "/music/Artist/Album/01 Song.flac", name: "01 Song.flac",
                        isDirectory: false, size: 1024, modified: nil)
        ], cover: nil)],
        rootPath: "/music", serverName: "Search test", driveID: "", existing: nil
    )
    store.replace(with: catalogue, drive: nil)
    catalogue.albums[0].title = "Old server content"
    store.replace(with: catalogue, drive: nil)
    let pending = try #require(store.derivationTask)

    // The old derivation is queued while this synchronous clear publishes immediately.
    // Await its actual task rather than guessing how long derivation takes on the test machine.
    store.replace(with: .empty, drive: nil)
    let clearedRevision = store.contentRevision
    await pending.value

    #expect(store.catalogue.isEmpty)
    #expect(store.albums.isEmpty)
    #expect(store.searchResults("Old server content").isEmpty)
    #expect(store.contentRevision == clearedRevision)
}

@Test @MainActor func derivedRowsRetainTheirSourceUntilTheNewCataloguePublishes() async {
    let library = LibraryStore()
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = "first-source"
    library.replace(with: catalogue, drive: nil)
    let firstRevision = library.contentRevision
    #expect(library.contentSourceID == "first-source")
    let firstTracks = library.tracks

    // Identical relative paths and tags on two NAS sources still represent a source change.
    catalogue.driveID = "second-source"
    library.replace(with: catalogue, drive: nil)
    #expect(library.catalogue.driveID == "second-source")
    #expect(library.contentSourceID == "first-source")
    await library.derivationTask?.value
    #expect(library.contentSourceID == "second-source")
    #expect(library.contentRevision > firstRevision)
    #expect(library.tracks == firstTracks)

    library.replace(with: .empty, drive: nil)
    #expect(library.contentSourceID == "")
    #expect(library.tracks.isEmpty)
}
