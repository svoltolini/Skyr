import SwiftUI

// MARK: - Catalogue types

/// Playback quality tier shown as signal-style bars: one for standard lossy files,
/// two for high bitrate lossy files, three for lossless and hi-res lossless.
public nonisolated enum AudioQuality: Int, Comparable, Codable, Sendable {
    case standard = 1
    case high = 2
    case lossless = 3

    public static func < (lhs: AudioQuality, rhs: AudioQuality) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .standard: "Standard quality"
        case .high: "High quality"
        case .lossless: "Lossless"
        }
    }

    /// Lossy files at or above this bitrate count as high quality (AAC 256, MP3 320, MP3 V0).
    public nonisolated static let highBitrate = 224_000
}

public nonisolated struct Track: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var albumID: String
    public var title: String
    /// Zero-based position inside the album.
    public var index: Int
    public var number: Int
    public var disc: Int
    public var duration: TimeInterval
    /// Lowercase codec name such as "flac" or "mp3".
    public var codec: String
    public var sampleRate: Int?
    public var bitDepth: Int?
    public var bitrate: Int?
    public var fileSize: Int64?
    public let path: String?
    /// Short badge such as "FLAC 24/96" or "MP3 320".
    public var format: String
    /// Track artist when the tags name one that differs from the album artist.
    public var artist: String?
    /// Album-level tags carried by this file, used to refine the folder-based guess.
    public var albumTitleTag: String?
    public var albumArtistTag: String?
    public var yearTag: Int?
    public var genreTag: String?
    /// True once the file's own headers and tags have been read.
    public var isEnriched: Bool
    /// Modification time reported by the source listing, in Unix seconds. Keep it numeric so
    /// catalogue date encoding cannot discard fractional precision and cause repeated rereads.
    public var sourceModifiedAt: TimeInterval? = nil
    /// Which version of the tag reader produced the tags; older tracks are read again on the next scan.
    public var tagVersion: Int? = nil
    /// How many times reading this song's tags failed, and when it was last tried; after three failures
    /// the song is left alone for a week instead of being read again on every refresh.
    public var enrichAttempts: Int? = nil
    public var enrichAttemptedAt: Date? = nil

    /// Bump when tag reading improves so already indexed tracks pick up the change.
    public nonisolated static let currentTagVersion = 2

    public var fileName: String {
        if let path, let last = path.split(separator: "/").last { return String(last) }
        return String(format: "%02d %@.%@", number, title, fileExtension)
    }

    public var fileExtension: String {
        if let path, let dot = path.lastIndex(of: "."), dot > path.lastIndex(of: "/") ?? path.startIndex {
            return String(path[path.index(after: dot)...]).lowercased()
        }
        return codec
    }

    public var isLossless: Bool { Self.losslessCodecs.contains(codec) }

    public var quality: AudioQuality {
        if isLossless { return .lossless }
        if let bitrate, bitrate >= AudioQuality.highBitrate { return .high }
        return .standard
    }

    /// Lossless above CD resolution: DSD, more than 16 bits or more than 48 kHz.
    public var isHiRes: Bool {
        guard isLossless else { return false }
        if codec == "dsd" { return true }
        if let bitDepth, bitDepth > 16 { return true }
        if let sampleRate, sampleRate > 48_000 { return true }
        return false
    }

    public var qualityLabel: String { isHiRes ? "Hi-Res Lossless" : quality.label }

    public var sizeText: String { ByteText.format(fileSize) }

    public nonisolated static let losslessCodecs: Set<String> = ["flac", "alac", "wav", "aiff", "aif", "ape", "wavpack", "wv", "dsd", "dsf", "dff", "pcm"]

    /// Moves a "(Disc 2)" style marker out of the album tag into the disc number.
    public mutating func normalizeDiscFromAlbumTag() {
        guard let tag = albumTitleTag.nonEmpty else { return }
        let split = PathParser.splitDisc(tag)
        guard let taggedDisc = split.disc else { return }
        albumTitleTag = split.title
        if disc <= 1 { disc = taggedDisc }
    }
}

