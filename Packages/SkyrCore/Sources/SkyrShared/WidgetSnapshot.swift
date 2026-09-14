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

    private static let storage = Storage(directory: containerURL)

    public static func load() -> WidgetSnapshot? { storage.load() }
    public static func coverURL(key: String, pixels: Int) -> URL? { storage.coverURL(key: key, pixels: pixels) }
    public static func resetAuthorization() { storage.resetAuthorization() }
    @discardableResult public static func setSession(_ sessionID: UUID?) -> Bool { storage.setSession(sessionID) }
    public static func publication(for sessionID: UUID) -> Publication? { storage.publication(for: sessionID) }
    public static func write(_ snapshot: WidgetSnapshot, publication: Publication, coverSources: [String: URL], heroKeys: Set<String>) async -> Bool {
        await storage.write(snapshot, publication: publication, coverSources: coverSources, heroKeys: heroKeys)
    }

    fileprivate nonisolated struct Authorization: Codable, Equatable, Sendable {
        let sessionID: UUID?
        let generation: UUID
    }

    private nonisolated struct Envelope: Codable, Sendable {
        let authorization: Authorization
        let snapshot: WidgetSnapshot
        let artworkPolicyVersion: Int?
    }

    /// A request belongs to one authenticated opening and one refresh. It cannot be reused after
    /// a newer refresh, a lock, a profile switch, or a fresh launch of the app.
    public nonisolated struct Publication: Sendable {
        fileprivate let authorization: Authorization
        fileprivate let revision: UInt64
    }

    /// The widget extension reads the same authorization marker as the publisher. Missing, older,
    /// malformed, or revoked markers fail closed. An injected directory keeps tests out of App Group.
    public nonisolated final class Storage: @unchecked Sendable {
        private let directory: URL?
        private let lock = NSLock()
        private let writer = DispatchQueue(label: "com.samuelvoltolini.skyr.widget-publication", qos: .utility)
        // Only the small authorization update and final snapshot commit hold this lock. Cover
        // decoding and deletion run on the utility queue, so locking a profile does not wait on them.
        private var authorization = Authorization(sessionID: nil, generation: UUID())
        private var revision: UInt64 = 0

        public init(directory: URL?) { self.directory = directory }

        private var authorizationURL: URL? { directory?.appending(path: "widget-authorization.json") }
        private var snapshotURL: URL? { directory?.appending(path: "widget-snapshot.json") }
        private var coversURL: URL? { directory?.appending(path: "widget-covers", directoryHint: .isDirectory) }

        public func resetAuthorization() { updateSession(nil, force: true) }

        @discardableResult public func setSession(_ sessionID: UUID?) -> Bool { updateSession(sessionID, force: false) }

        @discardableResult private func updateSession(_ sessionID: UUID?, force: Bool) -> Bool {
            lock.withLock {
                guard force || authorization.sessionID != sessionID else { return false }
                authorization = Authorization(sessionID: sessionID, generation: UUID())
                revision &+= 1
                // Persist the boundary before returning to the profile picker. The single, small
                // atomic marker write is synchronous; all expensive filesystem work stays off main.
                if let authorizationURL {
                    do {
                        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
                        try JSONEncoder().encode(authorization).write(to: authorizationURL, options: .atomic)
                    } catch {
                        // A failed write must not leave a previous opening authorized.
                        try? FileManager.default.removeItem(at: authorizationURL)
                    }
                }
                writer.async { [self] in purgeRevokedFiles() }
                return true
            }
        }

        public func publication(for sessionID: UUID) -> Publication? {
            lock.withLock {
                guard authorization.sessionID == sessionID, readAuthorization() == authorization else { return nil }
                revision &+= 1
                return Publication(authorization: authorization, revision: revision)
            }
        }

        public func load() -> WidgetSnapshot? {
            guard let envelope = authorizedEnvelope() else { return nil }
            return envelope.snapshot
        }

        public func coverURL(key: String, pixels: Int) -> URL? {
            guard safeKey(key), let envelope = authorizedEnvelope(), let coversURL else { return nil }
            let url = coversURL.appending(path: envelope.authorization.generation.uuidString, directoryHint: .isDirectory)
                .appending(path: "\(key)-\(pixels).jpg")
            guard FileManager.default.fileExists(atPath: url.path), readAuthorization() == envelope.authorization else { return nil }
            return url
        }

        private func authorizedEnvelope() -> Envelope? {
            guard let access = readAuthorization(), access.sessionID != nil,
                  let snapshotURL, let data = try? Data(contentsOf: snapshotURL) else { return nil }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let envelope = try? decoder.decode(Envelope.self, from: data), envelope.authorization == access,
                  envelope.artworkPolicyVersion == ArtworkPolicy.version,
                  readAuthorization() == access else { return nil }
            return envelope
        }

        private func readAuthorization() -> Authorization? {
            guard let authorizationURL, let data = try? Data(contentsOf: authorizationURL) else { return nil }
            return try? JSONDecoder().decode(Authorization.self, from: data)
        }

        private func accepts(_ publication: Publication) -> Bool {
            lock.withLock { acceptsUnderLock(publication) }
        }

        private func acceptsUnderLock(_ publication: Publication) -> Bool {
            publication.authorization.sessionID != nil && publication.authorization == authorization
                && publication.revision == revision && readAuthorization() == authorization
        }

        /// A serial writer avoids overlapping cover cleanup and publication. The revision is checked
        /// again at the commit so cancelling a delayed task cannot allow an old snapshot to reappear.
        public func write(_ snapshot: WidgetSnapshot, publication: Publication, coverSources: [String: URL], heroKeys: Set<String>) async -> Bool {
            await withCheckedContinuation { continuation in
                writer.async { [self] in
                    continuation.resume(returning: publish(snapshot, publication: publication, coverSources: coverSources, heroKeys: heroKeys))
                }
            }
        }

        private func publish(_ snapshot: WidgetSnapshot, publication: Publication, coverSources: [String: URL], heroKeys: Set<String>) -> Bool {
            guard accepts(publication), let snapshotURL, let coversURL else { return false }
            let copies = coversURL.appending(path: publication.authorization.generation.uuidString, directoryHint: .isDirectory)
            do { try FileManager.default.createDirectory(at: copies, withIntermediateDirectories: true) } catch { return false }
            var wanted: Set<String> = []
            for (key, source) in coverSources where safeKey(key) {
                var sizes = [WidgetStore.tilePixels]
                if heroKeys.contains(key) { sizes.append(WidgetStore.heroPixels) }
                for pixels in sizes {
                    guard accepts(publication) else { return false }
                    let destination = copies.appending(path: "\(key)-\(pixels).jpg")
                    wanted.insert(destination.lastPathComponent)
                    if !FileManager.default.fileExists(atPath: destination.path) {
                        WidgetStore.resize(source, maxPixels: pixels, to: destination)
                    }
                }
            }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(Envelope(authorization: publication.authorization, snapshot: snapshot, artworkPolicyVersion: ArtworkPolicy.version)) else { return false }
            let published = lock.withLock {
                guard acceptsUnderLock(publication) else { return false }
                do { try data.write(to: snapshotURL, options: .atomic); return true } catch { return false }
            }
            guard published else { return false }
            if let files = try? FileManager.default.contentsOfDirectory(at: copies, includingPropertiesForKeys: nil) {
                for file in files where !wanted.contains(file.lastPathComponent) { try? FileManager.default.removeItem(at: file) }
            }
            return true
        }

        private func purgeRevokedFiles() {
            let access = readAuthorization()
            if authorizedEnvelope() == nil, let snapshotURL { try? FileManager.default.removeItem(at: snapshotURL) }
            guard let coversURL, let files = try? FileManager.default.contentsOfDirectory(at: coversURL, includingPropertiesForKeys: nil) else { return }
            let allowedDirectory = access?.sessionID == nil ? nil : access?.generation.uuidString
            for file in files where file.lastPathComponent != allowedDirectory { try? FileManager.default.removeItem(at: file) }
        }

        private func safeKey(_ key: String) -> Bool {
            !key.isEmpty && key.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
        }

        /// Waits for copies and revocation cleanup already submitted to this store.
        public func flush() async {
            await withCheckedContinuation { continuation in writer.async { continuation.resume() } }
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
