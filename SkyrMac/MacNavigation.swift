import SkyrCore
import SwiftUI

/// What the sidebar can show. The library facets share one detail stack, so moving between them
/// keeps whatever album or artist was open.
enum MacSection: Hashable {
    case search
    case recentlyAdded
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
        case .recentlyAdded, .artists, .genres: "library"
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
}

/// The menu bar: playback, library and view shortcuts.
struct MacCommands: Commands {
    let navigation: MacNavigation
    let player: PlayerModel
    let model: AppModel

    var body: some Commands {
        CommandMenu("Playback") {
            Button("Play/Pause", systemImage: "playpause.fill") { player.togglePlayPause() }
                .keyboardShortcut("p", modifiers: [.command, .option])
            Button("Next", systemImage: "forward.fill") { player.next() }
                .keyboardShortcut(.rightArrow, modifiers: .command)
            Button("Previous", systemImage: "backward.fill") { player.previous() }
                .keyboardShortcut(.leftArrow, modifiers: .command)
            Divider()
            Button("Shuffle", systemImage: "shuffle") { player.toggleShuffle() }
                .keyboardShortcut("s", modifiers: [.command, .option])
            Button("Repeat", systemImage: "repeat") { player.cycleRepeat() }
                .keyboardShortcut("r", modifiers: [.command, .option])
            Divider()
            Button("Now Playing", systemImage: "music.note") { navigation.isShowingNowPlaying = true }
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
            Button("Search", systemImage: "magnifyingglass") { navigation.selection = .search }
                .keyboardShortcut("f", modifiers: .command)
            Divider()
            Button("Scan for New Music", systemImage: "arrow.clockwise") { model.rescan() }
                .keyboardShortcut("r", modifiers: .command)
        }
    }
}