public nonisolated struct Album: Identifiable, Hashable, Codable, Sendable {
    public let id: String
    public var title: String
    public var artist: String
    public var year: Int
    public var genre: String
    public var label: String?
    public var tracks: [Track]
    /// Album colours: read from the cover once there is one, otherwise a placeholder pair chosen by the id.
    public var colorA: String
    public var colorB: String
    /// Rough recency rank; higher means added more recently.
    public var addedRank: Int
    /// Directory on the drive that holds the album, when it came from a drive.
    public var folderPath: String?
    /// Image file on the drive that serves as the cover, when one was found.
    public var coverPath: String?
    /// What the folder names suggested before tags were read.
    public var folderTitle: String
    public var folderArtist: String
    public var folderYear: Int?

    public var primaryColor: Color { Color(hex: colorA) }
    public var secondaryColor: Color { Color(hex: colorB) }

    public var quality: AudioQuality { tracks.map(\.quality).max() ?? .standard }
    public var isHiRes: Bool { tracks.contains(where: \.isHiRes) }
    public var qualityLabel: String { isHiRes ? "Hi-Res Lossless" : quality.label }
    public var format: String { Self.mostCommon(tracks.map(\.format)) ?? "Unknown" }
    public var totalBytes: Int64 { tracks.reduce(0) { $0 + ($1.fileSize ?? 0) } }
    public var sizeInGB: Double { Double(totalBytes) / 1_000_000_000 }
    public var sizeText: String { ByteText.format(totalBytes) }
    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
    public var isEnriched: Bool { tracks.allSatisfy(\.isEnriched) }

    /// Directory that holds the album's files, e.g. "Halden Vey / 2023 - Nocturne Drift".
    public var folderName: String {
        if let folderPath {
            return folderPath.split(separator: "/").suffix(2).joined(separator: " / ")
        }
        if let path = tracks.first?.path {
            let parts = path.split(separator: "/").dropLast()
            return parts.suffix(2).joined(separator: " / ")
        }
        return "\(artist) / \(year) - \(title)"
    }

    public var metaLine: String { year > 0 ? "\(String(year)) · \(genre)" : genre }

    /// Re-derives title, artist, year and genre from the tags read so far, falling back to the folder guess.
    public mutating func refreshFromTags() {
        let enriched = tracks.filter(\.isEnriched)
        title = Self.mostCommon(enriched.compactMap(\.albumTitleTag)) ?? folderTitle
        let taggedArtists = enriched.compactMap { $0.albumArtistTag ?? $0.artist }
        artist = Self.mostCommon(taggedArtists) ?? folderArtist
        year = Self.mostCommonInt(enriched.compactMap(\.yearTag)) ?? folderYear ?? 0
        genre = Self.mostCommon(enriched.compactMap(\.genreTag)) ?? "Unknown genre"
    }

    public nonisolated static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: Int] = [:]
        for value in values where !value.isEmpty { counts[value, default: 0] += 1 }
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    public nonisolated static func mostCommonInt(_ values: [Int]) -> Int? {
        var counts: [Int: Int] = [:]
        for value in values where value > 0 { counts[value, default: 0] += 1 }
        return counts.max { $0.value == $1.value ? $0.key < $1.key : $0.value < $1.value }?.key
    }

    public nonisolated static func makeID(title: String, artist: String) -> String {
        "\(artist.lowercased())\u{1F}\(title.lowercased())"
    }

    /// "#3 (Deluxe Version)" → "#3", "Song (Remix)" → "Song": drops every bracketed part, unless nothing would be left.
    public nonisolated static func strippingBrackets(_ title: String) -> String {
        let stripped = title
            .replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return stripped.isEmpty ? title : stripped
    }

    /// Tracks grouped by disc, in disc order; single disc albums have one entry.
    public var discs: [Disc] {
        var grouped: [Int: [Track]] = [:]
        for track in tracks { grouped[track.disc, default: []].append(track) }
        return grouped.keys.sorted().map { Disc(number: $0, tracks: grouped[$0] ?? []) }
    }

    public var hasMultipleDiscs: Bool { Set(tracks.map(\.disc)).count > 1 }

    /// Orders tracks by disc, then number, then file name, and renumbers their positions.
    public mutating func sortTracks() {
        tracks.sort { lhs, rhs in
            if lhs.disc != rhs.disc { return lhs.disc < rhs.disc }
            let l = lhs.number == 0 ? Int.max : lhs.number
            let r = rhs.number == 0 ? Int.max : rhs.number
            if l != r { return l < r }
            return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
        }
        for index in tracks.indices { tracks[index].index = index }
    }
}

/// One disc of an album.
public nonisolated struct Disc: Identifiable, Hashable, Sendable {
    public let number: Int
    public let tracks: [Track]
    public var id: Int { number }
    public var duration: TimeInterval { tracks.reduce(0) { $0 + $1.duration } }
}

public nonisolated struct Artist: Identifiable, Hashable, Sendable {
    public let name: String
    public let albums: [Album]
    public var id: String { name }

    public var primaryColor: Color { albums[0].primaryColor }
    public var secondaryColor: Color { albums[0].secondaryColor }

    public var summary: String {
        let count = albums.count
        let songs = albums.reduce(0) { $0 + $1.tracks.count }
        return "\(count) \(count == 1 ? "album" : "albums") · \(songs) \(songs == 1 ? "song" : "songs")"
    }

    public var topTracks: [Track] { Array(albums.flatMap(\.tracks).prefix(5)) }
}

