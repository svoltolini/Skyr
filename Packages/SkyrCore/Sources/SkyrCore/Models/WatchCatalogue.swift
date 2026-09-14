import Foundation
import SkyrShared

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
    /// Older phone catalogues have no trustworthy cache scope and must be synced again.
    public var driveID: String?
    public var profileID: String?

    public init(id: String, name: String, isSmart: Bool, coverColours: [WatchColourPair], tracks: [WatchTrack], totalSongs: Int, driveID: String? = nil, profileID: String? = nil) {
        self.id = id
        self.name = name
        self.isSmart = isSmart
        self.coverColours = coverColours
        self.tracks = tracks
        self.totalSongs = totalSongs
        self.driveID = driveID
        self.profileID = profileID
    }

    public var totalBytes: Int64 { tracks.reduce(0) { $0 + $1.fileSize } }
    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    public var isCut: Bool { totalSongs > tracks.count }

    public var cacheID: String? {
        guard let driveID, !driveID.isEmpty, let profileID, !profileID.isEmpty else { return nil }
        let owner = DownloadManager.cacheKey(trackID: id, driveID: profileID)
        return DownloadManager.cacheKey(trackID: owner, driveID: driveID)
    }
}

/// Structured task metadata keeps NAS paths as data; no path or delimiter becomes a local filename.
public nonisolated struct WatchDownloadJob: Codable, Equatable, Sendable {
    public let playlistKey: String
    public let trackID: String
    public let fileName: String
    public let generation: UUID
    public let expectedBytes: Int64?

    public init?(playlist: WatchPlaylist, track: WatchTrack, generation: UUID) {
        guard let key = playlist.cacheID, let driveID = playlist.driveID else { return nil }
        playlistKey = key
        trackID = track.id
        fileName = DownloadManager.cacheKey(trackID: track.id, driveID: driveID) + "." + DownloadManager.safeExtension(track.fileExtension)
        self.generation = generation
        expectedBytes = track.fileSize > 0 ? track.fileSize : nil
    }

    public var encoded: String? { (try? JSONEncoder().encode(self)).map { $0.base64EncodedString() } }

    public static func decode(_ value: String?) -> WatchDownloadJob? {
        guard let value, let data = Data(base64Encoded: value), let job = try? JSONDecoder().decode(Self.self, from: data),
              job.playlistKey.count == 64, job.playlistKey.allSatisfy({ $0.isHexDigit }),
              !job.fileName.isEmpty, (job.fileName as NSString).lastPathComponent == job.fileName else { return nil }
        return job
    }

    public func destination(in root: URL) -> URL {
        root.appending(path: playlistKey, directoryHint: .isDirectory)
            .appending(path: generation.uuidString, directoryHint: .isDirectory)
            .appending(path: fileName)
    }
}

/// File Station sends original audio bytes. A successful status alone does not prove a usable file.
public nonisolated enum WatchDownloadValidation {
    public enum Failure: Error, LocalizedError, Equatable, Sendable {
        case serverStatus(Int)
        case missingOrEmpty
        case sizeMismatch
        case serverMessage

        public var errorDescription: String? {
            switch self {
            case .serverStatus(let status): "The server answered \(status). Try downloading again."
            case .missingOrEmpty: "The song could not be saved. Try downloading again."
            case .sizeMismatch: "The song did not match its expected size. Refresh the playlist on your iPhone, then try again."
            case .serverMessage: "The server returned a message instead of audio. Reconnect to your NAS, then try again."
            }
        }
    }

    public static func failure(for url: URL, expectedBytes: Int64?, statusCode: Int = 200, contentType: String? = nil) -> Failure? {
        guard statusCode == 200 else { return .serverStatus(statusCode) }
        // URL resource values can retain a previous size after a retry replaces the same path.
        guard let values = try? FileManager.default.attributesOfItem(atPath: url.path),
              values[.type] as? FileAttributeType == .typeRegular,
              let bytes = (values[.size] as? NSNumber)?.int64Value, bytes > 0 else { return .missingOrEmpty }
        let type = contentType?.lowercased() ?? ""
        if type.hasPrefix("text/") || type.contains("json") || type.contains("xml") { return .serverMessage }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return .missingOrEmpty }
        defer { try? handle.close() }
        guard let head = try? handle.read(upToCount: 512), !head.isEmpty else { return .missingOrEmpty }
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}")))
        if text.hasPrefix("{") || text.hasPrefix("[") || text.hasPrefix("<") { return .serverMessage }
        if let expectedBytes, expectedBytes > 0, bytes != expectedBytes { return .sizeMismatch }
        return nil
    }
}

