import CryptoKit
import Foundation

/// Finds album art online when the files carry none, or all carry the same one.
public nonisolated enum ArtworkLookup {
    private struct SearchResult: Decodable {
        let results: [Item]
        struct Item: Decodable {
            let collectionName: String?
            let artistName: String?
            let artworkUrl100: String?
        }
    }

    /// Cover art from the iTunes Store catalogue, or nil when nothing matches well enough.
    public static func itunesCover(artist: String, album: String) async -> Data? {
        let query = "\(artist) \(album)".trimmingCharacters(in: .whitespaces)
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: query), URLQueryItem(name: "entity", value: "album"),
            URLQueryItem(name: "limit", value: "8"), URLQueryItem(name: "media", value: "music"),
        ]
        guard let url = components.url,
              let (data, _) = try? await URLSession.shared.data(from: url),
              let search = try? JSONDecoder().decode(SearchResult.self, from: data)
        else { return nil }

        let wantedAlbum = normalize(album)
        let wantedArtist = normalize(artist)
        let match = search.results.first { item in
            guard let name = item.collectionName, let itemArtist = item.artistName else { return false }
            let albumMatches = normalize(name) == wantedAlbum || normalize(name).hasPrefix(wantedAlbum) || wantedAlbum.hasPrefix(normalize(name))
            let artistMatches = normalize(itemArtist) == wantedArtist || normalize(itemArtist).contains(wantedArtist) || wantedArtist.contains(normalize(itemArtist))
            return albumMatches && artistMatches
        }
        guard let artwork = match?.artworkUrl100 else { return nil }
        let large = artwork.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        guard let imageURL = URL(string: large), let (image, response) = try? await URLSession.shared.data(from: imageURL),
              (response as? HTTPURLResponse)?.statusCode == 200, !image.isEmpty
        else { return nil }
        return image
    }

    public static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func normalize(_ text: String) -> String {
        text.lowercased()
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
