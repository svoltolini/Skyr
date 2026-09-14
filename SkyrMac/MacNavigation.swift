import SkyrCore
import SwiftUI

/// Desktop sidebar destinations; selecting another section returns to its own collection root.
enum MacSection: Hashable {
    case search
    case recentlyAdded
    case albums
    case songs
    case artists
    case genres
    case downloads
    case playlists
    case playlist(String)

    var facet: LibraryFacet? {
        switch self {
        case .recentlyAdded: .recentlyAdded
        case .artists: .artists
        case .genres: .genres
        default: nil
        }
    }

    var detailIdentity: String {
        switch self {
        case .recentlyAdded, .albums, .songs, .artists, .genres: "library"
        case .search: "search"
        case .downloads: "downloads"
        case .playlists: "playlists"
        case .playlist(let id): "playlist-\(id)"
        }
    }
}

/// The sidebar selection, shared with the menu bar so ⌘1 to ⌘5 and ⌘F land in the same place.
@Observable
final class MacNavigation {
    var selection: MacSection? = .recentlyAdded
    var isShowingNowPlaying = false
    var searchText = ""
    var searchRequest = UUID()
    var isNamingPlaylist = false
    var albumToOpen: Album?
    var albumRequest = UUID()
    private var scope: MacNavigationScope?

    func synchronizeScope(profileID: String?, sessionID: UUID?, sourceID: String) {
        let next = MacNavigationScope(profileID: profileID, sessionID: sessionID, sourceID: sourceID)
        guard scope != next else { return }
        scope = next
        selection = .recentlyAdded
        albumToOpen = nil
        albumRequest = UUID()
        searchText = ""
        isNamingPlaylist = false
        isShowingNowPlaying = false
    }

    func showAlbum(_ album: Album) {
        selection = .albums
        albumRequest = UUID()
        albumToOpen = album
    }

    func focusSearch() {
        selection = .search
        searchRequest = UUID()
    }
}

nonisolated struct MacNavigationScope: Equatable {
    let profileID: String?
    let sessionID: UUID?
    let sourceID: String
}

/// The menu bar: playback, library and view shortcuts.
struct MacCommands: Commands {
    let navigation: MacNavigation
    let player: PlayerModel
    let model: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button(player.isPlaying ? "Pause" : "Play", systemImage: "playpause.fill") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
                .disabled(!player.hasTrack)
            Button("Next", systemImage: "forward.fill") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
                .disabled(!player.hasTrack)
            Button("Previous", systemImage: "backward.fill") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
                .disabled(!player.hasTrack)
            Divider()
            Button("Shuffle", systemImage: "shuffle") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Repeat", systemImage: "repeat") { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button(navigation.isShowingNowPlaying ? "Hide Now Playing" : "Show Now Playing", systemImage: "sidebar.right") { navigation.isShowingNowPlaying.toggle() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandMenu("Library") {
            Button("Recently Added", systemImage: "clock") { navigation.selection = .recentlyAdded }
                .keyboardShortcut("1", modifiers: .command)
            Button("Artists", systemImage: "music.microphone") { navigation.selection = .artists }
                .keyboardShortcut("2", modifiers: .command)
            Button("Genres", systemImage: "guitars") { navigation.selection = .genres }
                .keyboardShortcut("3", modifiers: .command)
            Button("Playlists", systemImage: "music.note.list") { navigation.selection = .playlists }
                .keyboardShortcut("4", modifiers: .command)
            Button("Downloads", systemImage: "arrow.down.circle") { navigation.selection = .downloads }
                .keyboardShortcut("5", modifiers: .command)
            Divider()
            Button("Search", systemImage: "magnifyingglass") { navigation.focusSearch() }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("New Playlist…", systemImage: "plus") {
                navigation.selection = .playlists
                navigation.isNamingPlaylist = true
            }
            .keyboardShortcut("n", modifiers: .command)
            Divider()
            Button("Scan for New Music", systemImage: "arrow.clockwise") { model.rescan() }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(model.isScanning || model.connection == nil)
        }
        SidebarCommands()
    }
}
