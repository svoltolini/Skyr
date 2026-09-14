import Foundation

/// A folder on the drive that holds audio files, as found by the scan.
public nonisolated struct ScannedFolder: Sendable, Hashable {
    public let path: String
    public let audio: [RemoteEntry]
    public let cover: RemoteEntry?
}

/// The indexed music library: albums with their tracks, plus where they came from.
public nonisolated struct Catalogue: Codable, Sendable {
    public var serverName: String
    public var albums: [Album]
    public var indexedAt: Date
    /// The folder that was indexed, e.g. "/music".
    public var rootPath: String
    public var driveID: String

    public nonisolated static let empty = Catalogue(serverName: "", albums: [], indexedAt: .distantPast, rootPath: "", driveID: "")

    public var isEmpty: Bool { albums.isEmpty }
    public var trackCount: Int { albums.reduce(0) { $0 + $1.tracks.count } }
    public var enrichedTrackCount: Int { albums.reduce(0) { $0 + $1.tracks.filter(\.isEnriched).count } }
    public var totalBytes: Int64 { albums.reduce(0) { $0 + $1.totalBytes } }
    public var artistCount: Int { Set(albums.map(\.artist)).count }

    public var summary: String { "\(albums.count.formatted()) albums · \(ByteText.format(totalBytes))" }
    public var detail: String { "\(albums.count.formatted()) albums · \(artistCount.formatted()) artists · \(ByteText.format(totalBytes))" }
    public var rootName: String { rootPath.split(separator: "/").last.map(String.init) ?? "music" }

    // MARK: Building from a folder scan

    /// Groups scanned folders into albums using folder and file names; `existing` supplies tags already read.
    public nonisolated static func build(folders: [ScannedFolder], rootPath: String, serverName: String, driveID: String, existing: Catalogue?) -> Catalogue {
        let previous = Dictionary(existing?.albums.flatMap(\.tracks).map { ($0.id, $0) } ?? [], uniquingKeysWith: { first, _ in first })
        let rootName = rootPath.split(separator: "/").last.map(String.init) ?? "music"

        struct Draft {
            var guess: PathParser.AlbumGuess
            var folderPath: String
            var coverPath: String?
            var tracks: [Track] = []
            var newest: Double = 0
        }
        var drafts: [String: Draft] = [:]
        var order: [String] = []

        for folder in folders {
            let relative = folder.path.hasPrefix(rootPath) ? String(folder.path.dropFirst(rootPath.count)) : folder.path
            let components = relative.split(separator: "/").map(String.init)
            let guess = PathParser.album(components: components, rootName: rootName)
            let id = Album.makeID(title: guess.title, artist: guess.artist)
            if drafts[id] == nil {
                let albumFolder = guess.hasDiscFolder ? String(folder.path.split(separator: "/").dropLast().map { "/" + $0 }.joined()) : folder.path
                drafts[id] = Draft(guess: guess, folderPath: albumFolder.isEmpty ? folder.path : albumFolder)
                order.append(id)
            }
            if drafts[id]!.coverPath == nil || guess.disc == nil, let cover = folder.cover {
                drafts[id]!.coverPath = cover.path
            }
            for file in folder.audio {
                let trackGuess = PathParser.track(fileName: file.name)
                let codec = codec(forExtension: file.fileExtension)
                var track = Track(
                    id: file.path, albumID: id, title: trackGuess.title, index: 0,
                    number: trackGuess.number ?? 0, disc: trackGuess.disc ?? guess.disc ?? 1,
                    duration: 0, codec: codec, sampleRate: nil, bitDepth: nil, bitrate: nil,
                    fileSize: file.size, path: file.path, format: FormatLabel.make(codec: codec, sampleRate: nil, bitrate: nil, bitDepth: nil),
                    artist: trackGuess.artist, albumTitleTag: nil, albumArtistTag: nil, yearTag: nil, genreTag: nil,
                    isEnriched: false
                )
                if let known = previous[file.path], known.fileSize == file.size {
                    if known.isEnriched {
                        track = known
                        track.normalizeDiscFromAlbumTag()
                    } else {
                        track.enrichAttempts = known.enrichAttempts
                        track.enrichAttemptedAt = known.enrichAttemptedAt
                    }
                }
                drafts[id]!.tracks.append(track)
                if let modified = file.modified?.timeIntervalSince1970 { drafts[id]!.newest = max(drafts[id]!.newest, modified) }
            }
        }

        var albums: [Album] = order.compactMap { id in
            guard var draft = drafts[id], !draft.tracks.isEmpty else { return nil }
            draft.tracks.sort { lhs, rhs in
                if lhs.disc != rhs.disc { return lhs.disc < rhs.disc }
                let l = lhs.number == 0 ? Int.max : lhs.number
                let r = rhs.number == 0 ? Int.max : rhs.number
                if l != r { return l < r }
                return lhs.fileName.localizedStandardCompare(rhs.fileName) == .orderedAscending
            }
            for index in draft.tracks.indices {
                draft.tracks[index].index = index
                if draft.tracks[index].number == 0 { draft.tracks[index].number = index + 1 }
            }
            let colors = ArtPalette.pair(for: id)
            var album = Album(
                id: id, title: draft.guess.title, artist: draft.guess.artist, year: draft.guess.year ?? 0,
                genre: "Unknown genre", label: nil, tracks: draft.tracks, colorA: colors.0, colorB: colors.1,
                addedRank: Int(draft.newest), folderPath: draft.folderPath, coverPath: draft.coverPath,
                folderTitle: draft.guess.title, folderArtist: draft.guess.artist, folderYear: draft.guess.year
            )
            album.refreshFromTags()
            return album
        }
        albums.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        return Catalogue(serverName: serverName, albums: albums, indexedAt: .now, rootPath: rootPath, driveID: driveID)
    }

    /// Rebuilds albums from the tags read so far, so folders that mix albums split correctly and
    /// compilations stay together. Folder-based grouping remains for tracks without tags.
    public mutating func regroupByTags() {
        struct Draft {
            var template: Album
            var artist: String
            var tracks: [Track] = []
            var sources: Set<String> = []
        }
        let previous = Dictionary(albums.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var drafts: [String: Draft] = [:]
        var order: [String] = []
        for album in albums {
            let folderArtist = album.folderArtist == "Unknown Artist" ? nil : album.folderArtist
            // Tracks grouped by album title and, where the tag exists, album artist: two different
            // artists' "Greatest Hits" in one folder stay two albums, while songs missing the tag join
            // the tagged album their own credit points at. Each group then settles on one artist, so a
            // guest on a few songs never splits an album.
            var groups: [String: [Track]] = [:]
            var groupOrder: [String] = []
            for track in album.tracks {
                let title = (track.albumTitleTag.nonEmpty ?? album.folderTitle).lowercased()
                let key = title + "\u{1F}" + (track.albumArtistTag.nonEmpty?.lowercased() ?? "")
                if groups[key] == nil { groupOrder.append(key) }
                groups[key, default: []].append(track)
            }
            for key in groupOrder where key.hasSuffix("\u{1F}") {
                let title = String(key.dropLast())
                let tagged = groupOrder.filter { $0 != key && $0.hasPrefix(title + "\u{1F}") && groups[$0] != nil }
                guard !tagged.isEmpty, let untagged = groups[key] else { continue }
                for track in untagged {
                    let credit = ArtistClustering.participants(track.artist ?? "")
                    let home = tagged.first { taggedKey in
                        let artist = String(taggedKey.dropFirst(title.count + 1))
                        return !credit.isEmpty && !ArtistClustering.participants(artist).isDisjoint(with: credit)
                    } ?? tagged.max { (groups[$0]?.count ?? 0) < (groups[$1]?.count ?? 0) }!
                    groups[home, default: []].append(track)
                }
                groups[key] = nil
            }
            for key in groupOrder {
                guard let tracks = groups[key], !tracks.isEmpty else { continue }
                let title = tracks.first?.albumTitleTag.nonEmpty ?? album.folderTitle
                let artists = ArtistClustering.assign(
                    tracks.map { ArtistClustering.Item(albumArtist: $0.albumArtistTag, artist: $0.artist) },
                    folderArtist: folderArtist
                )
                for (track, artist) in zip(tracks, artists) {
                    let id = Album.makeID(title: title, artist: artist)
                    if drafts[id] == nil {
                        drafts[id] = Draft(template: album, artist: artist)
                        order.append(id)
                    }
                    var moved = track
                    moved.albumID = id
                    drafts[id]!.tracks.append(moved)
                    drafts[id]!.sources.insert(album.id)
                }
            }
        }
        var derivedCount: [String: Int] = [:]
        for id in order {
            for source in drafts[id]?.sources ?? [] { derivedCount[source, default: 0] += 1 }
        }
        var regrouped: [Album] = []
        for id in order {
            guard let draft = drafts[id], !draft.tracks.isEmpty else { continue }
            let ownsSources = draft.sources.allSatisfy { derivedCount[$0] == 1 }
            let template = draft.template
            let colors = ArtPalette.pair(for: id)
            let sourceAlbums = draft.sources.compactMap { previous[$0] }
            var album = Album(
                id: id, title: template.folderTitle, artist: template.folderArtist, year: template.year, genre: template.genre,
                label: nil, tracks: draft.tracks, colorA: colors.0, colorB: colors.1,
                addedRank: sourceAlbums.map(\.addedRank).max() ?? template.addedRank,
                folderPath: Self.commonDirectory(of: draft.tracks.compactMap(\.path)),
                coverPath: ownsSources ? sourceAlbums.compactMap(\.coverPath).first : nil,
                folderTitle: template.folderTitle, folderArtist: template.folderArtist, folderYear: template.folderYear
            )
            album.sortTracks()
            album.refreshFromTags()
            album.artist = draft.artist
            if id != template.id, ownsSources, !CoverStore.hasCover(for: id) {
                for source in draft.sources where CoverStore.hasCover(for: source) {
                    CoverStore.copy(from: source, to: id)
                    break
                }
            }
            Self.adoptTrackCoverIfNeeded(for: album)
            regrouped.append(album)
        }
        albums = Self.mergingSameTitles(regrouped).sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
    }

    /// Second pass across folders: the same title filed under "Kygo" in one folder and "Kygo & Guest" in
    /// another is still one album when the credits share an artist. Different artists with a same-named
    /// album are left alone.
    public nonisolated static func mergingSameTitles(_ albums: [Album]) -> [Album] {
        var byTitle: [String: [Int]] = [:]
        for (index, album) in albums.enumerated() {
            byTitle[album.title.lowercased(), default: []].append(index)
        }
        var result: [Album] = []
        var consumed = Set<Int>()
        for (index, album) in albums.enumerated() {
            guard !consumed.contains(index) else { continue }
            let peers = byTitle[album.title.lowercased()] ?? [index]
            consumed.formUnion(peers)
            guard peers.count > 1 else {
                result.append(album)
                continue
            }
            let members = peers.map { albums[$0] }
            let items = members.flatMap { member in member.tracks.map { _ in ArtistClustering.Item(albumArtist: member.artist, artist: nil) } }
            let assigned = ArtistClustering.assign(items, folderArtist: nil)
            var groups: [String: [Album]] = [:]
            var order: [String] = []
            var offset = 0
            for member in members {
                let artist = assigned[offset]
                offset += member.tracks.count
                if groups[artist] == nil { order.append(artist) }
                groups[artist, default: []].append(member)
            }
            for artist in order {
                let group = groups[artist] ?? []
                if group.count == 1, let only = group.first, only.artist == artist {
                    result.append(only)
                } else {
                    result.append(combine(group, artist: artist))
                }
            }
        }
        return result
    }

    /// One album out of several that share a title, filed under `artist`; the biggest one lends its details and cover.
    nonisolated private static func combine(_ group: [Album], artist: String) -> Album {
        let primary = group.max { $0.tracks.count < $1.tracks.count } ?? group[0]
        let id = Album.makeID(title: primary.title, artist: artist)
        var tracks = group.flatMap(\.tracks)
        for index in tracks.indices { tracks[index].albumID = id }
        let colors = ArtPalette.pair(for: id)
        var album = Album(
            id: id, title: primary.title, artist: artist, year: primary.year, genre: primary.genre, label: primary.label,
            tracks: tracks, colorA: colors.0, colorB: colors.1,
            addedRank: group.map(\.addedRank).max() ?? primary.addedRank,
            folderPath: commonDirectory(of: tracks.compactMap(\.path)),
            coverPath: primary.coverPath,
            folderTitle: primary.folderTitle, folderArtist: primary.folderArtist, folderYear: primary.folderYear
        )
        album.sortTracks()
        album.refreshFromTags()
        album.artist = artist
        if !CoverStore.hasCover(for: id) {
            for source in group.sorted(by: { $0.tracks.count > $1.tracks.count }) where CoverStore.hasCover(for: source.id) {
                CoverStore.copy(from: source.id, to: id)
                break
            }
        }
        adoptTrackCoverIfNeeded(for: album)
        diagnostics("Merged \(group.count) albums titled “\(primary.title)” (\(group.map(\.artist).joined(separator: " / "))) under \(artist)")
        return album
    }

    /// An album without a cover takes the picture embedded in one of its songs, if one was saved.
    public nonisolated static func adoptTrackCoverIfNeeded(for album: Album) {
        guard !CoverStore.hasCover(for: album.id) else { return }
        if let track = album.tracks.first(where: { CoverStore.hasTrackCover(for: $0.id) }) {
            CoverStore.adoptTrackCover(from: track.id, for: album.id)
        }
    }

    /// Longest directory prefix shared by every path.
    public nonisolated static func commonDirectory(of paths: [String]) -> String? {
        guard var common = paths.first.map({ Array($0.split(separator: "/").dropLast()) }) else { return nil }
        for path in paths.dropFirst() {
            let parts = Array(path.split(separator: "/").dropLast())
            var matched = 0
            while matched < min(common.count, parts.count), common[matched] == parts[matched] { matched += 1 }
            common = Array(common.prefix(matched))
            if common.isEmpty { break }
        }
        return common.isEmpty ? nil : "/" + common.joined(separator: "/")
    }

    /// The album that currently holds a track, wherever regrouping has moved it.
    public func album(containing trackID: String) -> Album? {
        albums.first { album in album.tracks.contains { $0.id == trackID } }
    }

    /// Replaces one track with its enriched version and refreshes its album's tags. The track is
    /// found by id, since regrouping may have moved it to another album since it was queued.
    public mutating func apply(_ track: Track) {
        let albumIndex = albums.firstIndex { $0.id == track.albumID && $0.tracks.contains { $0.id == track.id } }
            ?? albums.firstIndex { album in album.tracks.contains { $0.id == track.id } }
        guard let albumIndex, let trackIndex = albums[albumIndex].tracks.firstIndex(where: { $0.id == track.id }) else { return }
        var moved = track
        moved.albumID = albums[albumIndex].id
        albums[albumIndex].tracks[trackIndex] = moved
        albums[albumIndex].sortTracks()
        albums[albumIndex].refreshFromTags()
    }

    public nonisolated static func codec(forExtension ext: String) -> String {
        switch ext {
        case "flac": "flac"
        case "mp3": "mp3"
        case "m4a", "mp4", "aac": "aac"
        case "alac": "alac"
        case "wav": "wav"
        case "aif", "aiff": "aiff"
        case "ogg", "oga": "ogg"
        case "opus": "opus"
        case "wma": "wma"
        case "ape": "ape"
        case "wv": "wavpack"
        case "dsf", "dff": "dsd"
        default: ext
        }
    }

    // MARK: Folder tree

    public func folderTree() -> FolderNode {
        final class Builder {
            var children: [String: Builder] = [:]
            var tracks: [Track] = []
        }
        let root = Builder()
        for album in albums {
            for track in album.tracks {
                guard let path = track.path else { continue }
                let relative = path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : path
                var node = root
                for directory in relative.split(separator: "/").dropLast() {
                    let key = String(directory)
                    if let child = node.children[key] {
                        node = child
                    } else {
                        let child = Builder()
                        node.children[key] = child
                        node = child
                    }
                }
                node.tracks.append(track)
            }
        }
        func materialize(_ name: String, _ path: String, _ builder: Builder) -> FolderNode {
            let subfolders = builder.children
                .sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
                .map { materialize($0.key, path + "/" + $0.key, $0.value) }
            let tracks = builder.tracks.sorted { $0.fileName.localizedStandardCompare($1.fileName) == .orderedAscending }
            return FolderNode(name: name, path: path, subfolders: subfolders, tracks: tracks)
        }
        return materialize(rootName, rootPath, root)
    }
}

/// Short human readable format badges such as "FLAC 24/96", "FLAC 44.1 kHz" or "MP3 320".
public nonisolated enum FormatLabel {
    public static func make(codec: String, sampleRate: Int?, bitrate: Int?, bitDepth: Int?) -> String {
        let name: String = switch codec {
        case "flac": "FLAC"
        case "alac": "ALAC"
        case "mp3": "MP3"
        case "aac": "AAC"
        case "dsd": "DSD"
        case "wav": "WAV"
        case "aiff": "AIFF"
        case "ogg": "OGG"
        case "opus": "Opus"
        case "wma": "WMA"
        case "ape": "APE"
        case "wavpack": "WavPack"
        case "pcm": "PCM"
        default: codec.isEmpty ? "Audio" : codec.uppercased()
        }
        if Track.losslessCodecs.contains(codec) {
            guard let sampleRate, sampleRate > 0 else { return name }
            if sampleRate >= 1_000_000 { return "\(name) \(String(format: "%.1f", Double(sampleRate) / 1_000_000)) MHz" }
            let khz = Double(sampleRate) / 1000
            let rate = khz == khz.rounded() ? String(Int(khz)) : String(format: "%.1f", khz)
            if let bitDepth, bitDepth > 0 { return "\(name) \(bitDepth)/\(rate)" }
            return "\(name) \(rate) kHz"
        }
        guard let bitrate, bitrate > 0 else { return name }
        return "\(name) \(bitrate / 1000)"
    }
}

nonisolated extension Optional where Wrapped == String {
    public var nonEmpty: String? {
        guard let value = self?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else { return nil }
        return value
    }
}
