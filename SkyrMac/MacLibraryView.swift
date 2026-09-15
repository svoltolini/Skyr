import SkyrCore
import SwiftUI

/// Each sidebar section owns a desktop navigation stack and returns to its root when reselected.
struct MacLibraryView: View {
    let section: MacSection
    @Environment(LibraryStore.self) private var library
    @Environment(MacNavigation.self) private var navigation
    @Environment(ProfileStore.self) private var profiles
    @State private var songs: [TrackListEntry] = []
    @State private var artists: [Artist] = []
    @State private var genres: [Genre] = []
    @State private var decades: [Decade] = []
    @State private var recentlyAdded: [Album] = []
    @State private var allAlbums: [Album] = []
    @State private var editingGenre: MacGenreEdit?

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            Group {
                switch section {
                case .songs:
                    MacTrackTable(entries: songs, title: "Songs")
                        .onChange(of: library.contentRevision, initial: true) { _, _ in songs = TrackListEntry.make(from: library.tracks) }
                case .artists:
                    MacArtistsList(artists: artists)
                        .onChange(of: library.contentRevision, initial: true) { _, _ in artists = library.artists }
                case .genres:
                    MacGenresList(genres: genres, decades: decades, library: library, profiles: profiles, editingGenre: $editingGenre)
                        .onChange(of: library.contentRevision, initial: true) { _, _ in
                            genres = library.genres
                            decades = library.decades
                        }
                case .recentlyAdded:
                    ScrollView { MacAlbumGrid(albums: recentlyAdded) }
                        .onChange(of: library.contentRevision, initial: true) { _, _ in recentlyAdded = library.recentlyAdded }
                default:
                    ScrollView { MacAlbumGrid(albums: allAlbums) }
                        .onChange(of: library.contentRevision, initial: true) { _, _ in allAlbums = library.albums }
                }
            }
            .overlay {
                if library.isEmpty {
                    ContentUnavailableView("Your Music Library", systemImage: "music.note", description: Text("Scan your music folder to find albums and songs. You can change the folder in Settings."))
                }
            }
            .navigationTitle(title)
            .navigationSubtitle(library.catalogue.summary)
            .libraryDestinations()
            .navigationDestination(item: $navigation.albumToOpen) { MacAlbumDetailView(album: $0) }
        }
        .sheet(item: $editingGenre) { edit in
            GenreEditorSheet(genre: edit.genre, isContextCurrent: {
                edit.scope.isCurrent(library: library, profiles: profiles) && library.genres.contains(edit.genre)
            })
            .frame(minWidth: 420, minHeight: 380)
        }
        .onChange(of: MacLibraryActionScope(library: library, profiles: profiles)) { _, _ in editingGenre = nil }
        .id(MacLibraryIdentity(section: section, request: navigation.albumRequest))
    }

    private var title: String {
        switch section {
        case .recentlyAdded: "Recently Added"
        case .songs: "Songs"
        case .artists: "Artists"
        case .genres: "Genres"
        default: "Albums"
        }
    }
}

private struct MacGenreEdit: Identifiable {
    let id = UUID()
    let genre: Genre
    let scope: MacLibraryActionScope
}

private struct MacLibraryIdentity: Hashable {
    let section: MacSection
    let request: UUID
}

/// Virtualized artist rows that only re-render when the cached artists array changes.
private struct MacArtistsList: View {
    let artists: [Artist]

    var body: some View {
        List(artists) { artist in
            NavigationLink(value: artist) {
                Label {
                    HStack {
                        Text(artist.name)
                        Spacer()
                        Text("\(artist.albums.count.formatted()) albums").foregroundStyle(.secondary)
                    }
                } icon: { Image(systemName: "person.crop.circle") }
            }
        }
        .listStyle(.inset)
    }
}

/// Genres and decades list that only re-renders when the cached arrays change.
private struct MacGenresList: View {
    let genres: [Genre]
    let decades: [Decade]
    let library: LibraryStore
    let profiles: ProfileStore
    @Binding var editingGenre: MacGenreEdit?

