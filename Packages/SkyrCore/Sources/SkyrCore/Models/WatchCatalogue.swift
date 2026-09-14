import Foundation

/// A song as the watch knows it: enough to list it, size it and fetch it from the server.
public nonisolated struct WatchTrack: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var title: String
    public var artist: String
    public var album: String
    public var duration: TimeInterval
    /// Path on the drive, the same one File Station streams from.
    public var path: String
    public var fileSize: Int64
    public var format: String
    public var isLossless: Bool

    public init(id: String, title: String, artist: String, album: String, duration: TimeInterval, path: String, fileSize: Int64, format: String, isLossless: Bool) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.duration = duration
        self.path = path
        self.fileSize = fileSize
        self.format = format
        self.isLossless = isLossless
    }

    public var fileExtension: String {
        let ext = (path as NSString).pathExtension.lowercased()
        return ext.isEmpty ? "audio" : ext
    }
}

/// Two hex colours; four of these make a playlist's mosaic on the watch.
public nonisolated struct WatchColourPair: Codable, Hashable, Sendable {
    public var a: String
    public var b: String

    public init(a: String, b: String) {
        self.a = a
        self.b = b
    }
}

/// A playlist cut to the watch's song limit.
public nonisolated struct WatchPlaylist: Codable, Hashable, Sendable, Identifiable {
    public let id: String
    public var name: String
    public var isSmart: Bool
    public var coverColours: [WatchColourPair]
    public var tracks: [WatchTrack]
    /// How many songs the playlist has on the phone; the watch carries at most the limit.
    public var totalSongs: Int

    public init(id: String, name: String, isSmart: Bool, coverColours: [WatchColourPair], tracks: [WatchTrack], totalSongs: Int) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.coverColours = coverColours
        self.tracks = tracks
        self.totalSongs = totalSongs
    }

    public var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    public var isCut: Bool { totalSongs > tracks.count }
}

/// Everything the watch shows: the playlists of the phone's active profile, each cut to the limit.
public nonisolated struct WatchCatalogue: Codable, Sendable {
    /// The most songs one playlist brings to the watch, for the watch's sake.
    public static let songLimit = 200

    public var serverName: String
    public var profileName: String?
    public var playlists: [WatchPlaylist]
    public var generatedAt: Date

    public init(serverName: String, profileName: String?, playlists: [WatchPlaylist], generatedAt: Date = .now) {
        self.serverName = serverName
        self.profileName = profileName
        self.playlists = playlists
        self.generatedAt = generatedAt
    }

    /// The same catalogue with the timestamp removed, so two builds of the same content compare equal.
    public var contentKey: Data? {
        var copy = self
        copy.generatedAt = .distantPast
        return try? JSONEncoder().encode(copy)
    }
}

/// What the watch needs to reach the server by itself.
public nonisolated struct WatchCredentials: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var account: String
    public var password: String

    public init(baseURL: URL, account: String, password: String) {
        self.baseURL = baseURL
        self.account = account
        self.password = password
    }
}

extension LibraryStore {
    /// Every playlist with songs, smart ones first, each cut to the watch's limit. Songs the
    /// server cannot serve (no path) are left out, and so is the library shuffle, which changes
    /// on every reading and would keep the watch downloading.
    public func watchCatalogue(serverName: String, profileName: String?) -> WatchCatalogue {
        let all = [favouritesPlaylist, favouritesMixPlaylist, recentlyPlayedPlaylist] + playlists
        let converted: [WatchPlaylist] = all.compactMap { playlist in
            let tracks: [WatchTrack] = playlist.tracks.prefix(WatchCatalogue.songLimit).compactMap { track in
                guard let path = track.path else { return nil }
                let album = album(id: track.albumID)
                return WatchTrack(
                    id: track.id, title: track.title, artist: track.artist ?? album?.artist ?? "",
                    album: album?.title ?? "", duration: track.duration, path: path,
                    fileSize: track.fileSize ?? 0, format: track.format, isLossless: track.isLossless
                )
            }
            guard !tracks.isEmpty else { return nil }
            return WatchPlaylist(
                id: playlist.id, name: playlist.name, isSmart: playlist.kind == .smart,
                coverColours: playlist.covers.prefix(4).map { WatchColourPair(a: $0.colorA, b: $0.colorB) },
                tracks: tracks, totalSongs: playlist.tracks.count
            )
        }
        return WatchCatalogue(serverName: serverName, profileName: profileName, playlists: converted)
    }
}
