import Foundation
import SkyrShared
import Testing
@testable import SkyrCore

private nonisolated func oldArtworkJSON<T: Encodable>(_ value: T, version: Int?) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    if let version { object["artworkPolicyVersion"] = version }
    else { object.removeValue(forKey: "artworkPolicyVersion") }
    return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
}

@Suite struct ArtworkCatalogueMigrationTests {
    @Test(arguments: [nil, 0, 999] as [Int?]) func legacyCatalogueKeepsMusicAndReplacesOnlyUnknownColours(version: Int?) throws {
        var source = SampleLibrary.catalogue
        source.driveID = "fixture-nas"
        source.albums = Array(source.albums.prefix(2))
        for index in source.albums.indices {
            source.albums[index].colorA = "#010203"
            source.albums[index].colorB = "#040506"
        }
        let decoded = try JSONDecoder().decode(Catalogue.self, from: oldArtworkJSON(source, version: version))
        #expect(decoded.artworkPolicyVersion == ArtworkPolicy.version)
        #expect(decoded.serverName == source.serverName)
        #expect(decoded.rootPath == source.rootPath)
        #expect(decoded.driveID == source.driveID)
        #expect(decoded.indexedAt == source.indexedAt)
        #expect(decoded.albums.count == source.albums.count)
        for (old, current) in zip(source.albums, decoded.albums) {
            var expected = old
            let colours = ArtPalette.pair(for: old.id)
            expected.colorA = colours.0
            expected.colorB = colours.1
            #expect(current == expected)
        }
        let persisted = try JSONEncoder().encode(decoded)
        let reopened = try JSONDecoder().decode(Catalogue.self, from: persisted)
        #expect(reopened.albums == decoded.albums)
    }

    @Test func currentCataloguePreservesSourceColoursOnRoundtrip() throws {
        var source = SampleLibrary.catalogue
        source.albums[0].colorA = "#010203"
        source.albums[0].colorB = "#040506"
        let decoded = try JSONDecoder().decode(Catalogue.self, from: JSONEncoder().encode(source))
        #expect(decoded.albums == source.albums)
        #expect(decoded.artworkPolicyVersion == ArtworkPolicy.version)
    }

    @Test(arguments: [nil, 0, 999] as [Int?]) func legacyWatchPayloadKeepsPlaylistAndDownloadIdentity(version: Int?) throws {
        let track = WatchTrack(id: "song", title: "Song", artist: "Artist", album: "Album", duration: 180,
                               path: "/music/song.flac", fileSize: 4096, format: "FLAC", isLossless: true)
        let playlist = WatchPlaylist(id: "playlist", name: "Offline favourites", isSmart: false,
                                     coverColours: [WatchColourPair(a: "#010203", b: "#040506")], tracks: [track],
                                     totalSongs: 1, driveID: "fixture-nas", profileID: "fixture-profile")
        let catalogue = WatchCatalogue(serverName: "Fixture NAS", profileName: "Me", playlists: [playlist], generatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let legacyData = try oldArtworkJSON(catalogue, version: version)
        let decoded = try JSONDecoder().decode(WatchCatalogue.self, from: legacyData)
        let current = try #require(decoded.playlists.first)
        #expect(current.cacheID == playlist.cacheID)
        #expect(current.tracks == playlist.tracks)
        #expect(current.id == playlist.id)
        #expect(current.name == playlist.name)
        #expect(current.totalSongs == playlist.totalSongs)
        #expect(current.driveID == playlist.driveID)
        #expect(current.profileID == playlist.profileID)
        #expect(current.coverColours != playlist.coverColours)
        #expect(current.coverColours.count == playlist.coverColours.count)
        #expect(decoded.serverName == catalogue.serverName)
        #expect(decoded.profileName == catalogue.profileName)
        #expect(decoded.generatedAt == catalogue.generatedAt)
        #expect(decoded.artworkPolicyVersion == ArtworkPolicy.version)
        let secondOldMessage = try JSONDecoder().decode(WatchCatalogue.self, from: legacyData)
        #expect(secondOldMessage.playlists == decoded.playlists)
        let reopened = try JSONDecoder().decode(WatchCatalogue.self, from: JSONEncoder().encode(decoded))
        #expect(reopened.playlists == decoded.playlists)
    }

    @Test func currentWatchPayloadPreservesSourceColours() throws {
        let playlist = WatchPlaylist(id: "playlist", name: "Favourites", isSmart: true,
                                     coverColours: [WatchColourPair(a: "#010203", b: "#040506")], tracks: [], totalSongs: 0,
                                     driveID: "fixture-nas", profileID: "fixture-profile")
        let source = WatchCatalogue(serverName: "Fixture NAS", profileName: "Me", playlists: [playlist])
        let decoded = try JSONDecoder().decode(WatchCatalogue.self, from: JSONEncoder().encode(source))
        #expect(decoded.playlists == source.playlists)
        #expect(decoded.artworkPolicyVersion == ArtworkPolicy.version)
    }
}
