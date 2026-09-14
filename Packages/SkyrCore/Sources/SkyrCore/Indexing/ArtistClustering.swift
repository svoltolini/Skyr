import Foundation

/// Decides one album artist for the songs that share an album title inside a folder, so guests on
/// individual tracks ("Kygo & OneRepublic", "Kygo & Zak Abel") or a stray mis-tagged song do not
/// split the album into several.
public nonisolated enum ArtistClustering {
    public struct Item: Sendable {
        public var albumArtist: String?
        public var artist: String?
    }

    /// The artist to file each item under, in the same order as `items`. Every item gets the same
    /// answer: songs that share an album title in one folder are one album, whatever their credits.
    public static func assign(_ items: [Item], folderArtist: String?) -> [String] {
        let names = items.map { $0.albumArtist.nonEmpty ?? $0.artist.nonEmpty ?? folderArtist ?? "Unknown Artist" }
        guard let first = names.first else { return [] }
        if names.allSatisfy({ $0.caseInsensitiveCompare(first) == .orderedSame }) {
            return names
        }

        // 0. Album artist tags are the authority when most songs carry one: "Lil Baby & Lil Durk"
        //    stays the album's artist even though the songs credit each of them alone.
        let tagged = items.compactMap { $0.albumArtist.nonEmpty }
        if tagged.count * 2 > items.count, let chosen = mostCommon(tagged) {
            return [String](repeating: chosen, count: items.count)
        }
        let sets = names.map(participants)

        // 1. A whole name that every song's credit contains: "Kygo" among "Kygo & X" songs,
        //    "Simon & Garfunkel" among "Simon & Garfunkel feat. X", or the folder's own artist.
        var candidates = Array(Set(names))
        if let folderArtist { candidates.append(folderArtist) }
        candidates.sort { $0.count == $1.count ? $0 < $1 : $0.count < $1.count }
        if let chosen = best(candidates, in: sets, count: items.count, folderArtist: folderArtist) {
            return [String](repeating: chosen, count: items.count)
        }

        // 2. A single participant shared by most songs, kept in the spelling it first appears with.
        var display: [String: String] = [:]
        for name in names {
            for part in splitParticipants(name) where display[part.lowercased()] == nil { display[part.lowercased()] = part }
        }
        let participantNames = display.keys.sorted().compactMap { display[$0] }
        if let chosen = best(participantNames, in: sets, count: items.count, folderArtist: folderArtist) {
            return [String](repeating: chosen, count: items.count)
        }

        // 3. Nobody dominates by credit. The most frequent name takes the album when it covers at
        //    least half of the songs; otherwise it is a compilation. The album stays whole either way.
        var clusters: [(artist: String, members: Int)] = []
        for name in names {
            if let index = clusters.firstIndex(where: { $0.artist.caseInsensitiveCompare(name) == .orderedSame }) {
                clusters[index].members += 1
            } else {
                clusters.append((name, 1))
            }
        }
        if let biggest = clusters.max(by: { $0.members < $1.members }), biggest.members * 2 >= items.count {
            return [String](repeating: biggest.artist, count: items.count)
        }
        return [String](repeating: "Various Artists", count: items.count)
    }

    /// The spelling that appears most, compared without case.
    private static func mostCommon(_ values: [String]) -> String? {
        var counts: [String: (display: String, count: Int)] = [:]
        for value in values {
            let key = value.lowercased()
            counts[key] = (counts[key]?.display ?? value, (counts[key]?.count ?? 0) + 1)
        }
        return counts.values.max { $0.count == $1.count ? $0.display > $1.display : $0.count < $1.count }?.display
    }

    /// The candidate whose participants appear in more than half the songs (and in at least two of them).
    private static func best(_ candidates: [String], in sets: [Set<String>], count: Int, folderArtist: String?) -> String? {
        var winner: (name: String, support: Int)?
        for candidate in candidates {
            let needed = participants(candidate)
            guard !needed.isEmpty else { continue }
            let support = sets.filter { needed.isSubset(of: $0) }.count
            guard support * 2 > count, support >= 2 || count == 1 else { continue }
            let isFolder = folderArtist.map { $0.caseInsensitiveCompare(candidate) == .orderedSame } ?? false
            if let current = winner {
                let currentIsFolder = folderArtist.map { $0.caseInsensitiveCompare(current.name) == .orderedSame } ?? false
                if support > current.support || (support == current.support && isFolder && !currentIsFolder) {
                    winner = (candidate, support)
                }
            } else {
                winner = (candidate, support)
            }
        }
        return winner?.name
    }

    /// Lowercased people or bands named in a credit.
    public static func participants(_ name: String) -> Set<String> {
        Set(splitParticipants(name).map { $0.lowercased() })
    }

    /// "Alok, The Chainsmokers & Mae Stephens" → ["Alok", "The Chainsmokers", "Mae Stephens"].
    public static func splitParticipants(_ name: String) -> [String] {
        var text = name.replacingOccurrences(of: #"\s+x\s+"#, with: " & ", options: .regularExpression)
        text = text.replacingOccurrences(
            of: #"\s*(?:&|,|/|\+|\(|\)|\band\b|\bfeat\.?|\bfeaturing\b|\bft\.?|\bwith\b|\bvs\.?)\s*"#,
            with: "\u{1F}", options: [.regularExpression, .caseInsensitive]
        )
        return text.split(separator: "\u{1F}")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
