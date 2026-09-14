import Foundation

/// Derives album and track information from folder and file names.
public nonisolated enum PathParser {
    public struct AlbumGuess: Sendable, Hashable {
        public var artist: String
        public var title: String
        public var year: Int?
        public var disc: Int?
        /// True when the last folder was a disc folder such as "CD1" inside the album's folder.
        public var hasDiscFolder = false
    }

    public struct TrackGuess: Sendable, Hashable {
        public var number: Int?
        public var disc: Int?
        public var title: String
        public var artist: String?
    }

    /// `components` is the folder path relative to the chosen root, e.g. ["Halden Vey", "2023 - Nocturne Drift"].
    public static func album(components: [String], rootName: String) -> AlbumGuess {
        var parts = components.map(clean)
        var disc: Int?
        var hasDiscFolder = false
        if let last = parts.last, let number = discNumber(in: last), parts.count >= 2 {
            disc = number
            hasDiscFolder = true
            parts.removeLast()
        }
        guard let albumDir = parts.last else {
            return AlbumGuess(artist: "Unknown Artist", title: clean(rootName), year: nil, disc: disc, hasDiscFolder: hasDiscFolder)
        }
        var (title, year) = splitYear(albumDir)
        // "Album (Disc 2)" style folders sit next to each other and belong to one album.
        let split = splitDisc(title)
        if let suffixDisc = split.disc, disc == nil {
            disc = suffixDisc
            title = split.title
        }
        var artist = parts.count >= 2 ? parts[parts.count - 2] : ""
        if artist.isEmpty, let range = title.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            artist = String(title[..<range.lowerBound])
            title = String(title[range.upperBound...])
        }
        if artist.isEmpty { artist = parts.count == 1 ? title : "Unknown Artist" }
        if title.isEmpty { title = albumDir }
        return AlbumGuess(artist: artist, title: title, year: year, disc: disc, hasDiscFolder: hasDiscFolder)
    }

    /// Parses "03 - Title", "1-03 Title", "03. Title", "Artist - Title" and plain names.
    public static func track(fileName: String) -> TrackGuess {
        let base = clean((fileName as NSString).deletingPathExtension)
        if let match = firstMatch(#"^(\d{1,2})[-.](\d{2,3})[\s._-]+(.+)$"#, in: base), match.count == 4 {
            return TrackGuess(number: Int(match[2]), disc: Int(match[1]), title: match[3], artist: nil)
        }
        if let match = firstMatch(#"^(\d{1,3})[\s._-]+(.+)$"#, in: base), match.count == 3 {
            var title = match[2]
            var artist: String?
            if let range = title.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
                artist = String(title[..<range.lowerBound])
                title = String(title[range.upperBound...])
            }
            return TrackGuess(number: Int(match[1]), disc: nil, title: title, artist: artist)
        }
        if let range = base.range(of: #"\s+[-–—]\s+"#, options: .regularExpression) {
            return TrackGuess(number: nil, disc: nil, title: String(base[range.upperBound...]), artist: String(base[..<range.lowerBound]))
        }
        return TrackGuess(number: nil, disc: nil, title: base, artist: nil)
    }

    /// "CD1", "Disc 2", "Disk 02 - Live" and "Vol. 3" name a disc folder inside an album.
    public static func discNumber(in name: String) -> Int? {
        if let match = firstMatch(#"^(?:cd|disc|disk|dvd)\.?\s*[-_#]?\s*(\d{1,2})(?:\s*[-–—:(\[].*)?$"#, in: name, caseInsensitive: true), match.count == 2 {
            return Int(match[1])
        }
        guard let match = firstMatch(#"^(?:volume|vol)\.?\s*[-_]?\s*(\d{1,2})$"#, in: name, caseInsensitive: true), match.count == 2 else { return nil }
        return Int(match[1])
    }

    /// Splits "Greatest Hits (Disc 2)", "Greatest Hits [CD 2]", "Greatest Hits - Disc 2 of 3" and "Greatest Hits CD2"
    /// into the plain title and the disc number. Titles without a disc marker come back unchanged.
    public static func splitDisc(_ name: String) -> (title: String, disc: Int?) {
        let pattern = #"^(.+?)\s*[-–—_:,]?\s*[(\[]?\s*\b(?:cd|disc|disk)\.?\s*[-_#]?\s*(\d{1,2})(?:\s*(?:of|/)\s*\d{1,2})?\s*[)\]]?\s*$"#
        guard let match = firstMatch(pattern, in: name, caseInsensitive: true), match.count == 3, let disc = Int(match[2]) else {
            return (name, nil)
        }
        let title = clean(match[1])
        return title.isEmpty ? (name, nil) : (title, disc)
    }

    /// "2019 - Album", "Album (2019)", "Album [2019]" and "2019 Album" become a title and a year.
    public static func splitYear(_ name: String) -> (String, Int?) {
        if let match = firstMatch(#"^((?:19|20)\d{2})\s*[-–—._]\s*(.+)$"#, in: name), match.count == 3, let year = Int(match[1]) {
            return (match[2], year)
        }
        if let match = firstMatch(#"^(.+?)\s*[\(\[]((?:19|20)\d{2})[\)\]]\s*$"#, in: name), match.count == 3, let year = Int(match[2]) {
            return (match[1], year)
        }
        if let match = firstMatch(#"^((?:19|20)\d{2})\s+(.+)$"#, in: name), match.count == 3, let year = Int(match[1]) {
            return (match[2], year)
        }
        return (name, nil)
    }

    public static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Whole match plus capture groups, or nil.
    private static func firstMatch(_ pattern: String, in text: String, caseInsensitive: Bool = false) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: caseInsensitive ? [.caseInsensitive] : []) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range) else { return nil }
        return (0..<match.numberOfRanges).map { index in
            guard let bounds = Range(match.range(at: index), in: text) else { return "" }
            return String(text[bounds])
        }
    }
}
