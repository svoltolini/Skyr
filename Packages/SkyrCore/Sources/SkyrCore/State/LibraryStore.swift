import SwiftUI

/// Everything the store derives from a catalogue: shown albums, lookups, shelves and search keys.
/// Built off the main thread whenever the library is already on screen.
public nonisolated struct DerivedLibrary: Sendable {
    public var sourceID: String
    public var albums: [Album]
    public var albumsByID: [String: Album]
    public var tracksByID: [String: Track]
    public var allTracks: [Track]
    /// Lowercased "title artist" per album and title per track, parallel to `albums` and `allTracks`.
    public var albumSearchKeys: [String]
    public var trackSearchKeys: [String]
    public var artists: [Artist]
    public var genres: [Genre]
    public var genreShelves: [Genre]
    public var decades: [Decade]
    public var hiResAlbums: [Album]
    public var recentlyAdded: [Album]
    public var coveredAlbumIDs: Set<String>
    public var palettes: [String: CoverPalette.Pair]
    /// Only rebuilt when the catalogue itself changed; it depends on nothing else.
    public var folderRoot: FolderNode?

    public static func make(
        catalogue: Catalogue, hidesBrackets: Bool, genreAliases: [String: String],
        knownPalettes: [String: CoverPalette.Pair], includeFolders: Bool
    ) -> DerivedLibrary {
        let covered = catalogue.driveID.isEmpty ? [] : CoverStore.coveredAlbumIDs(among: catalogue.albums)
        var palettes = knownPalettes.filter { covered.contains($0.key) }
        for id in covered where palettes[id] == nil {
            if let pair = CoverStore.palette(for: id) { palettes[id] = pair }
        }
        let albums = catalogue.albums.map { album in
            var shown = album
            if hidesBrackets {
                shown.title = Album.strippingBrackets(album.title)
                for index in shown.tracks.indices {
                    shown.tracks[index].title = Album.strippingBrackets(shown.tracks[index].title)
                }
            }
            if let pair = palettes[album.id] {
                shown.colorA = pair.primary
                shown.colorB = pair.secondary
            }
            shown.genre = genreAliases[album.genre] ?? album.genre
            return shown
        }
        let allTracks = albums.flatMap(\.tracks)
        let byRecency: (Album, Album) -> Bool = { $0.addedRank == $1.addedRank ? $0.title < $1.title : $0.addedRank > $1.addedRank }
        let genres = Dictionary(grouping: albums, by: \.genre)
            .map { Genre(name: $0.key, albums: $0.value.sorted(by: byRecency)) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return DerivedLibrary(
            sourceID: catalogue.driveID,
            albums: albums,
            albumsByID: Dictionary(uniqueKeysWithValues: albums.map { ($0.id, $0) }),
            tracksByID: Dictionary(allTracks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }),
            allTracks: allTracks,
            albumSearchKeys: albums.map { ($0.title + " " + $0.artist).lowercased() },
            trackSearchKeys: allTracks.map { $0.title.lowercased() },
            artists: Dictionary(grouping: albums, by: \.artist)
                .map { Artist(name: $0.key, albums: $0.value.sorted { $0.year < $1.year }) }
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            genres: genres,
            genreShelves: Array(
                genres
                    .filter { $0.albums.count >= 2 && $0.name != "Unknown genre" }
                    .sorted { $0.albums.count == $1.albums.count ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending : $0.albums.count > $1.albums.count }
                    .prefix(8)
            ),
            decades: Dictionary(grouping: albums.filter { $0.year > 0 }, by: { $0.year / 10 * 10 })
                .map { Decade(label: "\($0.key)s", albums: $0.value.sorted { $0.year < $1.year }) }
                .sorted { $0.label < $1.label },
            hiResAlbums: albums.filter(\.isHiRes),
            recentlyAdded: albums.sorted(by: byRecency),
            coveredAlbumIDs: covered,
            palettes: palettes,
            folderRoot: includeFolders ? catalogue.folderTree() : nil
        )
    }
}

/// Artists, albums and songs whose names contain a query.
public nonisolated struct SearchResults: Sendable {
    public var artists: [Artist] = []
    public var albums: [Album] = []
    public var tracks: [Track] = []
    public var isEmpty: Bool { artists.isEmpty && albums.isEmpty && tracks.isEmpty }

    public init() {}
}

