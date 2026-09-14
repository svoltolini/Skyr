import Foundation

/// Built-in demo catalogue that mirrors the content of the design file.
public nonisolated enum SampleLibrary {
    private struct Seed {
        let title: String, artist: String, year: Int, genre: String, label: String
        let format: String, codec: String, sampleRate: Int?, bitDepth: Int?, bitrate: Int?, bytes: Int64
        let colorA: String, colorB: String
        var discs = 1
    }

    private static let seeds: [Seed] = [
        Seed(title: "Nocturne Drift", artist: "Halden Vey", year: 2023, genre: "Ambient", label: "Kranky", format: "FLAC 24/96", codec: "flac", sampleRate: 96_000, bitDepth: 24, bitrate: 2_304_000, bytes: 1_200_000_000, colorA: "#7c5cff", colorB: "#2a1a80"),
        Seed(title: "Concrete Gardens", artist: "The Lowline", year: 2019, genre: "Indie rock", label: "Sacred Bones", format: "FLAC 16/44", codec: "flac", sampleRate: 44_100, bitDepth: 16, bitrate: 1_011_000, bytes: 380_000_000, colorA: "#4a5568", colorB: "#141821"),
        Seed(title: "Saltwater Radio", artist: "Mira Solano", year: 2021, genre: "Indie folk", label: "Jagjaguwar", format: "ALAC 16/44", codec: "alac", sampleRate: 44_100, bitDepth: 16, bitrate: 890_000, bytes: 342_000_000, colorA: "#38bdf8", colorB: "#0c4a6e"),
        Seed(title: "Kinetic Hours", artist: "Orbital Twins", year: 2017, genre: "Electronic", label: "Warp", format: "FLAC 24/48", codec: "flac", sampleRate: 48_000, bitDepth: 24, bitrate: 1_640_000, bytes: 760_000_000, colorA: "#f472b6", colorB: "#4c0519"),
        Seed(title: "Blue Meridian", artist: "Josef Amari Trio", year: 1998, genre: "Jazz", label: "ECM", format: "DSD64", codec: "dsd", sampleRate: 2_822_400, bitDepth: 1, bitrate: 5_644_000, bytes: 2_400_000_000, colorA: "#1e40af", colorB: "#0f172a", discs: 2),
        Seed(title: "Parallel Lives", artist: "Ana Kestrel", year: 2024, genre: "Pop", label: "Self-released", format: "FLAC 24/96", codec: "flac", sampleRate: 96_000, bitDepth: 24, bitrate: 2_210_000, bytes: 1_100_000_000, colorA: "#fb923c", colorB: "#7c2d12"),
        Seed(title: "Rust & Honey", artist: "Delta Cartwright", year: 2011, genre: "Blues", label: "Fat Possum", format: "MP3 320", codec: "mp3", sampleRate: 44_100, bitDepth: nil, bitrate: 320_000, bytes: 98_000_000, colorA: "#c86a3e", colorB: "#5a2d1e"),
        Seed(title: "Northern Static", artist: "Vesper Field", year: 2020, genre: "Indie rock", label: "Captured Tracks", format: "FLAC 16/44", codec: "flac", sampleRate: 44_100, bitDepth: 16, bitrate: 960_000, bytes: 410_000_000, colorA: "#a3a3a3", colorB: "#262626"),
        Seed(title: "Terra Firma", artist: "Coastline Ensemble", year: 2015, genre: "Classical", label: "Deutsche Grammophon", format: "FLAC 24/192", codec: "flac", sampleRate: 192_000, bitDepth: 24, bitrate: 4_608_000, bytes: 3_100_000_000, colorA: "#84cc16", colorB: "#1a2e05"),
        Seed(title: "Midnight Ledger", artist: "Rook & Vale", year: 2022, genre: "Hip-hop", label: "Stones Throw", format: "FLAC 16/44", codec: "flac", sampleRate: 44_100, bitDepth: 16, bitrate: 1_020_000, bytes: 365_000_000, colorA: "#eab308", colorB: "#1c1917"),
        Seed(title: "Glasshouse", artist: "Iris Ohm", year: 2018, genre: "Electronic", label: "Ghostly", format: "ALAC 16/44", codec: "alac", sampleRate: 44_100, bitDepth: 16, bitrate: 905_000, bytes: 350_000_000, colorA: "#2dd4bf", colorB: "#134e4a"),
        Seed(title: "Small Weather", artist: "Tom Ferrier", year: 2009, genre: "Indie folk", label: "Bella Union", format: "MP3 V0", codec: "mp3", sampleRate: 44_100, bitDepth: nil, bitrate: 245_000, bytes: 82_000_000, colorA: "#e11d48", colorB: "#3b0a1a"),
    ]

    private static let trackNames = ["Slow Pulse Meridian", "Copper Wire", "Low Tide Sermon", "Hours Under Glass", "Field Recording, Dusk", "Anywhere but the Sea", "Second Light", "Vellum", "A Room That Breathes"]
    private static let durations: [TimeInterval] = [331, 254, 270, 198, 412, 226, 305, 187, 364]
    /// Seed indexes in the order the design lists them as recently added / recently played.
    private static let recentlyAddedOrder = [5, 0, 9, 2, 8, 3]
    private static let recentlyPlayedOrder = [6, 4, 11, 1, 10, 7]

    public static let rootPath = "/music"
    public static let serverName = "Sample library"
    public static let displayedTrackTotal = 41_208

    public static let catalogue: Catalogue = {
        let rankOrder = recentlyAddedOrder + (0..<seeds.count).filter { !recentlyAddedOrder.contains($0) }
        let albums = seeds.enumerated().map { seedIndex, seed -> Album in
            let id = Album.makeID(title: seed.title, artist: seed.artist)
            let ext = seed.codec == "dsd" ? "dsf" : seed.codec == "alac" ? "m4a" : seed.codec
            let folder = "\(rootPath)/\(seed.artist)/\(seed.year) - \(seed.title)"
            let firstOnSecondDisc = seed.discs > 1 ? 5 : trackNames.count
            let tracks = trackNames.enumerated().map { index, name in
                let disc = index < firstOnSecondDisc ? 1 : 2
                let number = index < firstOnSecondDisc ? index + 1 : index - firstOnSecondDisc + 1
                let fileName = seed.discs > 1 ? "\(disc)-\(String(format: "%02d", number)) \(name)" : "\(String(format: "%02d", number)) \(name)"
                return Track(
                    id: "demo_\(seedIndex)_\(index)", albumID: id, title: name, index: index, number: number, disc: disc,
                    duration: durations[index], codec: seed.codec, sampleRate: seed.sampleRate, bitDepth: seed.bitDepth,
                    bitrate: seed.bitrate, fileSize: seed.bytes / Int64(trackNames.count),
                    path: "\(folder)/\(fileName).\(ext)",
                    format: seed.format, artist: nil, albumTitleTag: seed.title, albumArtistTag: seed.artist,
                    yearTag: seed.year, genreTag: seed.genre, isEnriched: true
                )
            }
            return Album(
                id: id, title: seed.title, artist: seed.artist, year: seed.year, genre: seed.genre, label: seed.label,
                tracks: tracks, colorA: seed.colorA, colorB: seed.colorB,
                addedRank: seeds.count - (rankOrder.firstIndex(of: seedIndex) ?? seeds.count),
                folderPath: folder, coverPath: nil, folderTitle: seed.title, folderArtist: seed.artist, folderYear: seed.year
            )
        }
        return Catalogue(serverName: serverName, albums: albums, indexedAt: .now, rootPath: rootPath, driveID: "")
    }()

    public static func album(seed index: Int) -> Album { catalogue.albums.first { $0.id == Album.makeID(title: seeds[index].title, artist: seeds[index].artist) }! }

    public static var recentlyPlayedIDs: [String] { recentlyPlayedOrder.map { album(seed: $0).id } }

    public static let playlists: [Playlist] = [
        ("Late shift", "84 songs · 6 h 12 min", [0, 4, 7, 10]),
        ("Sunday, slowly", "41 songs · 3 h 04 min", [2, 6, 11, 8]),
        ("Hi-res showcase", "27 songs · 2 h 51 min", [8, 5, 3, 0]),
        ("Vinyl rips", "132 songs · 9 h 40 min", [6, 1, 9, 4]),
    ].map { name, summary, covers in
        let albums = covers.map { album(seed: $0) }
        return Playlist(id: "demo_playlist_\(name)", name: name, summary: summary, covers: albums, tracks: albums.flatMap { $0.tracks.prefix(3) })
    }

    public static let recentSearches = ["ECM", "24/96", "Vesper Field", "1998"]
}
