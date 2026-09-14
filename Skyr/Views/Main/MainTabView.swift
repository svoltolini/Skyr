import SkyrCore
import SwiftUI

/// Library, Playlists and Search tabs with the mini player docked above the tab bar.
struct MainTabView: View {
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.colorScheme) private var colorScheme
    @State private var isShowingNowPlaying = false

    var body: some View {
        @Bindable var model = model
        TabView(selection: $model.selectedTab) {
            Tab("Library", systemImage: "square.stack.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab("Playlists", systemImage: "music.note.list", value: AppTab.playlists) {
                PlaylistsView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: AppTab.downloads) {
                DownloadsTabView()
            }
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsTabView()
            }
            Tab("Search", systemImage: "magnifyingglass", value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .adaptiveTabs()
        .tabBarMinimizeBehavior(.onScrollDown)
        // Pin the tab bar and its accessory to the app's own light or dark look. Left to itself, the glass
        // flips its label colour to match whatever scrolls underneath, which can leave white text on a
        // pale bar while a dark cover passes by.
        .toolbarColorScheme(colorScheme, for: .tabBar)
        .tabViewBottomAccessory(isEnabled: player.hasTrack) {
            MiniPlayerView {
                isShowingNowPlaying = true
            }
            // The accessory resolves its own scheme from the glass; keep its text on the app's scheme too.
            .environment(\.colorScheme, colorScheme)
        }
        // A plain sheet on purpose: a zoom out of the mini player crashes, because the tab bar
        // accessory is not always in the view hierarchy when the sheet comes back down.
        .sheet(isPresented: $isShowingNowPlaying) {
            NowPlayingView()
                .nowPlayingSheetSize()
        }
    }
}

private extension View {
    /// An iPad shows the player as a tall page sheet with room for the cover; a phone sheet fills the screen anyway.
    @ViewBuilder func nowPlayingSheetSize() -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            presentationSizing(.page)
        } else {
            self
        }
    }

    /// On an iPad the tab bar sits at the top and can fold out into a sidebar; the phone keeps its bar.
    @ViewBuilder func adaptiveTabs() -> some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            tabViewStyle(.sidebarAdaptable)
        } else {
            self
        }
    }
}
