#if os(iOS)
import CarPlay
import SkyrCore
import UIKit

/// The car's screen. CarPlay hands the app an interface controller when the phone connects; the
/// controller below fills it with the library, the playlists and the artists as lists, and hands
/// playback to the system's Now Playing screen, driven by the same player as the phone.
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var controller: CarPlayController?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        guard let library = AppDelegate.library, let player = AppDelegate.player,
              let profiles = AppDelegate.profiles, let model = AppDelegate.model else { return }
        controller = CarPlayController(interface: interfaceController, library: library, player: player, profiles: profiles, model: model)
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        controller = nil
    }
}

/// Builds and refreshes the car's templates.
@MainActor
final class CarPlayController {
    private let interface: CPInterfaceController
    private let library: LibraryStore
    private let player: PlayerModel
    private let profiles: ProfileStore
    private let model: AppModel

    private var libraryTemplate: CPListTemplate?
    private var playlistsTemplate: CPListTemplate?
    private var artistsTemplate: CPListTemplate?
    /// What the root currently shows, so a change in readiness swaps it and a change in content only updates it.
    private var rootKind: RootKind?

    private enum RootKind: Equatable {
        case notSetUp, locked, tabs
    }

    /// How many entries a list carries; the car reads short lists best and CarPlay caps them anyway.
    private static let listLimit = 100

    init(interface: CPInterfaceController, library: LibraryStore, player: PlayerModel, profiles: ProfileStore, model: AppModel) {
        self.interface = interface
        self.library = library
        self.player = player
        self.profiles = profiles
        self.model = model
        configureNowPlaying()
        refresh()
        observeChanges()
    }

    // MARK: Root

    private var currentKind: RootKind {
        if model.stage != .ready { return .notSetUp }
        if profiles.isLocked { return .locked }
        return .tabs
    }

    /// Sets the root when what should be there changed; otherwise refreshes the lists in place.
    private func refresh() {
        let kind = currentKind
        if kind != rootKind {
            rootKind = kind
            let root: CPTemplate
            switch kind {
            case .notSetUp:
                root = messageTemplate(title: "Skyr", text: "Set up Skyr on your iPhone first", detail: "Connect your server, then the library appears here.")
            case .locked:
                root = messageTemplate(title: "Skyr", text: "Choose a profile on your iPhone", detail: "Playlists and favourites belong to a profile.")
            case .tabs:
                let libraryList = CPListTemplate(title: "Library", sections: librarySections())
                libraryList.tabTitle = "Library"
                libraryList.tabImage = UIImage(systemName: "square.stack.fill")
                let playlistsList = CPListTemplate(title: "Playlists", sections: playlistSections())
                playlistsList.tabTitle = "Playlists"
                playlistsList.tabImage = UIImage(systemName: "music.note.list")
                let artistsList = CPListTemplate(title: "Artists", sections: artistSections())
                artistsList.tabTitle = "Artists"
                artistsList.tabImage = UIImage(systemName: "music.mic")
                libraryTemplate = libraryList
                playlistsTemplate = playlistsList
                artistsTemplate = artistsList
                root = CPTabBarTemplate(templates: [libraryList, playlistsList, artistsList])
            }
            interface.setRootTemplate(root, animated: true, completion: nil)
        } else if kind == .tabs {
            libraryTemplate?.updateSections(librarySections())
            playlistsTemplate?.updateSections(playlistSections())
            artistsTemplate?.updateSections(artistSections())
        }
    }

