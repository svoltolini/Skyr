import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// What the Home Screen widgets show. The app writes it into the shared container whenever playback
/// or the library changes; the widget extension only reads it.
public nonisolated struct WidgetSnapshot: Codable, Sendable {
    public nonisolated struct Album: Codable, Sendable, Identifiable, Hashable {
        public var id: String
        public var title: String
        public var artist: String
        public var colorA: String
        public var colorB: String
        public var year: Int?
        public var genre: String?
        /// Name stem of the resized cover copies in the shared container, when the album has a cover.
        public var coverKey: String?

        public init(id: String, title: String, artist: String, colorA: String, colorB: String, year: Int? = nil, genre: String? = nil, coverKey: String? = nil) {
            self.id = id
            self.title = title
            self.artist = artist
            self.colorA = colorA
            self.colorB = colorB
            self.year = year
            self.genre = genre
            self.coverKey = coverKey
        }

        /// "2019 · Jazz", or whichever of the two is known.
        public var metaLine: String {
            [year.map { String($0) }, genre].compactMap { $0 }.joined(separator: " · ")
        }
    }

    public nonisolated struct PlaylistInfo: Codable, Sendable, Identifiable, Hashable {
        public nonisolated enum Kind: String, Codable, Sendable {
            case favourites, mix, recentlyPlayed, shuffle, local
        }

        public var id: String
        public var name: String
        public var summary: String
        public var kind: Kind
        /// Up to four albums whose covers form the mosaic of a playlist you made.
        public var covers: [Album]

        public init(id: String, name: String, summary: String, kind: Kind, covers: [Album]) {
            self.id = id
            self.name = name
            self.summary = summary
            self.kind = kind
            self.covers = covers
        }
    }

    /// The album of the song playing or paused right now.
    public var nowPlaying: Album?
    public var trackTitle: String?
    public var isPlaying: Bool
    /// Most recent first, up to eight each.
    public var recentlyPlayed: [Album]
    public var recentlyAdded: [Album]
    /// Albums kept on this iPhone, newest first, up to twelve.
    public var downloads: [Album]
    public var downloadedSongCount: Int
    /// The app's own lists first, then the ones you made.
    public var playlists: [PlaylistInfo]
    /// Albums not played lately in an order that changes daily; the Rediscover widget walks through them.
    public var rediscover: [Album]
    public var updated: Date

    public init(
        nowPlaying: Album? = nil, trackTitle: String? = nil, isPlaying: Bool = false,
        recentlyPlayed: [Album] = [], recentlyAdded: [Album] = [], downloads: [Album] = [], downloadedSongCount: Int = 0,
        playlists: [PlaylistInfo] = [], rediscover: [Album] = [], updated: Date = .distantPast
    ) {
        self.nowPlaying = nowPlaying
        self.trackTitle = trackTitle
        self.isPlaying = isPlaying
        self.recentlyPlayed = recentlyPlayed
        self.recentlyAdded = recentlyAdded
        self.downloads = downloads
        self.downloadedSongCount = downloadedSongCount
        self.playlists = playlists
        self.rediscover = rediscover
        self.updated = updated
    }

    /// Anything a newer app has not written yet reads as empty, so the widgets never go blank after an update.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        nowPlaying = try container.decodeIfPresent(Album.self, forKey: .nowPlaying)
        trackTitle = try container.decodeIfPresent(String.self, forKey: .trackTitle)
        isPlaying = try container.decodeIfPresent(Bool.self, forKey: .isPlaying) ?? false
        recentlyPlayed = try container.decodeIfPresent([Album].self, forKey: .recentlyPlayed) ?? []
        recentlyAdded = try container.decodeIfPresent([Album].self, forKey: .recentlyAdded) ?? []
        downloads = try container.decodeIfPresent([Album].self, forKey: .downloads) ?? []
        downloadedSongCount = try container.decodeIfPresent(Int.self, forKey: .downloadedSongCount) ?? 0
        playlists = try container.decodeIfPresent([PlaylistInfo].self, forKey: .playlists) ?? []
        rediscover = try container.decodeIfPresent([Album].self, forKey: .rediscover) ?? []
        updated = try container.decodeIfPresent(Date.self, forKey: .updated) ?? .distantPast
    }

    public static let empty = WidgetSnapshot()

    /// The album the widgets lead with, and why.
    public enum Lead: Sendable {
        case playing, paused, recentlyPlayed, recentlyAdded
    }

    public var featured: (album: Album, lead: Lead)? {
        if let nowPlaying { return (nowPlaying, isPlaying ? .playing : .paused) }
        if let played = recentlyPlayed.first { return (played, .recentlyPlayed) }
        if let added = recentlyAdded.first { return (added, .recentlyAdded) }
        return nil
    }

    /// Albums for the shelves: what was played before the featured one, then new albums to fill up.
    public func others(limit: Int) -> [Album] {
        let lead = featured?.album.id
        var picks: [Album] = []
        for album in recentlyPlayed + recentlyAdded where album.id != lead && !picks.contains(where: { $0.id == album.id }) {
            picks.append(album)
            if picks.count == limit { break }
        }
        return picks
    }

    /// Whether this album is the one playing right now.
    public func isPlaying(_ album: Album) -> Bool { isPlaying && nowPlaying?.id == album.id }

    /// Shown in the widget gallery and as the placeholder, so every widget looks like a library in use.
    public static let sample: WidgetSnapshot = {
        let albums = [
            Album(id: "s1", title: "Nocturne Drift", artist: "Halden Vey", colorA: "#6d5bd0", colorB: "#2a1d7a", year: 2021, genre: "Ambient", coverKey: nil),
            Album(id: "s2", title: "Blue Meridian", artist: "Josef Amari Trio", colorA: "#1f3a8a", colorB: "#0b1a4a", year: 1998, genre: "Jazz", coverKey: nil),
            Album(id: "s3", title: "Saltwater Radio", artist: "Mira Solano", colorA: "#2a9dd6", colorB: "#0b4f7a", year: 2016, genre: "Indie folk", coverKey: nil),
            Album(id: "s4", title: "Rust & Honey", artist: "Delta Cartwright", colorA: "#b8622e", colorB: "#5a2a12", year: 2011, genre: "Blues", coverKey: nil),
            Album(id: "s5", title: "Terra Firma", artist: "Coastline Ensemble", colorA: "#5c9e1c", colorB: "#1f4a0b", year: 2004, genre: "Classical", coverKey: nil),
            Album(id: "s6", title: "Kinetic Hours", artist: "Orbital Twins", colorA: "#c93a7a", colorB: "#5a1237", year: 2019, genre: "Electronic", coverKey: nil),
            Album(id: "s7", title: "Parallel Lives", artist: "Ana Kestrel", colorA: "#e07a2f", colorB: "#7a3a10", year: 2024, genre: "Pop", coverKey: nil),
            Album(id: "s8", title: "Northern Static", artist: "Vesper Field", colorA: "#8a8a8a", colorB: "#2c2c2c", year: 2013, genre: "Indie rock", coverKey: nil),
            Album(id: "s9", title: "Midnight Ledger", artist: "Cole & Marr", colorA: "#d4a017", colorB: "#5a4308", year: 2009, genre: "Hip-hop", coverKey: nil),
            Album(id: "s10", title: "Glasshouse", artist: "The Lowline", colorA: "#3d4a5c", colorB: "#161c26", year: 2015, genre: "Indie rock", coverKey: nil),
            Album(id: "s11", title: "Small Weather", artist: "June Halloran", colorA: "#c8324a", colorB: "#5a0f1e", year: 2020, genre: "Pop", coverKey: nil),
            Album(id: "s12", title: "Concrete Gardens", artist: "The Lowline", colorA: "#2c3644", colorB: "#0e1218", year: 2017, genre: "Indie rock", coverKey: nil),
        ]
        let playlists = [
            PlaylistInfo(id: "smart.favourites", name: "Favourites", summary: "84 songs", kind: .favourites, covers: []),
            PlaylistInfo(id: "smart.favourites-mix", name: "Favourites mix", summary: "132 songs", kind: .mix, covers: []),
            PlaylistInfo(id: "smart.recently-played", name: "Recently played", summary: "100 songs", kind: .recentlyPlayed, covers: []),
            PlaylistInfo(id: "smart.library-shuffle", name: "Library shuffle", summary: "50 songs", kind: .shuffle, covers: []),
            PlaylistInfo(id: "p1", name: "Late shift", summary: "84 songs", kind: .local, covers: [albums[0], albums[1], albums[7], albums[2]]),
            PlaylistInfo(id: "p2", name: "Sunday, slowly", summary: "41 songs", kind: .local, covers: [albums[2], albums[3], albums[10], albums[4]]),
            PlaylistInfo(id: "p3", name: "Hi-res showcase", summary: "27 songs", kind: .local, covers: [albums[4], albums[6], albums[5], albums[0]]),
            PlaylistInfo(id: "p4", name: "Vinyl rips", summary: "132 songs", kind: .local, covers: [albums[3], albums[9], albums[8], albums[1]]),
        ]
        return WidgetSnapshot(
            nowPlaying: albums[0], trackTitle: "Slow Pulse Meridian", isPlaying: true,
            recentlyPlayed: Array(albums[1...5]), recentlyAdded: Array(albums[5...8]),
            downloads: [albums[6], albums[1], albums[3], albums[0], albums[8], albums[2], albums[9], albums[10]], downloadedSongCount: 74,
            playlists: playlists,
            rediscover: [albums[9], albums[4], albums[10], albums[2], albums[8], albums[11], albums[3], albums[5]],
            updated: .now
        )
    }()
}

