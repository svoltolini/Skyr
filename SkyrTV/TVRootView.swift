import SkyrCore
import SwiftUI

/// The first-run connection flow, then the tabs, with the profile picker over either until someone is in.
struct TVRootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        ZStack {
            if model.stage == .ready {
                TVMainView()
                    .allowsHitTesting(!profiles.isLocked)
                    .accessibilityHidden(profiles.isLocked)
                    .transition(.opacity)
            } else {
                ConnectFlowView()
                    .transition(.opacity)
            }
            if model.stage == .ready, profiles.isLocked {
                ProfilePickerView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.stage == .ready)
        .animation(.easeInOut(duration: 0.35), value: profiles.isLocked)
    }
}

enum TVTab: Hashable {
    case library, playlists, nowPlaying, settings, search
}

/// The television's tabs along the top. Now Playing appears once something plays, as in Music.
struct TVMainView: View {
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(AppModel.self) private var model
    @State private var tab: TVTab = .library

    /// `--tab playlists` and friends open a tab straight away while developing.
    private static var initialTab: TVTab {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--tab"), index + 1 < arguments.count else { return .library }
        switch arguments[index + 1] {
        case "playlists": return .playlists
        case "settings": return .settings
        case "search": return .search
        case "nowplaying": return .nowPlaying
        default: return .library
        }
    }

    var body: some View {
        TabView(selection: $tab) {
            Tab("Library", systemImage: "square.stack.fill", value: TVTab.library) {
                LibraryView()
            }
            Tab("Playlists", systemImage: "music.note.list", value: TVTab.playlists) {
                PlaylistsView()
            }
            if player.hasTrack {
                Tab("Now Playing", systemImage: "music.note", value: TVTab.nowPlaying) {
                    TVNowPlayingView()
                }
            }
            Tab("Settings", systemImage: "gearshape.fill", value: TVTab.settings) {
                SettingsTabView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: TVTab.search, role: .search) {
                SearchView()
            }
        }
        .onChange(of: model.albumNavigationRequest) { _, _ in
            tab = .library
        }
        .task {
            // Development shortcuts, applied once the tabs exist: `--play` starts the first album,
            // `--tab playlists` and friends open a tab.
            let arguments = ProcessInfo.processInfo.arguments
            if arguments.contains("--play"), player.track == nil {
                while library.albums.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                player.play(album: library.albums[0])
                try? await Task.sleep(for: .milliseconds(300))
            }
            if Self.initialTab != .library {
                try? await Task.sleep(for: .milliseconds(300))
                tab = Self.initialTab
            }
            if arguments.contains("--album") {
                while library.albums.isEmpty { try? await Task.sleep(for: .milliseconds(100)) }
                try? await Task.sleep(for: .milliseconds(500))
                model.showAlbum(library.albums[0])
            }
        }
    }
}

/// The full-screen player: the shared Now Playing screen with room around it for the ten-foot view.
struct TVNowPlayingView: View {
    @Environment(PlayerModel.self) private var player

    var body: some View {
        NowPlayingView()
            .padding(.horizontal, 160)
            .padding(.vertical, 40)
            .skyrBackground(player.tint)
    }
}
