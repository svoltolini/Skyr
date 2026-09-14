import AppKit
import SkyrCore
import SwiftUI

/// The first-run connection flow, or the sidebar app with the player bar, and the profile picker
/// over either when nobody is signed in to a profile.
struct MacRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        // The split view must be the window's root: nested in a stack, AppKit re-enters its
        // constraint pass when a column's size changes and the app aborts. The profile picker
        // therefore replaces it rather than covering it, and owns the window while it is up.
        // Setup is a fixed assistant window; the app itself asks for a real window and grows it.
        if model.stage == .ready, profiles.isLocked {
            ProfilePickerView()
                .frame(minWidth: 980, minHeight: 620)
        } else if model.stage == .ready {
            MacMainView()
                .frame(minWidth: 980, minHeight: 620)
                .onAppear(perform: growWindow)
        } else {
            MacSetupView()
        }
    }

    /// The assistant's window is small; the library wants the app's usual size.
    private func growWindow() {
        guard let window = NSApp.windows.first(where: { $0.isVisible }), window.frame.width < 1200 else { return }
        var frame = window.frame
        let target = NSSize(width: 1240, height: 800)
        frame.origin.x -= (target.width - frame.width) / 2
        frame.origin.y -= (target.height - frame.height) / 2
        frame.size = target
        window.setFrame(frame, display: true, animate: true)
    }
}

/// Sidebar on the left, the chosen section on the right, the player across the bottom.
struct MacMainView: View {
    @Environment(MacNavigation.self) private var navigation
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var navigation = navigation
        NavigationSplitView {
            // A GeometryReader reports no minimum size of its own, so the column's constraints
            // never change while the sidebar's rows or the detail's pages do.
            GeometryReader { _ in
                MacSidebar(selection: $navigation.selection)
                    .clearOfPlayerBar()
            }
            .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            GeometryReader { _ in
                detail
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    // The phone's screens lean on the navigation bar for their top spacing; under a
                    // Mac toolbar the first header would sit against its edge.
                    .safeAreaPadding(.top, 16)
                    .clearOfPlayerBar()
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            MacPlayerBar { navigation.isShowingNowPlaying = true }
        }
        .sheet(isPresented: $navigation.isShowingNowPlaying) {
            NowPlayingView()
                .frame(width: 440, height: 780)
                .overlay(alignment: .topTrailing) {
                    Button("Close", systemImage: "xmark") { navigation.isShowingNowPlaying = false }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .keyboardShortcut(.cancelAction)
                        .padding(14)
                }
        }
        .onChange(of: navigation.selection, initial: true) { _, selection in
            if let facet = selection?.facet, model.facet != facet { model.facet = facet }
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch navigation.selection ?? .recentlyAdded {
        case .recentlyAdded, .artists, .genres:
            LibraryView()
        case .playlists:
            PlaylistsView()
        case .playlist(let id):
            MacPlaylistPane(id: id)
        case .downloads:
            DownloadsTabView()
        case .search:
            SearchView()
        }
    }
}

/// Library, then every playlist by name, so a list is one click away.
struct MacSidebar: View {
    @Binding var selection: MacSection?
    @Environment(LibraryStore.self) private var library

    var body: some View {
        List(selection: $selection) {
            Label("Search", systemImage: "magnifyingglass")
                .tag(MacSection.search)
            Section("Library") {
                Label("Recently Added", systemImage: "clock")
                    .tag(MacSection.recentlyAdded)
                Label("Artists", systemImage: "music.microphone")
                    .tag(MacSection.artists)
                Label("Genres", systemImage: "guitars")
                    .tag(MacSection.genres)
                Label("Downloads", systemImage: "arrow.down.circle")
                    .tag(MacSection.downloads)
            }
            Section("Playlists") {
                Label("All Playlists", systemImage: "square.grid.2x2")
                    .tag(MacSection.playlists)
                Label(library.favouritesPlaylist.name, systemImage: "heart.fill")
                    .tag(MacSection.playlist(library.favouritesPlaylist.id))
                Label(library.favouritesMixPlaylist.name, systemImage: "sparkles")
                    .tag(MacSection.playlist(library.favouritesMixPlaylist.id))
                Label(library.recentlyPlayedPlaylist.name, systemImage: "clock.arrow.circlepath")
                    .tag(MacSection.playlist(library.recentlyPlayedPlaylist.id))
                Label(library.libraryShufflePlaylist.name, systemImage: "shuffle")
                    .tag(MacSection.playlist(library.libraryShufflePlaylist.id))
                ForEach(library.playlists) { playlist in
                    Label(playlist.name, systemImage: "music.note.list")
                        .tag(MacSection.playlist(playlist.id))
                }
            }
        }
        .listStyle(.sidebar)
    }
}

/// One playlist as the detail column, with albums and artists pushed on top of it.
struct MacPlaylistPane: View {
    let id: String
    @Environment(LibraryStore.self) private var library
    @Namespace private var artworkNamespace

    private var playlist: Playlist? {
        let smart = [library.favouritesPlaylist, library.favouritesMixPlaylist, library.recentlyPlayedPlaylist, library.libraryShufflePlaylist]
        return (smart + library.playlists).first { $0.id == id }
    }

    var body: some View {
        NavigationStack {
            if let playlist {
                PlaylistDetailView(playlist: playlist)
                    .libraryDestinations()
            } else {
                EmptyStateView(title: "Playlist Gone", systemImage: "music.note.list", message: "This playlist was deleted.")
            }
        }
        .id(id)
        .environment(\.artworkNamespace, artworkNamespace)
    }
}

/// The Settings window: the same groups as on the phone, with Family and Profiles pushed inside it.
struct MacSettingsView: View {
    @Namespace private var artworkNamespace

    var body: some View {
        NavigationStack {
            SettingsView()
                .libraryDestinations()
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }
}

private extension View {
    /// The columns are AppKit views that never see the split view's safe-area inset, so the player
    /// bar would cover their last rows. Give them exactly the bar's height at the bottom instead.
    func clearOfPlayerBar() -> some View {
        safeAreaPadding(.bottom, MacPlayerBar.height)
            .ignoresSafeArea(.container, edges: .bottom)
    }
}
