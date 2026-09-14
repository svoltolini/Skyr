import CryptoKit
import Foundation

/// Optional Apple artwork requests share one device-local choice across this app's profiles.
/// A profile or iCloud update can never turn this on.
@Observable
public final class ArtworkLookup {
    public static let shared = ArtworkLookup(preference: ArtworkPrivacyPreference())
    public static let disclosure = "When enabled, Skyr sends artist and album names to Apple’s iTunes Search service to find missing or repeated covers, then downloads matching artwork from Apple. Apple also receives connection information, including your IP address. Music files stay on your NAS or devices. This choice applies only to this device; turning it off stops new lookups and keeps artwork already saved."

    public private(set) var isEnabled: Bool
    public private(set) var preferenceError: String?
    @ObservationIgnored private let preference: ArtworkPrivacyPreference
    @ObservationIgnored private let request: @Sendable (URL, Int64) async throws -> Data
    @ObservationIgnored private var generation = UUID()
    @ObservationIgnored private var enabledAt: Date?
    @ObservationIgnored private var tasks: [UUID: Task<Cover?, Never>] = [:]

    /// A result is usable only while the choice that allowed its requests is still current.
    public struct Cover: Sendable {
        fileprivate let data: Data
        fileprivate let generation: UUID
    }

    init(preference: ArtworkPrivacyPreference,
         request: (@Sendable (URL, Int64) async throws -> Data)? = nil) {
        self.preference = preference
        isEnabled = preference.load()
        enabledAt = preference.enabledAt
        if let request {
            self.request = request
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 20
            let session = URLSession(configuration: configuration, delegate: ArtworkRedirectDelegate(), delegateQueue: nil)
            self.request = { url, limit in
                try await ArtworkDownload.data(from: url, maximum: limit, session: session)
            }
        }
    }

    public func setEnabled(_ enabled: Bool) {
        if enabled, isEnabled { return }
        preferenceError = nil
        if !enabled {
            // Revocation takes effect before touching disk or waiting for a network callback.
            isEnabled = false
            generation = UUID()
            for task in tasks.values { task.cancel() }
            tasks.removeAll()
        }
        do {
            try preference.save(enabled)
            if enabled, !isEnabled {
                generation = UUID()
                enabledAt = .now
                isEnabled = true
            }
        } catch {
            preferenceError = enabled
                ? "Couldn’t save this choice. Apple artwork lookup remains off."
                : "Artwork lookup is off for this session, but the choice couldn’t be saved. Check it again after reopening Skyr."
        }
    }

    public func itunesCover(artist: String, album: String) async -> Cover? {
        guard isEnabled, !Task.isCancelled else { return nil }
        let allowedGeneration = generation
        let id = UUID()
        let task = Task { await fetchCover(artist: artist, album: album, generation: allowedGeneration) }
        tasks[id] = task
        let result = await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        tasks[id] = nil
        guard isCurrent(allowedGeneration), !Task.isCancelled else { return nil }
        return result
    }

    /// Call on the main actor immediately before publishing or caching, without another suspension.
    public func acceptedData(from cover: Cover) -> Data? {
        isCurrent(cover.generation) && !Task.isCancelled ? cover.data : nil
    }

    private func isCurrent(_ value: UUID) -> Bool { isEnabled && generation == value }

    /// A previous NAS-only miss must not delay the first explicitly enabled lookup by a week.
    func shouldRetryMissingCover(after attempt: Date) -> Bool {
        isEnabled && enabledAt.map { attempt < $0 } == true
    }

    private struct SearchResult: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
    }

    private func fetchCover(artist: String, album: String, generation: UUID) async -> Cover? {
        let wantedAlbum = Self.normalize(album)
        let wantedArtist = Self.normalize(artist)
        guard !wantedAlbum.isEmpty, !wantedArtist.isEmpty else { return nil }
        let query = "\(artist) \(album)".trimmingCharacters(in: .whitespaces)
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query), URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "8"), URLQueryItem(name: "media", value: "music"),
        ]
        guard isCurrent(generation), !Task.isCancelled, let url = components.url,
              let data = try? await request(url, 1024 * 1024),
              isCurrent(generation), !Task.isCancelled,
              let search = try? JSONDecoder().decode(SearchResult.self, from: data) else { return nil }

        let match = search.results.first { item in
            guard let name = item.collectionName, let itemArtist = item.artistName else { return false }
            let albumMatches = Self.normalize(name) == wantedAlbum || Self.normalize(name).hasPrefix(wantedAlbum) || wantedAlbum.hasPrefix(Self.normalize(name))
            let artistMatches = Self.normalize(itemArtist) == wantedArtist || Self.normalize(itemArtist).contains(wantedArtist) || wantedArtist.contains(Self.normalize(itemArtist))
            return albumMatches && artistMatches
        }
        guard let artwork = match?.artworkUrl100 else { return nil }
        let large = artwork.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard isCurrent(generation), !Task.isCancelled, let imageURL = URL(string: large),
              Self.isArtworkURL(imageURL), let image = try? await request(imageURL, 12 * 1024 * 1024),
              isCurrent(generation), !Task.isCancelled, !image.isEmpty else { return nil }
        return Cover(data: image, generation: generation)
    }

    nonisolated static func isArtworkURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host.hasSuffix(".mzstatic.com")
    }

    public nonisolated static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

nonisolated enum ArtworkDownload {
    /// Byte-by-byte response bounds are enforced away from the UI executor.
    @concurrent static func data(from url: URL, maximum: Int64, session: URLSession) async throws -> Data {
        try Task.checkCancellation()
        let (bytes, response) = try await session.bytes(from: url)
        defer { bytes.task.cancel() }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
        return try await withTaskCancellationHandler {
            try await BoundedBytes.collect(bytes, maximum: maximum, expectedLength: response.expectedContentLength)
        } onCancel: {
            bytes.task.cancel()
        }
    }
}

/// The search query must not follow a redirect to another service. Artwork can move only within
/// Apple's artwork hosts; credentials and cookies are not attached to either kind of request.
private nonisolated final class ArtworkRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        guard let original = task.originalRequest?.url, let destination = request.url,
              destination.scheme?.lowercased() == "https", destination.user == nil, destination.password == nil,
              destination.port == nil || destination.port == 443 else { completionHandler(nil); return }
        let allowed = ArtworkLookup.isArtworkURL(original)
            ? ArtworkLookup.isArtworkURL(destination)
            : destination.host?.lowercased() == "itunes.apple.com"
        completionHandler(allowed ? request : nil)
    }
}