/// Holds the indexed catalogue plus everything derived from it, and reaches the drive for media.
@Observable
public final class LibraryStore {
    public private(set) var catalogue: Catalogue = .empty

    public init() {}
    public var drive: (any RemoteDrive)?

    public private(set) var albums: [Album] = []
    /// Changes once a complete set of derived catalogue content is published, never for scan progress.
    public private(set) var contentRevision = 0
    /// The NAS whose derived rows are on screen. A replacement catalogue can be waiting for its
    /// background derivation, so its source must not be assigned to the preceding source's rows.
    public private(set) var contentSourceID: String?
    public private(set) var artists: [Artist] = []
    public private(set) var genres: [Genre] = []
    /// Genres with enough albums to deserve a shelf on the Library home, most albums first.
    public private(set) var genreShelves: [Genre] = []
    public private(set) var decades: [Decade] = []
    public private(set) var hiResAlbums: [Album] = []
    public private(set) var recentlyAdded: [Album] = []
    public private(set) var folderRoot = FolderNode(name: "music", path: "", subfolders: [], tracks: [])
    private var albumsByID: [String: Album] = [:]
    private var tracksByID: [String: Track] = [:]
    private var allTracks: [Track] = []
    private var albumSearchKeys: [String] = []
    private var trackSearchKeys: [String] = []
    private var coveredAlbumIDs: Set<String> = []
    /// Colours read from the covers on disk, by album id.
    private var palettes: [String: CoverPalette.Pair] = [:]
    /// Counts derivations started, so a slow one never overwrites a newer result.
    private var derivationGeneration = 0
    @ObservationIgnored private(set) var derivationTask: Task<Void, Never>?
    /// The people using the app; the active one's favourites, playlists, history and settings are what this store shows.
    public var profiles: ProfileStore?
    /// Shows "#3" instead of "#3 (Deluxe Version)" and "Song" instead of "Song (Remix)"; grouping still uses full titles.
    public var hidesBracketedTitleParts = false {
        didSet {
            guard hidesBracketedTitleParts != oldValue else { return }
            profiles?.updateSettings { $0.hidesBracketedTitleParts = hidesBracketedTitleParts }
            rebuildDerived()
        }
    }

    /// Genre tags shown under another name, e.g. "Religiös" → "Religious", so one style tagged in two languages is one genre.
    public private(set) var genreAliases: [String: String] = [:]

    public private(set) var recentlyPlayedIDs: [String] = []
    public private(set) var recentSearches: [String] = []
    private var localPlaylists: [LocalPlaylist] = []
    public private(set) var favouriteTrackIDs: [String] = []
    /// The last songs that started playing, most recent first.
    public private(set) var playedTrackIDs: [String] = []
    private var shuffleDay = ""
    private var shuffleCache: [Track] = []

    // Playlists are kept ready rather than rebuilt by every screen that shows them; the favourites
    // mix in particular scores the whole library.
    public private(set) var favouritesPlaylist = Playlist(id: Playlist.favouritesID, name: "Favourites", summary: "0 songs", covers: [], tracks: [], kind: .smart)
    public private(set) var favouritesMixPlaylist = Playlist(id: Playlist.favouritesMixID, name: "Favourites mix", summary: "0 songs", covers: [], tracks: [], kind: .smart)
    public private(set) var recentlyPlayedPlaylist = Playlist(id: Playlist.recentlyPlayedID, name: "Recently played", summary: "0 songs", covers: [], tracks: [], kind: .smart)
    public private(set) var playlists: [Playlist] = []

    /// The built-in sample catalogue rather than a drive.
    public var isDemo: Bool { catalogue.driveID.isEmpty && !catalogue.isEmpty }
    /// A drive catalogue whose drive isn't signed in right now.
    public var isOffline: Bool { drive == nil && !isDemo && !catalogue.isEmpty }
    public var isEmpty: Bool { catalogue.isEmpty }

    // MARK: Catalogue

