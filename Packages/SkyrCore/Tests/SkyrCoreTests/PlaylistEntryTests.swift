import Foundation
import Testing
@testable import SkyrCore

@Test func playlistEntriesPreserveRepeatedSongsAndStableOccurrenceIdentity() {
    let a = SampleLibrary.catalogue.albums[0].tracks[0]
    let b = SampleLibrary.catalogue.albums[0].tracks[1]
    var playlist = Playlist(id: "test", name: "Repeated songs", summary: "", covers: [], tracks: [a, b, a])
    let before = playlist.entries
    #expect(before.map(\.track.id) == [a.id, b.id, a.id])
    #expect(before.map(\.position) == [0, 1, 2])
    #expect(Set(before.map(\.id)).count == 3)
    playlist.tracks.remove(at: 1)
    #expect(playlist.entries.map(\.id) == [before[0].id, before[2].id])
    #expect(playlist.entries.map(\.position) == [0, 1])
    let same = Playlist(id: playlist.id, name: playlist.name, summary: playlist.summary, covers: [], tracks: [a, a])
    #expect(playlist == same)
    #expect(Set([playlist, same]).count == 1)
}

@Test @MainActor func removingSelectedPlaylistOccurrencesPreservesUnavailableSongsAndOtherDuplicates() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-playlist-entries-\(UUID().uuidString)")
    let suite = "skyr.playlist.entries.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    let profiles = ProfileStore(directory: directory, defaults: defaults)
    #expect(profiles.activate(try #require(profiles.owner)))
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = "entries-source"
    let a = catalogue.albums[0].tracks[0]
    let b = catalogue.albums[0].tracks[1]
    profiles.updateLibrary(catalogue.driveID) {
        $0.playlists = [LocalPlaylist(id: "duplicates", name: "Duplicates", trackIDs: ["unavailable", a.id, b.id, a.id], created: .now)]
    }
    let library = LibraryStore()
    library.profiles = profiles
    library.replace(with: catalogue, drive: nil)
    #expect(library.tracks == catalogue.albums.flatMap(\.tracks))
    #expect(library.playlist(id: "duplicates")?.tracks.map(\.id) == [a.id, b.id, a.id])
    library.removeEntries(at: IndexSet([1, 2, 1000]), fromPlaylist: "duplicates")
    #expect(library.playlist(id: "duplicates")?.tracks.map(\.id) == [a.id])
    #expect(profiles.libraryState(for: catalogue.driveID).playlists[0].trackIDs == ["unavailable", a.id])
    #expect(profiles.libraryState(for: "other-source").playlists.isEmpty)
    // A selection that no longer exists is harmless, and the existing remove-all API keeps its behavior.
    library.removeEntries(at: IndexSet(integer: 20), fromPlaylist: "duplicates")
    #expect(profiles.libraryState(for: catalogue.driveID).playlists[0].trackIDs == ["unavailable", a.id])
    library.remove(a, fromPlaylist: "duplicates")
    #expect(profiles.libraryState(for: catalogue.driveID).playlists[0].trackIDs == ["unavailable"])
    profiles.lock()
    await profiles.drainPersistence()
    defaults.removePersistentDomain(forName: suite)
    try FileManager.default.removeItem(at: directory)
}