public nonisolated struct Genre: Identifiable, Hashable, Sendable {
    public let name: String
    public let albums: [Album]
    public var id: String { name }
    public var countText: String { "\(albums.count) \(albums.count == 1 ? "album" : "albums")" }
    public var primaryColor: Color { albums[0].primaryColor }
    public var secondaryColor: Color { albums[0].secondaryColor }
}

public nonisolated struct Decade: Identifiable, Hashable, Sendable {
    public let label: String
    public let albums: [Album]
    public var id: String { label }
    public var countText: String { "\(albums.count) \(albums.count == 1 ? "album" : "albums")" }
    public var album: Album { albums[0] }
}

/// One directory of the music share, derived from track paths.
public nonisolated final class FolderNode: Identifiable, Hashable, Sendable {
    public let name: String
    public let path: String
    public let subfolders: [FolderNode]
    public let tracks: [Track]
    public let fileCount: Int
    public let totalBytes: Int64
    /// The album whose colours decorate the folder icon, when the folder belongs to one album.
    public let albumID: String?

    public init(name: String, path: String, subfolders: [FolderNode], tracks: [Track]) {
        self.name = name
        self.path = path
        self.subfolders = subfolders
        self.tracks = tracks
        fileCount = tracks.count + subfolders.reduce(0) { $0 + $1.fileCount }
        totalBytes = tracks.reduce(0) { $0 + ($1.fileSize ?? 0) } + subfolders.reduce(0) { $0 + $1.totalBytes }
        let ids = Set(tracks.map(\.albumID) + subfolders.compactMap(\.albumID))
        albumID = ids.count == 1 ? ids.first : nil
    }

    public var id: String { path }
    public var summary: String { "\(fileCount) \(fileCount == 1 ? "file" : "files") · \(ByteText.format(totalBytes))" }

    public static func == (lhs: FolderNode, rhs: FolderNode) -> Bool { lhs.path == rhs.path }
    public func hash(into hasher: inout Hasher) { hasher.combine(path) }
}

/// A song's occurrence in an ordered list. Repeated songs need separate row identities, while
/// removing a different song should preserve the identity of the remaining occurrences.
public nonisolated struct TrackListEntry: Identifiable, Hashable, Sendable {
    public struct ID: Hashable, Sendable {
        public let trackID: String
        public let occurrence: Int
    }

    public let id: ID
    public let track: Track
    public let position: Int

    public static func make(from tracks: [Track]) -> [TrackListEntry] {
        var occurrences: [String: Int] = [:]
        return tracks.enumerated().map { position, track in
            let occurrence = occurrences[track.id, default: 0]
            occurrences[track.id] = occurrence + 1
            return TrackListEntry(id: ID(trackID: track.id, occurrence: occurrence), track: track, position: position)
        }
    }
}

public nonisolated struct Playlist: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        case local, smart
    }

    public let id: String
    public var name: String
    public var summary: String
    /// Up to four albums whose artwork forms the mosaic cover.
    public var covers: [Album]
    public var tracks: [Track] {
        didSet { entries = TrackListEntry.make(from: tracks) }
    }
    /// Prepared when contents change, so row identity does not enumerate the whole playlist on
    /// every playback, progress or selection update.
    public private(set) var entries: [TrackListEntry]
    public var kind: Kind = .local

    public init(id: String, name: String, summary: String, covers: [Album], tracks: [Track], kind: Kind = .local) {
        self.id = id
        self.name = name
        self.summary = summary
        self.covers = covers
        self.tracks = tracks
        self.entries = TrackListEntry.make(from: tracks)
        self.kind = kind
    }

    public static func == (lhs: Playlist, rhs: Playlist) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name && lhs.summary == rhs.summary &&
            lhs.covers == rhs.covers && lhs.tracks == rhs.tracks && lhs.kind == rhs.kind
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
        hasher.combine(name)
        hasher.combine(summary)
        hasher.combine(covers)
        hasher.combine(tracks)
        hasher.combine(kind)
    }

    public nonisolated static let favouritesID = "smart.favourites"
    public nonisolated static let favouritesMixID = "smart.favourites-mix"
    public nonisolated static let recentlyPlayedID = "smart.recently-played"
    public nonisolated static let libraryShuffleID = "smart.library-shuffle"
}

/// Persisted form of a playlist the user made in the app.
public nonisolated struct LocalPlaylist: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var trackIDs: [String]
    public var created: Date
}