    public func replace(with catalogue: Catalogue, drive: (any RemoteDrive)?) {
        let previous = self.catalogue
        let firstLoad = albums.isEmpty
        let driveChanged = catalogue.driveID != previous.driveID
        let sameAlbums = !firstLoad && !driveChanged && catalogue.albums == previous.albums
        self.catalogue = catalogue
        self.drive = drive
        if firstLoad || driveChanged {
            genreAliases = UserDefaults.standard.dictionary(forKey: Self.genreAliasesKey(for: catalogue.driveID)) as? [String: String] ?? [:]
            loadProfileState()
        }
        if firstLoad || catalogue.isEmpty {
            // The first catalogue is derived right away so the library is there on the first frame.
            // Clearing or changing the library must also supersede work still deriving its old contents.
            derivationGeneration &+= 1
            derivationTask?.cancel()
            derivationTask = nil
            apply(DerivedLibrary.make(catalogue: catalogue, hidesBrackets: hidesBracketedTitleParts, genreAliases: genreAliases, knownPalettes: palettes, includeFolders: true))
        } else {
            // Later catalogues (refreshes, tags settling) are derived in the background so the screen
            // never waits; when nothing changed only the cover index is looked at again.
            rebuildDerivedInBackground(includeFolders: !sameAlbums)
        }
    }

    /// Takes the active profile's favourites, plays, playlists, searches and bracket setting for this library.
    public func loadProfileState() {
        let saved = profiles?.libraryState(for: catalogue.driveID) ?? LibraryState()
        favouriteTrackIDs = saved.favourites
        playedTrackIDs = saved.played
        localPlaylists = saved.playlists
        recentlyPlayedIDs = saved.recentAlbums
        recentSearches = saved.searches
        shuffleDay = ""
        rebuildPlaylists()
        let hides = profiles?.state.settings.hidesBracketedTitleParts ?? false
        if hides != hidesBracketedTitleParts { hidesBracketedTitleParts = hides }
    }

    /// Recomputes everything derived from the catalogue off the main thread and applies what changed.
    private func rebuildDerived() {
        rebuildDerivedInBackground(includeFolders: false)
    }

