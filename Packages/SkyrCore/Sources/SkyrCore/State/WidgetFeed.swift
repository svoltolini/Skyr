import CryptoKit
import Foundation
import Observation
import SkyrShared
#if canImport(WidgetKit)
import WidgetKit
#endif

/// Keeps the Home Screen widgets fed: watches the models, builds a snapshot of what is playing and
/// what is recent, kept and listed, copies the covers it needs into the shared container, and asks
/// WidgetKit to redraw. It watches the models directly rather than a screen, so a play started from
/// a widget while the app sits in the background updates the widgets too.
public final class WidgetFeed {
    /// Everything the widgets depend on. Reading it inside observation tracking registers the properties.
    public struct Signature: Equatable {
        public let nowPlayingID: String?
        public let trackTitle: String?
        public let isPlaying: Bool
        public let recentlyPlayed: [String]
        public let recentlyAdded: [String]
        public let coverKeys: [String?]
        public let albumCount: Int
        public let downloadOwners: [String]
        public let downloadedSongs: Int
        public let playlists: [String]

        public init(library: LibraryStore, player: PlayerModel, downloads: DownloadManager) {
            nowPlayingID = player.album?.id
            trackTitle = player.track?.title
            isPlaying = player.isPlaying
            let played = Array(library.recentlyPlayed.prefix(8))
            let added = Array(library.recentlyAdded.prefix(8))
            recentlyPlayed = played.map(\.id)
            recentlyAdded = added.map(\.id)
            coverKeys = ([player.album].compactMap { $0 } + played + added).map { WidgetFeed.coverKey(for: $0, in: library) }
            albumCount = library.albums.count
            downloadOwners = downloads.listedOwnerIDs.sorted() + [downloads.activeProfileID]
            downloadedSongs = downloads.records.count
            playlists = ([library.favouritesPlaylist, library.favouritesMixPlaylist, library.recentlyPlayedPlaylist] + library.playlists).map { $0.id + $0.summary }
        }
    }

    private var library: LibraryStore?
    private var player: PlayerModel?
    private var downloads: DownloadManager?
    private var pending: Task<Void, Never>?

    public init() {}

    public func start(library: LibraryStore, player: PlayerModel, downloads: DownloadManager) {
        self.library = library
        self.player = player
        self.downloads = downloads
        observe()
        refresh()
    }

    private func observe() {
        guard let library, let player, let downloads else { return }
        withObservationTracking {
            _ = Signature(library: library, player: player, downloads: downloads)
        } onChange: { [weak self] in
            // Fires before the change lands; the hop lets it finish before anything is read.
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                self.observe()
            }
        }
    }

    /// Writes a fresh snapshot shortly after being called; repeated calls within the delay coalesce.
    public func refresh() {
        guard let library, let player, let downloads else { return }
        var sources: [String: URL] = [:]
        var heroKeys: Set<String> = []
        func describe(_ album: Album) -> WidgetSnapshot.Album {
            let key = Self.coverKey(for: album, in: library)
            if let key, let url = library.coverURL(for: album) { sources[key] = url }
            return WidgetSnapshot.Album(
                id: album.id, title: album.title, artist: album.artist, colorA: album.colorA, colorB: album.colorB,
                year: album.year > 0 ? album.year : nil, genre: album.genre == "Unknown genre" ? nil : album.genre, coverKey: key
            )
        }
        func describe(_ playlist: Playlist) -> WidgetSnapshot.PlaylistInfo {
            let kind: WidgetSnapshot.PlaylistInfo.Kind = switch playlist.id {
            case Playlist.favouritesID: .favourites
            case Playlist.favouritesMixID: .mix
            case Playlist.recentlyPlayedID: .recentlyPlayed
            case Playlist.libraryShuffleID: .shuffle
            default: .local
            }
            return WidgetSnapshot.PlaylistInfo(id: playlist.id, name: playlist.name, summary: playlist.summary, kind: kind, covers: playlist.covers.prefix(4).map(describe))
        }

        let lead = player.album
        let played = Array(library.recentlyPlayed.prefix(8))
        let added = Array(library.recentlyAdded.prefix(8))
        let listed = downloads.listedOwnerIDs
        let kept = Array(library.recentlyAdded.filter { listed.contains(downloads.owner(for: $0).id) }.prefix(12))
        let playlists = [library.favouritesPlaylist, library.favouritesMixPlaylist, library.recentlyPlayedPlaylist, library.libraryShufflePlaylist] + library.playlists.prefix(8)
        // Albums not played lately, in an order that stays put for the day and changes overnight.
        let day = Date.now.formatted(.iso8601.year().month().day())
        let recent = Set(played.map(\.id) + [lead?.id].compactMap { $0 })
        let rediscover = library.albums
            .filter { !recent.contains($0.id) }
            .sorted { Self.stableHash($0.id + day) < Self.stableHash($1.id + day) }
            .prefix(24)
            .map(describe)

        let snapshot = WidgetSnapshot(
            nowPlaying: lead.map(describe),
            trackTitle: player.track?.title,
            isPlaying: player.isPlaying,
            recentlyPlayed: played.map(describe),
            recentlyAdded: added.map(describe),
            downloads: kept.map(describe),
            downloadedSongCount: downloads.records.count,
            playlists: playlists.map(describe),
            rediscover: Array(rediscover),
            updated: .now
        )
        // Lead albums get the big copy: the small widgets fill their whole face with them.
        for album in ([lead, played.first, added.first, kept.first].compactMap { $0 }) + Array(library.albums.filter { candidate in rediscover.contains { $0.id == candidate.id } }) {
            if let key = Self.coverKey(for: album, in: library) { heroKeys.insert(key) }
        }
        let coverSources = sources
        let heroes = heroKeys
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await Task.detached(priority: .utility) {
                WidgetStore.write(snapshot, coverSources: coverSources, heroKeys: heroes)
            }.value
            #if canImport(WidgetKit)
            WidgetCenter.shared.reloadAllTimelines()
            #endif
        }
    }

    /// File stem for an album's cover copies, changing when the cover itself is replaced.
    public static func coverKey(for album: Album, in library: LibraryStore) -> String? {
        guard library.coverURL(for: album) != nil else { return nil }
        let digest = SHA256.hash(data: Data(album.id.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return "\(digest)-v\(library.coverVersion(for: album))"
    }

    /// FNV-1a: the same order for the same day on every launch, unlike `hashValue`.
    nonisolated private static func stableHash(_ text: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