public nonisolated struct BrowseEntry: Identifiable, Hashable, Sendable {
    public let label: String
    public let detail: String
    public let facet: LibraryFacet
    public var id: String { label }
}

/// A saved server connection.
public nonisolated struct ServerConnection: Codable, Hashable, Sendable {
    public var name: String
    public var baseURL: URL
    public var account: String
    /// Path of the folder to index on the drive.
    public var musicPath: String?

    public var host: String { baseURL.host() ?? baseURL.absoluteString }

    /// A private IP, Bonjour name, or Tailscale address: fine at home or via Tailscale,
    /// but not a public server that requires router port forwarding.
    public var isHomeOnly: Bool { Self.isHomeAddress(host) }

    public static func isHomeAddress(_ host: String) -> Bool {
        let name = host.lowercased()
        let isShortHostname = !name.contains(".") && !(name.hasPrefix("ts") && name.hasSuffix("net"))
        if name.hasSuffix(".local") || name.hasSuffix(".ts.net") || name == "localhost" || isShortHostname { return true }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 10 || (parts[0] == 192 && parts[1] == 168) || (parts[0] == 172 && (16...31).contains(parts[1]))
            || (parts[0] == 169 && parts[1] == 254) || (parts[0] == 100 && (64...127).contains(parts[1]))
    }
    public var address: String {
        let port = baseURL.port.map { ":\($0)" } ?? ""
        return host + port
    }
    public var sourceID: String { NASSource.identifier(baseURL: baseURL, account: account) }
    /// Hostname-only keys cannot distinguish two ports or accounts on the same server.
    public var keychainAccount: String { sourceID }
    /// The key older builds used; the address changes between routes, so it is only read for migration.
    public var legacyKeychainAccount: String { "\(baseURL.absoluteString)|\(account)" }
}

// MARK: - App level enums

public nonisolated enum LibraryFacet: String, CaseIterable, Identifiable, Sendable {
    case recentlyAdded = "Recently added"
    case artists = "Artists"
    case genres = "Genres"
    public var id: String { rawValue }
}

public nonisolated enum StreamQuality: String, CaseIterable, Identifiable, Sendable {
    case original = "Original"
    case lossless = "Lossless"
    case compact = "Compact"
    public var id: String { rawValue }
}

public nonisolated enum Appearance: String, CaseIterable, Identifiable, Sendable {
    case light = "Light"
    case dark = "Dark"
    case auto = "Auto"
    public var id: String { rawValue }

    /// Settings copy. Automatic follows the system appearance.
    public var title: String { self == .auto ? "Automatic" : rawValue }

    public var colorScheme: ColorScheme? {
        switch self {
        case .light: .light
        case .dark: .dark
        case .auto: nil
        }
    }
}

public nonisolated enum AppTab: Hashable, Sendable {
    case library, playlists, downloads, settings, search
}

// MARK: - Formatting helpers

public nonisolated enum TimeText {
    /// "5:31" style clock text.
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds).rounded(.down))
        return "\(total / 60):" + String(format: "%02d", total % 60)
    }

    /// "6 h 12 min" style duration.
    public static func long(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) h \(String(format: "%02d", minutes % 60)) min" : "\(minutes) min"
    }
}

public nonisolated enum ByteText {
    public static func format(_ bytes: Int64?) -> String {
        guard let bytes, bytes > 0 else { return "—" }
        let gb = Double(bytes) / 1_000_000_000
        if gb >= 1 { return String(format: gb >= 10 ? "%.0f GB" : "%.1f GB", gb) }
        let mb = Double(bytes) / 1_000_000
        if mb >= 1 { return String(format: "%.0f MB", mb) }
        return String(format: "%.0f KB", Double(bytes) / 1000)
    }

    public static func gigabytes(_ bytes: Int64) -> Double { Double(bytes) / 1_000_000_000 }
}

/// Curated gradient pairs used as placeholder artwork.
public nonisolated enum ArtPalette {
    public static let pairs: [(String, String)] = [
        ("#7c5cff", "#2a1a80"), ("#4a5568", "#141821"), ("#38bdf8", "#0c4a6e"), ("#f472b6", "#4c0519"),
        ("#1e40af", "#0f172a"), ("#fb923c", "#7c2d12"), ("#c86a3e", "#5a2d1e"), ("#a3a3a3", "#262626"),
        ("#84cc16", "#1a2e05"), ("#eab308", "#1c1917"), ("#2dd4bf", "#134e4a"), ("#e11d48", "#3b0a1a"),
    ]

    public static func pair(for key: String) -> (String, String) {
        var hash: UInt64 = 1469598103934665603
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 1099511628211
        }
        return pairs[Int(hash % UInt64(pairs.count))]
    }
}