    private func rebuildDerivedInBackground(includeFolders: Bool) {
        derivationGeneration &+= 1
        derivationTask?.cancel()
        let generation = derivationGeneration
        let catalogue = self.catalogue
        let hides = hidesBracketedTitleParts
        let aliases = genreAliases
        let known = palettes
        derivationTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let started = ContinuousClock.now
            let derived = await Task.detached(priority: .userInitiated) {
                DerivedLibrary.make(catalogue: catalogue, hidesBrackets: hides, genreAliases: aliases, knownPalettes: known, includeFolders: includeFolders)
            }.value
            guard let self, !Task.isCancelled, generation == derivationGeneration else { return }
            apply(derived)
            let elapsed = started.duration(to: .now)
            if elapsed > .milliseconds(150) {
                diagnostics("Library derived in \(elapsed.formatted(.units(allowed: [.milliseconds], width: .narrow)))")
            }
        }
    }

    /// Stores the derived data, touching only what actually changed so screens showing the rest stay put.
    private func apply(_ derived: DerivedLibrary) {
        let sourceChanged = contentSourceID != derived.sourceID
        let albumsChanged = albums != derived.albums
        if albumsChanged || sourceChanged {
            albums = derived.albums
            albumsByID = derived.albumsByID
            tracksByID = derived.tracksByID
            allTracks = derived.allTracks
            albumSearchKeys = derived.albumSearchKeys
            trackSearchKeys = derived.trackSearchKeys
            hiResAlbums = derived.hiResAlbums
            recentlyAdded = derived.recentlyAdded
            if artists != derived.artists { artists = derived.artists }
            if genres != derived.genres { genres = derived.genres }
            if genreShelves != derived.genreShelves { genreShelves = derived.genreShelves }
            if decades != derived.decades { decades = derived.decades }
            recentlyPlayedIDs = recentlyPlayedIDs.filter { albumsByID[$0] != nil }
        }
        if coveredAlbumIDs != derived.coveredAlbumIDs { coveredAlbumIDs = derived.coveredAlbumIDs }
        if palettes != derived.palettes { palettes = derived.palettes }
        if let root = derived.folderRoot { folderRoot = root }
        if sourceChanged { contentSourceID = derived.sourceID }
        if albumsChanged || sourceChanged {
            shuffleDay = ""
            rebuildPlaylists()
            contentRevision &+= 1
        }
        let unread = coveredAlbumIDs.subtracting(palettes.keys)
        if !unread.isEmpty { readPalettes(for: unread) }
    }

    /// Reads colours for covers saved before palettes existed, off the main thread, then refreshes the albums.
    private func readPalettes(for albumIDs: Set<String>) {
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { CoverStore.computePalettes(for: albumIDs) }.value
            guard let self, !found.isEmpty else { return }
            palettes.merge(found) { _, new in new }
            rebuildDerived()
        }
    }

    // MARK: Genre names

    /// Shows every album whose genre currently reads `name` under `newName` instead. Picking the name
    /// of another genre merges the two; typing a tag's original name undoes its rename.
    public func renameGenre(_ name: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != name else { return }
        let tags = Set(catalogue.albums.map(\.genre)).filter { (genreAliases[$0] ?? $0) == name }
        for tag in tags {
            genreAliases[tag] = tag == trimmed ? nil : trimmed
        }
        saveGenreAliases()
        rebuildDerived()
        diagnostics("Genre “\(name)” now shows as “\(trimmed)” (\(tags.count) tags)")
    }

    /// Every renamed tag with the name it shows under, alphabetically.
    public var genreRenames: [(tag: String, name: String)] {
        genreAliases.sorted { $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }.map { (tag: $0.key, name: $0.value) }
    }

    /// Shows the tag under its original name again.
    public func resetGenre(tag: String) {
        genreAliases[tag] = nil
        saveGenreAliases()
        rebuildDerived()
    }

    public func resetGenreNames() {
        genreAliases = [:]
        saveGenreAliases()
        rebuildDerived()
    }

    private static func genreAliasesKey(for driveID: String) -> String { "genreAliases.\(driveID)" }

    private func saveGenreAliases() {
        UserDefaults.standard.set(genreAliases, forKey: Self.genreAliasesKey(for: catalogue.driveID))
    }

    /// Demo mode starts with the design's play history.
    public func seedDemoHistory() {
        recentlyPlayedIDs = SampleLibrary.recentlyPlayedIDs
        recentSearches = SampleLibrary.recentSearches
    }

    public func album(id: String) -> Album? { albumsByID[id] }
    public func album(for track: Track) -> Album? { albumsByID[track.albumID] }
    public func track(id: String) -> Track? { tracksByID[id] }
    /// Catalogue order, prepared with the other derived content rather than flattened by each screen.
    public var tracks: [Track] { allTracks }
    public func artist(named name: String) -> Artist? { artists.first { $0.name == name } }

    public var recentlyPlayed: [Album] { recentlyPlayedIDs.compactMap { albumsByID[$0] } }

    /// Remembers a song that started playing, for the Recently played list (last 100, newest first).
    public func notePlayed(_ track: Track) {
        playedTrackIDs.removeAll { $0 == track.id }
        playedTrackIDs.insert(track.id, at: 0)
        playedTrackIDs = Array(playedTrackIDs.prefix(100))
        profiles?.updateLibrary(catalogue.driveID, recordingHistory: .played) { $0.played = playedTrackIDs }
        recentlyPlayedPlaylist = smartPlaylist(id: Playlist.recentlyPlayedID, name: "Recently played", tracks: recentlyPlayedTracks)
    }

    public var recentlyPlayedTracks: [Track] { playedTrackIDs.compactMap { tracksByID[$0] } }

    /// Fifty songs from across the library, chosen again each day.
    public var libraryShuffle: [Track] {
        let day = Date.now.formatted(.iso8601.year().month().day())
        if day == shuffleDay, !shuffleCache.isEmpty { return shuffleCache }
        let all = allTracks
        guard !all.isEmpty else { return [] }
        var generator = SeededGenerator(seed: UInt64(truncatingIfNeeded: (day + catalogue.driveID).hashValue))
        var picks: [Track] = []
        var used = Set<Int>()
        let wanted = min(50, all.count)
        while picks.count < wanted {
            let index = Int(generator.next() % UInt64(all.count))
            if used.insert(index).inserted { picks.append(all[index]) }
        }
        shuffleDay = day
        shuffleCache = picks
        return picks
    }

    public func notePlayed(_ album: Album) {
        recentlyPlayedIDs.removeAll { $0 == album.id }
        recentlyPlayedIDs.insert(album.id, at: 0)
        recentlyPlayedIDs = Array(recentlyPlayedIDs.prefix(30))
        profiles?.updateLibrary(catalogue.driveID, recordingHistory: .recentAlbums) { $0.recentAlbums = recentlyPlayedIDs }
    }

    // MARK: Media

    public func coverURL(for album: Album) -> URL? {
        coveredAlbumIDs.contains(album.id) ? CoverStore.fileURL(for: album.id) : nil
    }

    public private(set) var coverVersions: [String: Int] = [:]

    /// A value that changes whenever the album's cover file is replaced, so views reload it.
    public func coverVersion(for album: Album) -> Int { coverVersions[album.id] ?? 0 }

    /// Throws away the cached cover and fetches it again from the album's own folder and files.
    public func refreshCover(for album: Album) async -> String {
        guard let drive else { return "Not connected to the server." }
        let sourceID = catalogue.driveID
        CoverStore.remove(for: album.id)
        coveredAlbumIDs.remove(album.id)
        palettes[album.id] = nil
        let chosen = await LibraryIndexer.fetchCover(for: album, drive: drive)
        guard !Task.isCancelled, catalogue.driveID == sourceID, self.drive?.id == drive.id else {
            return "The library changed before the cover finished loading."
        }
        if let (data, source) = chosen {
            CoverStore.save(data, for: album.id)
            coveredAlbumIDs.insert(album.id)
            palettes[album.id] = CoverStore.palette(for: album.id)
            coverVersions[album.id, default: 0] += 1
            rebuildDerived()
            DiagnosticsLog.shared.record("Refreshed cover for “\(album.title)”: \(source)")
            return "Cover taken from \(source)"
        }
        coverVersions[album.id, default: 0] += 1
        rebuildDerived()
        DiagnosticsLog.shared.record("Refreshed cover for “\(album.title)”: nothing found")
        return "No folder image or embedded art was found for this album."
    }

    public func streamURL(for track: Track, quality: StreamQuality) -> URL? {
        guard let drive, let path = track.path else { return nil }
        return drive.streamURL(for: path)
    }

    // MARK: Search

    /// Artists, albums and songs whose names contain the query; matched against lowercased keys built with the library.
    public func searchResults(_ query: String) -> SearchResults {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return SearchResults() }
        var results = SearchResults()
        for artist in artists where artist.name.lowercased().contains(needle) {
            results.artists.append(artist)
            if results.artists.count == 20 { break }
        }
        for (album, key) in zip(albums, albumSearchKeys) where key.contains(needle) {
            results.albums.append(album)
            if results.albums.count == 30 { break }
        }
        for (track, key) in zip(allTracks, trackSearchKeys) where key.contains(needle) {
            results.tracks.append(track)
            if results.tracks.count == 50 { break }
        }
        return results
    }

    public func search(_ query: String) -> [Album] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        return albums.filter { album in
            [album.title, album.artist, album.genre, album.label ?? "", String(album.year)]
                .joined(separator: " ")
                .lowercased()
                .contains(needle)
        }
    }

    public func noteSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        recentSearches.removeAll { $0.caseInsensitiveCompare(trimmed) == .orderedSame }
        recentSearches.insert(trimmed, at: 0)
        recentSearches = Array(recentSearches.prefix(8))
        profiles?.updateLibrary(catalogue.driveID, recordingHistory: .searches) { $0.searches = recentSearches }
    }

    public var browseEntries: [BrowseEntry] {
        let years = albums.map(\.year).filter { $0 > 0 }
        let yearRange = years.isEmpty ? "—" : "\(years.min()!) – \(years.max()!)"
        let lossless = albums.filter { $0.quality == .lossless }.count
        return [
            BrowseEntry(label: "Artists", detail: artists.count.formatted(), facet: .artists),
            BrowseEntry(label: "Genres", detail: genres.count.formatted(), facet: .genres),
            BrowseEntry(label: "Years", detail: yearRange, facet: .recentlyAdded),
            BrowseEntry(label: "Lossless albums", detail: lossless.formatted(), facet: .recentlyAdded),
        ]
    }

    // MARK: Favourites

    public func isFavourite(_ track: Track) -> Bool { favouriteTrackIDs.contains(track.id) }

    public func toggleFavourite(_ track: Track) {
        if let index = favouriteTrackIDs.firstIndex(of: track.id) {
            favouriteTrackIDs.remove(at: index)
        } else {
            favouriteTrackIDs.append(track.id)
        }
        profiles?.updateLibrary(catalogue.driveID) { $0.favourites = favouriteTrackIDs }
        rebuildFavouritePlaylists()
    }

    public var favouriteTracks: [Track] { favouriteTrackIDs.compactMap { tracksByID[$0] } }

    /// Favourites interleaved with songs that resemble them: same album, artist, genre or decade.
    public var favouritesMix: [Track] {
        let favourites = favouriteTracks
        guard !favourites.isEmpty else { return [] }
        let favouriteIDs = Set(favourites.map(\.id))
        let favouriteAlbums = Set(favourites.map(\.albumID))
        let sourceAlbums = favourites.compactMap { albumsByID[$0.albumID] }
        let artists = Set(sourceAlbums.map { $0.artist.lowercased() })
        let genres = Set(sourceAlbums.map { $0.genre.lowercased() })
        let decades = Set(sourceAlbums.filter { $0.year > 0 }.map { $0.year / 10 })

        var candidates: [(Track, Double)] = []
        for album in albums {
            var score = 0.0
            if favouriteAlbums.contains(album.id) { score += 3 }
            if artists.contains(album.artist.lowercased()) { score += 2 }
            if genres.contains(album.genre.lowercased()) { score += 1 }
            if album.year > 0, decades.contains(album.year / 10) { score += 0.5 }
            guard score > 0 else { continue }
            let picks = album.tracks.filter { !favouriteIDs.contains($0.id) }
            let spread = stride(from: 0, to: picks.count, by: max(1, picks.count / 3)).prefix(3).map { picks[$0] }
            for track in spread { candidates.append((track, score)) }
        }
        candidates.sort { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 > $1.1 }
        var similar = candidates.map(\.0).prefix(max(24, favourites.count * 2)).makeIterator()
        var mix: [Track] = []
        for favourite in favourites {
            mix.append(favourite)
            if let next = similar.next() { mix.append(next) }
            if let next = similar.next() { mix.append(next) }
        }
        while let next = similar.next() { mix.append(next) }
        return mix
    }

    private func smartPlaylist(id: String, name: String, tracks: [Track]) -> Playlist {
        var covers: [Album] = []
        for track in tracks {
            if let album = albumsByID[track.albumID], !covers.contains(album) { covers.append(album) }
            if covers.count == 4 { break }
        }
        let duration = tracks.reduce(0) { $0 + $1.duration }
        let summary = "\(tracks.count) \(tracks.count == 1 ? "song" : "songs")" + (duration > 0 ? " · \(TimeText.long(duration))" : "")
        return Playlist(id: id, name: name, summary: summary, covers: covers, tracks: tracks, kind: .smart)
    }

    public var libraryShufflePlaylist: Playlist { smartPlaylist(id: Playlist.libraryShuffleID, name: "Library shuffle", tracks: libraryShuffle) }

    /// The live version of a playlist, since favourites and playlist contents change while a page is open.
    public func playlist(id: String) -> Playlist? {
        switch id {
        case Playlist.favouritesID: favouritesPlaylist
        case Playlist.favouritesMixID: favouritesMixPlaylist
        case Playlist.recentlyPlayedID: recentlyPlayedPlaylist
        case Playlist.libraryShuffleID: libraryShufflePlaylist
        default: playlists.first { $0.id == id }
        }
    }

    // MARK: Playlists

    private func rebuildPlaylists() {
        rebuildFavouritePlaylists()
        recentlyPlayedPlaylist = smartPlaylist(id: Playlist.recentlyPlayedID, name: "Recently played", tracks: recentlyPlayedTracks)
        rebuildLocalPlaylists()
    }

    private func rebuildFavouritePlaylists() {
        favouritesPlaylist = smartPlaylist(id: Playlist.favouritesID, name: "Favourites", tracks: favouriteTracks)
        favouritesMixPlaylist = smartPlaylist(id: Playlist.favouritesMixID, name: "Favourites mix", tracks: favouritesMix)
    }

    private func rebuildLocalPlaylists() {
        playlists = (isDemo ? SampleLibrary.playlists : []) + localPlaylists.map { local in
            let tracks = local.trackIDs.compactMap { tracksByID[$0] }
            var covers: [Album] = []
            for track in tracks {
                if let album = albumsByID[track.albumID], !covers.contains(album) { covers.append(album) }
                if covers.count == 4 { break }
            }
            let duration = tracks.reduce(0) { $0 + $1.duration }
            let summary = "\(tracks.count) \(tracks.count == 1 ? "song" : "songs")" + (duration > 0 ? " · \(TimeText.long(duration))" : "")
            return Playlist(id: local.id, name: local.name, summary: summary, covers: covers, tracks: tracks)
        }
    }

    @discardableResult
    public func createPlaylist(named name: String, tracks: [Track] = []) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let playlist = LocalPlaylist(id: UUID().uuidString, name: trimmed, trackIDs: tracks.map(\.id), created: .now)
        localPlaylists.insert(playlist, at: 0)
        saveLocalPlaylists()
        return playlist.id
    }

    public func add(_ tracks: [Track], toPlaylist id: String) {
        guard let index = localPlaylists.firstIndex(where: { $0.id == id }) else { return }
        for track in tracks where !localPlaylists[index].trackIDs.contains(track.id) {
            localPlaylists[index].trackIDs.append(track.id)
        }
        saveLocalPlaylists()
    }

    public func renamePlaylist(id: String, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = localPlaylists.firstIndex(where: { $0.id == id }) else { return }
        localPlaylists[index].name = trimmed
        saveLocalPlaylists()
    }

    public func remove(_ track: Track, fromPlaylist id: String) {
        guard let index = localPlaylists.firstIndex(where: { $0.id == id }) else { return }
        localPlaylists[index].trackIDs.removeAll { $0 == track.id }
        saveLocalPlaylists()
    }

    /// Removes selected visible occurrences, including when the same song appears more than once.
    /// Unavailable songs may be absent from the visible list, so translate positions back to the
    /// stored identifiers before editing. Out-of-range selections are ignored.
    public func removeEntries(at positions: IndexSet, fromPlaylist id: String) {
        guard !positions.isEmpty, let index = localPlaylists.firstIndex(where: { $0.id == id }) else { return }
        var visiblePosition = 0
        var changed = false
        localPlaylists[index].trackIDs = localPlaylists[index].trackIDs.filter { trackID in
            guard tracksByID[trackID] != nil else { return true }
            defer { visiblePosition += 1 }
            if positions.contains(visiblePosition) { changed = true; return false }
            return true
        }
        if changed { saveLocalPlaylists() }
    }

    public func deletePlaylist(id: String) {
        localPlaylists.removeAll { $0.id == id }
        saveLocalPlaylists()
    }

    public func isLocalPlaylist(_ id: String) -> Bool { localPlaylists.contains { $0.id == id } }

    private func saveLocalPlaylists() {
        profiles?.updateLibrary(catalogue.driveID) { $0.playlists = localPlaylists }
        rebuildLocalPlaylists()
    }

    // MARK: Persistence

    private static let cacheURL: URL = {
        let directory = AppDirectories.support
            .appending(path: "Skyr", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "catalogue.json")
    }()

    public static func loadCachedCatalogue() -> Catalogue? {
        guard let data = try? Data(contentsOf: cacheURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Catalogue.self, from: data)
    }

    public func saveCatalogue() {
        let snapshot = catalogue
        let url = Self.cacheURL
        Task.detached(priority: .utility) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            if let data = try? encoder.encode(snapshot) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    public static func deleteCache() {
        try? FileManager.default.removeItem(at: cacheURL)
        CoverStore.clear()
        CoverImageCache.shared.removeAll()
    }
}

/// Small deterministic generator so the daily shuffle is the same all day.
nonisolated private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