    /// Rebuilds when the library, the playlists or the profile lock change.
    private func observeChanges() {
        withObservationTracking {
            _ = library.recentlyAdded.count
            _ = library.playlists.count
            _ = library.artists.count
            _ = library.favouritesPlaylist.tracks.count
            _ = profiles.isLocked
            _ = model.stage
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.refresh()
                self?.observeChanges()
            }
        }
    }

    private func messageTemplate(title: String, text: String, detail: String) -> CPListTemplate {
        let item = CPListItem(text: text, detailText: detail, image: UIImage(systemName: "iphone"))
        item.isEnabled = false
        return CPListTemplate(title: title, sections: [CPListSection(items: [item])])
    }

    // MARK: Sections

    private func librarySections() -> [CPListSection] {
        let recent = library.recentlyAdded.prefix(Self.listLimit).map(albumItem)
        return [CPListSection(items: Array(recent), header: "Recently added", sectionIndexTitle: nil)]
    }

    private func playlistSections() -> [CPListSection] {
        let smart = [library.favouritesPlaylist, library.favouritesMixPlaylist, library.recentlyPlayedPlaylist, library.libraryShufflePlaylist]
            .filter { !$0.tracks.isEmpty }
        var sections = [CPListSection(items: smart.map(playlistItem), header: "Made for you", sectionIndexTitle: nil)]
        let own = library.playlists.prefix(Self.listLimit).map(playlistItem)
        if !own.isEmpty {
            sections.append(CPListSection(items: Array(own), header: "Your playlists", sectionIndexTitle: nil))
        }
        return sections
    }

    private func artistSections() -> [CPListSection] {
        let items = library.artists.prefix(Self.listLimit).map { artist -> CPListItem in
            let item = CPListItem(text: artist.name, detailText: artist.summary, image: artist.albums.first.map(cover(for:)))
            item.accessoryType = .disclosureIndicator
            item.handler = { [weak self] _, completion in
                self?.showArtist(artist)
                completion()
            }
            return item
        }
        return [CPListSection(items: items)]
    }

    // MARK: Items

    private func albumItem(_ album: Album) -> CPListItem {
        let item = CPListItem(text: album.title, detailText: album.artist, image: cover(for: album))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.showAlbum(album)
            completion()
        }
        loadCover(for: album, into: item)
        return item
    }

    private func playlistItem(_ playlist: Playlist) -> CPListItem {
        let item = CPListItem(text: playlist.name, detailText: playlist.summary, image: playlist.covers.first.map(cover(for:)))
        item.accessoryType = .disclosureIndicator
        item.handler = { [weak self] _, completion in
            self?.showPlaylist(playlist)
            completion()
        }
        return item
    }

    // MARK: Pages

    private func showAlbum(_ album: Album) {
        let play = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"))
        play.handler = { [weak self] _, completion in
            self?.start(album.tracks, from: 0, title: nil)
            completion()
        }
        let shuffle = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffle.handler = { [weak self] _, completion in
            self?.start(album.tracks.shuffled(), from: 0, title: album.title)
            completion()
        }
        let songs = album.tracks.enumerated().map { index, track -> CPListItem in
            let item = CPListItem(text: track.title, detailText: track.artist ?? album.artist)
            item.handler = { [weak self] _, completion in
                self?.start(album.tracks, from: index, title: nil)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: album.title, sections: [
            CPListSection(items: [play, shuffle]),
            CPListSection(items: songs, header: "\(album.tracks.count) songs", sectionIndexTitle: nil),
        ])
        interface.pushTemplate(template, animated: true, completion: nil)
    }

    private func showPlaylist(_ playlist: Playlist) {
        let play = CPListItem(text: "Play", detailText: nil, image: UIImage(systemName: "play.fill"))
        play.handler = { [weak self] _, completion in
            self?.start(playlist.tracks, from: 0, title: playlist.name)
            completion()
        }
        let shuffle = CPListItem(text: "Shuffle", detailText: nil, image: UIImage(systemName: "shuffle"))
        shuffle.handler = { [weak self] _, completion in
            self?.start(playlist.tracks.shuffled(), from: 0, title: playlist.name)
            completion()
        }
        let songs = playlist.tracks.prefix(Self.listLimit * 2).enumerated().map { index, track -> CPListItem in
            let album = library.album(id: track.albumID)
            let item = CPListItem(text: track.title, detailText: track.artist ?? album?.artist ?? "", image: album.map(cover(for:)))
            item.handler = { [weak self] _, completion in
                self?.start(playlist.tracks, from: index, title: playlist.name)
                completion()
            }
            return item
        }
        let template = CPListTemplate(title: playlist.name, sections: [
            CPListSection(items: [play, shuffle]),
            CPListSection(items: Array(songs), header: playlist.summary, sectionIndexTitle: nil),
        ])
        interface.pushTemplate(template, animated: true, completion: nil)
    }

    private func showArtist(_ artist: Artist) {
        let albums = artist.albums.map(albumItem)
        let template = CPListTemplate(title: artist.name, sections: [CPListSection(items: albums)])
        interface.pushTemplate(template, animated: true, completion: nil)
    }

    /// Starts playback and brings up the system's Now Playing screen.
    private func start(_ tracks: [Track], from index: Int, title: String?) {
        player.play(queue: tracks, startingAt: index, title: title)
        if interface.topTemplate !== CPNowPlayingTemplate.shared {
            interface.pushTemplate(CPNowPlayingTemplate.shared, animated: true, completion: nil)
        }
    }

    // MARK: Now Playing

    private func configureNowPlaying() {
        let nowPlaying = CPNowPlayingTemplate.shared
        nowPlaying.isAlbumArtistButtonEnabled = false
        nowPlaying.updateNowPlayingButtons([
            CPNowPlayingShuffleButton { [weak self] _ in self?.player.toggleShuffle() },
            CPNowPlayingRepeatButton { [weak self] _ in self?.player.cycleRepeat() },
        ])
    }

    // MARK: Covers

    /// The cached cover, or the album's own gradient until the real one arrives.
    private func cover(for album: Album) -> UIImage {
        let version = library.coverVersion(for: album)
        let key = "\(album.id)|\(version)|\(CoverImageCache.thumbnailPixels)"
        if let cached = CoverImageCache.shared.cached(key) { return UIImage(cgImage: cached) }
        let size = CGSize(width: 180, height: 180)
        return UIGraphicsImageRenderer(size: size).image { context in
            let colors = [UIColor(album.primaryColor).cgColor, UIColor(album.secondaryColor).cgColor] as CFArray
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                context.cgContext.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: size.width, y: size.height), options: [])
            }
        }
    }

    /// Fetches the real cover from the server for a list item still showing its gradient.
    private func loadCover(for album: Album, into item: CPListItem) {
        let version = library.coverVersion(for: album)
        let key = "\(album.id)|\(version)|\(CoverImageCache.thumbnailPixels)"
        guard CoverImageCache.shared.cached(key) == nil, let url = library.coverURL(for: album) else { return }
        Task {
            if let image = await CoverImageCache.shared.image(url: url, key: key, maxPixelSize: CoverImageCache.thumbnailPixels) {
                item.setImage(UIImage(cgImage: image))
            }
        }
    }
}
#endif