/// Where the snapshot and its covers live: the App Group container both targets can read.
public nonisolated enum WidgetStore {
    public static let groupIdentifier = "group.com.samuelvoltolini.skyr"
    /// Pixel sizes of the cover copies: one for lead albums, one for shelf tiles.
    public static let heroPixels = 600
    public static let tilePixels = 240

    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier)
    }

    private static var snapshotURL: URL? { containerURL?.appending(path: "widget-snapshot.json") }
    private static var coversURL: URL? { containerURL?.appending(path: "widget-covers", directoryHint: .isDirectory) }

    public static func load() -> WidgetSnapshot? {
        guard let url = snapshotURL, let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(WidgetSnapshot.self, from: data)
    }

    public static func coverURL(key: String, pixels: Int) -> URL? {
        guard let url = coversURL?.appending(path: "\(key)-\(pixels).jpg") else { return nil }
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Writes the snapshot and makes sure every cover it names exists in the sizes the widgets use,
    /// resizing from the app's cover files. Copies nothing needs any more are deleted.
    public static func write(_ snapshot: WidgetSnapshot, coverSources: [String: URL], heroKeys: Set<String>) {
        guard let snapshotURL, let coversURL else { return }
        try? FileManager.default.createDirectory(at: coversURL, withIntermediateDirectories: true)
        var wanted: Set<String> = []
        for (key, source) in coverSources {
            var sizes = [tilePixels]
            if heroKeys.contains(key) { sizes.append(heroPixels) }
            for pixels in sizes {
                let destination = coversURL.appending(path: "\(key)-\(pixels).jpg")
                wanted.insert(destination.lastPathComponent)
                if !FileManager.default.fileExists(atPath: destination.path) {
                    resize(source, maxPixels: pixels, to: destination)
                }
            }
        }
        if let files = try? FileManager.default.contentsOfDirectory(at: coversURL, includingPropertiesForKeys: nil) {
            for file in files where !wanted.contains(file.lastPathComponent) {
                try? FileManager.default.removeItem(at: file)
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: snapshotURL, options: .atomic)
        }
    }

    private static func resize(_ source: URL, maxPixels: Int, to destination: URL) {
        guard let imageSource = CGImageSourceCreateWithURL(source as CFURL, nil) else { return }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, options as CFDictionary),
              let sink = CGImageDestinationCreateWithURL(destination as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.86] as CFDictionary)
        CGImageDestinationFinalize(sink)
    }
}

/// Links from the widgets into the app.
public nonisolated enum WidgetLink {
    public static let scheme = "skyr"

    public enum Destination: Equatable, Sendable {
        case album(String)
        case playlist(String)
        /// A tab by name: "library", "playlists" or "downloads".
        case tab(String)
    }

    public static func album(id: String) -> URL { make(host: "album", id: id) }
    public static func playlist(id: String) -> URL { make(host: "playlist", id: id) }
    public static func tab(_ name: String) -> URL { make(host: "tab", id: name) }

    private static func make(host: String, id: String) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.queryItems = [URLQueryItem(name: "id", value: id)]
        return components.url ?? URL(string: "\(scheme)://\(host)")!
    }

    public static func destination(from url: URL) -> Destination? {
        guard url.scheme == scheme,
              let id = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value
        else { return nil }
        switch url.host {
        case "album": return .album(id)
        case "playlist": return .playlist(id)
        case "tab": return .tab(id)
        default: return nil
        }
    }
}
