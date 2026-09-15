import Foundation

/// A local intention, small for routine history/settings edits. Its original clock is replayed
/// verbatim; replay must never manufacture another play or give an old edit a newer revision.
nonisolated enum ProfileStateEdit: Codable, Sendable {
    struct LibraryPatch: Codable, Sendable {
        var favourites: [String]?
        var playlists: [LocalPlaylist]?
        var played: [String]?
        var recentAlbums: [String]?
        var searches: [String]?
        var downloadedAlbums: [String]?
        var downloadedPlaylists: [String]?

        init(from old: LibraryState, to new: LibraryState, recordingHistory: ProfileHistory?) {
            favourites = old.favourites == new.favourites ? nil : new.favourites
            playlists = old.playlists == new.playlists ? nil : new.playlists
            played = old.played == new.played && recordingHistory != .played ? nil : new.played
            recentAlbums = old.recentAlbums == new.recentAlbums && recordingHistory != .recentAlbums ? nil : new.recentAlbums
            searches = old.searches == new.searches && recordingHistory != .searches ? nil : new.searches
            downloadedAlbums = old.downloadedAlbums == new.downloadedAlbums ? nil : new.downloadedAlbums
            downloadedPlaylists = old.downloadedPlaylists == new.downloadedPlaylists ? nil : new.downloadedPlaylists
        }

        func apply(to library: inout LibraryState) {
            if let favourites { library.favourites = favourites }
            if let playlists { library.playlists = playlists }
            if let played { library.played = played }
            if let recentAlbums { library.recentAlbums = recentAlbums }
            if let searches { library.searches = searches }
            if let downloadedAlbums { library.downloadedAlbums = downloadedAlbums }
            if let downloadedPlaylists { library.downloadedPlaylists = downloadedPlaylists }
        }
    }

    case library(String, LibraryPatch, ProfileRevision, recordingHistory: String?)
    case settings(ProfileSettings, ProfileRevision)

    static func revision(after state: ProfileState, operation: String, now: Date = .now) -> ProfileRevision {
        .init(time: max(now.timeIntervalSince1970, (state.sync?.clock.time ?? state.updatedAt.timeIntervalSince1970).nextUp), operation: operation)
    }

    /// Keep the already materialized values in place. Rebuilding every unchanged playlist here
    /// would put the full-library sort back on the playback thread.
    func applying(to previous: ProfileState) -> ProfileState {
        let old = previous.sync == nil ? previous.normalizedForSync() : previous
        var result = old
        guard var metadata = old.sync else { return old }
        let revision: ProfileRevision
        let history: (String, ProfileHistory)?
        switch self {
        case .settings(let settings, let stamp):
            result.settings = settings
            revision = stamp
            history = nil
        case .library(let id, let patch, let stamp, let recorded):
            var library = result.libraries[id] ?? LibraryState()
            patch.apply(to: &library)
            result.libraries[id] = library
            revision = stamp
            history = recorded.flatMap(ProfileHistory.init(rawValue:)).map { (id, $0) }
        }
        metadata.update(from: old, to: result, revision: revision, recordingHistory: history)
        if case .library(let id, let patch, _, _) = self, let library = metadata.libraries[id] {
            // History merge may contain more than the display limit between actual local edits.
            if patch.played != nil { result.libraries[id]?.played = Array(library.played.values.prefix(100)) }
            if patch.recentAlbums != nil { result.libraries[id]?.recentAlbums = Array(library.recentAlbums.values.prefix(30)) }
            if patch.searches != nil { result.libraries[id]?.searches = Array(library.searches.values.prefix(8)) }
        }
        result.sync = metadata
        result.updatedAt = Date(timeIntervalSince1970: revision.time)
        return result
    }
}
