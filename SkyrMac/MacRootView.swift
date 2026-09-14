import SkyrCore
import SwiftUI

struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        // Keep the split view at the root: wrapping it in a stack caused AppKit constraint re-entry.
        if model.stage == .ready, profiles.isLocked {
            ProfilePickerView().frame(minWidth: 900, minHeight: 560)
        } else if model.stage == .ready {
            MacMainView().frame(minWidth: 900, minHeight: 560)
        } else {
            MacSetupView()
        }
    }
}

/// Desktop navigation and playback stay in the window while content changes.
struct MacMainView: View {
    @Environment(MacNavigation.self) private var navigation
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @FocusState private var searchFocused: Bool
    @Namespace private var artworkNamespace

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            GeometryReader { _ in
                MacSidebar(selection: $navigation.selection).clearOfPlayerBar()
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            GeometryReader { _ in
                detail.frame(maxWidth: .infinity, maxHeight: .infinity).clearOfPlayerBar()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacPlayerBar { navigation.isShowingNowPlaying.toggle() }
        }
        .inspector(isPresented: $navigation.isShowingNowPlaying) {
            MacNowPlayingInspector()
                .inspectorColumnWidth(min: 260, ideal: 300, max: 380)
        }
        .searchable(text: $navigation.searchText, placement: .toolbar, prompt: "Search Library")
        .searchFocused($searchFocused)
        .onSubmit(of: .search) { library.noteSearch(navigation.searchText) }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button("New Playlist", systemImage: "plus") {
                    navigation.selection = .playlists
                    navigation.isNamingPlaylist = true
                }
                .help("Create a playlist (⌘N)")
                Button("Scan for New Music", systemImage: "arrow.clockwise") { model.rescan() }
                    .disabled(model.isScanning || model.connection == nil)
                    .help("Scan for new music (⌘R)")
                Button("Now Playing", systemImage: "sidebar.right") { navigation.isShowingNowPlaying.toggle() }
                    .help("Show or hide Now Playing (⇧⌘N)")
                Menu {
                    if let profile = profiles.active { Text(profile.name) }
                    Button("Switch Profile…", systemImage: "person.crop.circle") { profiles.lock() }
                    SettingsLink()
                } label: {
                    Image(systemName: "person.crop.circle")
                }
                .help("Profile and Settings")
            }
        }
        .onChange(of: navigation.searchText) { _, query in
            if !query.isEmpty, navigation.selection != .search { navigation.selection = .search }
        }
        .onChange(of: navigation.searchRequest) { _, _ in searchFocused = true }
        .onChange(of: navigation.selection, initial: true) { _, selection in
            if let facet = selection?.facet, model.facet != facet { model.facet = facet }
            if selection != .search {
                searchFocused = false
                navigation.searchText = ""
            }
            if selection != .albums { navigation.albumToOpen = nil }
        }
        .onChange(of: model.albumToOpen) { _, album in
            guard let album else { return }
            navigation.showAlbum(album)
            model.albumToOpen = nil
        }
        .onChange(of: model.playlistToOpen) { _, playlist in
            guard let playlist else { return }
            navigation.selection = .playlist(playlist.id)
            model.playlistToOpen = nil
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }

    @ViewBuilder private var detail: some View {
        switch navigation.selection ?? .recentlyAdded {
        case .recentlyAdded, .albums, .songs, .artists, .genres:
            MacLibraryView(section: navigation.selection ?? .recentlyAdded)
        case .playlists:
            MacPlaylistsView()
        case .playlist(let id):
            MacPlaylistPane(id: id)
        case .downloads:
            NavigationStack { MacDownloadsView().libraryDestinations() }
        case .search:
            MacSearchView()
        }
    }
}

struct MacSidebar: View {
    @Binding var selection: MacSection?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List(selection: $selection) {
            Label("Search", systemImage: "magnifyingglass").tag(MacSection.search)
            Section("Library") {
                Label("Recently Added", systemImage: "clock").tag(MacSection.recentlyAdded)
                Label("Albums", systemImage: "square.stack").tag(MacSection.albums)
                Label("Songs", systemImage: "music.note").tag(MacSection.songs)
                Label("Artists", systemImage: "music.microphone").tag(MacSection.artists)
                Label("Genres", systemImage: "guitars").tag(MacSection.genres)
                Label("Downloads", systemImage: "arrow.down.circle").tag(MacSection.downloads)
            }
            Section("Playlists") {
                Label("All Playlists", systemImage: "music.note.list").tag(MacSection.playlists)
                Label("Favourites", systemImage: "heart.fill").tag(MacSection.playlist(Playlist.favouritesID))
                Label("Favourites Mix", systemImage: "sparkles").tag(MacSection.playlist(Playlist.favouritesMixID))
                Label("Recently Played", systemImage: "clock.arrow.circlepath").tag(MacSection.playlist(Playlist.recentlyPlayedID))
                Label("Library Shuffle", systemImage: "shuffle").tag(MacSection.playlist(Playlist.libraryShuffleID))
                ForEach(library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list").tag(MacSection.playlist(playlist.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct MacPlaylistPane: View {
    let id: String
    @Environment(LibraryStore.self) private var library

    var body: some View {
        NavigationStack {
            if let playlist = library.playlist(id: id) {
                MacPlaylistDetailView(playlist: playlist).libraryDestinations()
            } else {
                ContentUnavailableView("Playlist Unavailable", systemImage: "music.note.list", description: Text("Select a playlist in the sidebar."))
            }
        }
        .id(id)
    }
}

private extension View {
    // AppKit columns don't receive the outer inset. Reserve the bar without changing column constraints.
    func clearOfPlayerBar() -> some View {
        safeAreaPadding(.bottom, MacPlayerBar.height).ignoresSafeArea(.container, edges: .bottom)
    }
}