/// Desired songs are persisted separately from available files, so a partial transfer stays partial.
public nonisolated struct WatchDownloadManifest: Codable, Sendable {
    public var files: [String: String] = [:]
    public var desired: Set<String> = []
    public var generation: UUID?

    public init() {}

    /// Includes partial or invalid saved files so the user can always remove their storage.
    public var hasStoredFiles: Bool { !files.isEmpty }

    public func availableFiles(for playlist: WatchPlaylist, root: URL) -> [(track: WatchTrack, url: URL)] {
        guard let key = playlist.cacheID else { return [] }
        return playlist.tracks.compactMap { track in
            guard let path = files[track.id] else { return nil }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil,
                  !parts[1].isEmpty, parts[1] != ".", parts[1] != ".." else { return nil }
            let url = root.appending(path: key).appending(path: path)
            guard WatchDownloadValidation.failure(for: url, expectedBytes: track.fileSize) == nil else { return nil }
            return (track, url)
        }
    }
}

/// Everything the watch shows: the playlists of the phone's active profile, each cut to the limit.
public nonisolated struct WatchCatalogue: Codable, Sendable {
    /// The most songs one playlist brings to the watch, for the watch's sake.
    public static let songLimit = 200

    public var serverName: String
    public var profileName: String?
    public var playlists: [WatchPlaylist]
    public var generatedAt: Date
    public private(set) var artworkPolicyVersion: Int

    public init(serverName: String, profileName: String?, playlists: [WatchPlaylist], generatedAt: Date = .now) {
        self.serverName = serverName
        self.profileName = profileName
        self.playlists = playlists
        self.generatedAt = generatedAt
        artworkPolicyVersion = ArtworkPolicy.version
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        serverName = try values.decode(String.self, forKey: .serverName)
        profileName = try values.decodeIfPresent(String.self, forKey: .profileName)
        playlists = try values.decode([WatchPlaylist].self, forKey: .playlists)
        generatedAt = try values.decode(Date.self, forKey: .generatedAt)
        let storedPolicy = try? values.decode(Int.self, forKey: .artworkPolicyVersion)
        if storedPolicy != ArtworkPolicy.version {
            // Apply this to every decode, including queued messages from an older phone.
            // Playlist/track identities and download ownership remain unchanged.
            for index in playlists.indices {
                let id = playlists[index].id
                playlists[index].coverColours = playlists[index].coverColours.indices.map { offset in
                    let colours = ArtPalette.pair(for: "watch-\(id)-\(offset)")
                    return WatchColourPair(a: colours.0, b: colours.1)
                }
            }
        }
        artworkPolicyVersion = ArtworkPolicy.version
    }

    /// The same catalogue with the timestamp removed, so two builds of the same content compare equal.
    public var contentKey: Data? {
        var copy = self
        copy.generatedAt = .distantPast
        return try? JSONEncoder().encode(copy)
    }

    /// Navigation values are snapshots; resolve them against this catalogue before taking action.
    public func playlist(matching snapshot: WatchPlaylist) -> WatchPlaylist? {
        playlists.first {
            $0.id == snapshot.id && $0.cacheID == snapshot.cacheID
                && $0.driveID == snapshot.driveID && $0.profileID == snapshot.profileID
        }
    }
}

/// What the watch needs to reach the server by itself.
public nonisolated struct WatchCredentials: Codable, Hashable, Sendable {
    public var baseURL: URL
    public var account: String
    public var password: String
    public var driveID: String?

    public init(baseURL: URL, account: String, password: String, driveID: String? = nil) {
        self.baseURL = baseURL
        self.account = account
        self.password = password
        self.driveID = driveID
    }

    public func matches(_ playlist: WatchPlaylist) -> Bool {
        guard let driveID, !driveID.isEmpty else { return false }
        return driveID == playlist.driveID
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
                tracks: tracks, totalSongs: playlist.tracks.count,
                driveID: catalogue.driveID, profileID: profiles?.active?.id ?? profiles?.lastActiveID
            )
        }
        return WatchCatalogue(serverName: serverName, profileName: profileName, playlists: converted)
    }
}