    var body: some View {
        let scope = MacLibraryActionScope(library: library, profiles: profiles)
        List {
            Section("Genres") {
                ForEach(genres) { genre in
                    NavigationLink(value: AlbumCollection(title: genre.name, albums: genre.albums)) {
                        HStack {
                            Label(genre.name, systemImage: "guitars")
                            Spacer()
                            Text(genre.countText).foregroundStyle(.secondary)
                        }
                    }
                    .contextMenu {
                        Button("Rename or Merge Genre…", systemImage: "pencil") {
                            guard scope.isCurrent(library: library, profiles: profiles), library.genres.contains(genre) else { return }
                            editingGenre = MacGenreEdit(genre: genre, scope: scope)
                        }
                    }
                }
            }
            if !decades.isEmpty {
                Section("Decades") {
                    ForEach(decades) { decade in
                        NavigationLink(value: AlbumCollection(title: decade.label, albums: decade.albums)) {
                            HStack {
                                Label(decade.label, systemImage: "calendar")
                                Spacer()
                                Text(decade.countText).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .listStyle(.inset)
    }
}

/// Artwork remains the focus of album browsing, at a density suited to a desktop window.
struct MacAlbumGrid: View {
    let albums: [Album]
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    private let columns = [GridItem(.adaptive(minimum: 140, maximum: 190), spacing: 20, alignment: .top)]

    var body: some View {
        let actionScope = MacLibraryActionScope(library: library, profiles: profiles)
        LazyVGrid(columns: columns, alignment: .leading, spacing: 24) {
            ForEach(albums) { album in
                NavigationLink(value: album) {
                    VStack(alignment: .leading, spacing: 5) {
                        ArtworkView(album: album, cornerRadius: 6, highlight: false)
                            .aspectRatio(1, contentMode: .fit)
                            .padding(.bottom, 3)
                        Text(album.title).font(.headline).lineLimit(2)
                        Text(album.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Play Album", systemImage: "play.fill") {
                        guard actionScope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                        player.play(album: album)
                    }
                    Button("Shuffle Album", systemImage: "shuffle") {
                        guard actionScope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                        player.play(queue: album.tracks.shuffled(), title: album.title)
                    }
                }
                .accessibilityLabel("\(album.title), \(album.artist)")
            }
        }
        .padding(20)
        .disabled(!actionScope.isCurrent(library: library, profiles: profiles))
    }
}

struct MacPlaylistsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(MacNavigation.self) private var navigation
    @State private var name = ""

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            List {
                Section("Made for You") {
                    playlistRow(library.favouritesPlaylist, symbol: "heart.fill")
                    playlistRow(library.favouritesMixPlaylist, symbol: "sparkles")
                    playlistRow(library.recentlyPlayedPlaylist, symbol: "clock.arrow.circlepath")
                    playlistRow(library.libraryShufflePlaylist, symbol: "shuffle")
                }
                Section("Your Playlists") {
                    ForEach(library.playlists) { playlist in playlistRow(playlist, symbol: "music.note.list") }
                    Button("New Playlist…", systemImage: "plus") { name = ""; navigation.isNamingPlaylist = true }
                }
            }
            .listStyle(.inset)
            .navigationTitle("Playlists")
            .libraryDestinations()
        }
        .alert("New Playlist", isPresented: $navigation.isNamingPlaylist) {
            TextField("Name", text: $name)
            Button("Create") {
                if let id = library.createPlaylist(named: name) { navigation.selection = .playlist(id) }
            }
            .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) { name = "" }
        } message: { Text("Give your playlist a name.") }
    }

    private func playlistRow(_ playlist: Playlist, symbol: String) -> some View {
        NavigationLink(value: playlist) {
            HStack(spacing: 12) {
                Image(systemName: symbol).frame(width: 24).foregroundStyle(.secondary)
                Text(playlist.name)
                Spacer()
                Text(playlist.summary).foregroundStyle(.secondary)
            }
            .padding(.vertical, 4)
        }
    }
}

private enum MacSearchScope: String, CaseIterable, Identifiable {
    case songs = "Songs", albums = "Albums", artists = "Artists"
    var id: Self { self }
}

private nonisolated struct MacSearchRequest: Equatable {
    let text: String
    let revision: Int
    let source: String
}

struct MacSearchView: View {
    @Environment(MacNavigation.self) private var navigation
    @Environment(LibraryStore.self) private var library
    @State private var results = SearchResults()
    @State private var entries: [TrackListEntry] = []
    @State private var scope: MacSearchScope = .songs
    @State private var path = NavigationPath()
    @State private var completedQuery = ""

    private var query: String { navigation.searchText.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var scopeIsEmpty: Bool {
        switch scope {
        case .songs: results.tracks.isEmpty
        case .albums: results.albums.isEmpty
        case .artists: results.artists.isEmpty
        }
    }

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                if query.isEmpty {
                    List {
                        Section("Recent Searches") {
                            if library.recentSearches.isEmpty {
                                Text("Search for a song, artist or album using the toolbar.").foregroundStyle(.secondary)
                            }
                            ForEach(library.recentSearches, id: \.self) { text in
                                Button { navigation.searchText = text; navigation.focusSearch() } label: {
                                    Label(text, systemImage: "clock")
                                }
                            }
                        }
                    }
                    .listStyle(.inset)
                } else {
                    Picker("Search results", selection: $scope) {
                        Text("Songs (\(results.tracks.count.formatted()))").tag(MacSearchScope.songs)
                        Text("Albums (\(results.albums.count.formatted()))").tag(MacSearchScope.albums)
                        Text("Artists (\(results.artists.count.formatted()))").tag(MacSearchScope.artists)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 520)
                    .padding(16)
                    Divider()
                    if completedQuery != query {
                        ProgressView("Searching…").frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if scopeIsEmpty {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        switch scope {
                        case .songs: MacTrackTable(entries: entries, title: "Search Results")
                        case .albums: ScrollView { MacAlbumGrid(albums: results.albums) }
                        case .artists:
                            List(results.artists) { artist in
                                NavigationLink(value: artist) { Label(artist.name, systemImage: "person.crop.circle") }
                            }
                            .listStyle(.inset)
                        }
                    }
                }
            }
            .navigationTitle("Search")
            .libraryDestinations()
        }
        .onChange(of: navigation.searchText) { _, _ in path = NavigationPath() }
        .onChange(of: navigation.searchRequest) { _, _ in path = NavigationPath() }
        .task(id: MacSearchRequest(text: navigation.searchText, revision: library.contentRevision, source: library.catalogue.driveID)) {
            do { try await Task.sleep(for: .milliseconds(120)) } catch { return }
            guard !Task.isCancelled else { return }
            results = library.searchResults(navigation.searchText)
            entries = TrackListEntry.make(from: results.tracks)
            if scopeIsEmpty {
                if !results.tracks.isEmpty { scope = .songs }
                else if !results.albums.isEmpty { scope = .albums }
                else if !results.artists.isEmpty { scope = .artists }
            }
            completedQuery = query
        }
    }
}
