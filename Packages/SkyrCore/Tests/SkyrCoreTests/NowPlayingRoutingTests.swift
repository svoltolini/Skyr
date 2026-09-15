import Foundation
import SkyrShared
import SwiftUI
import Testing
@testable import SkyrCore

@Suite("Now Playing links")
struct NowPlayingLinkTests {
    @Test func playerLinkRoundTripsWithAndWithoutAFallback() {
        #expect(WidgetLink.destination(from: WidgetLink.nowPlaying()) == .nowPlaying(fallback: nil))
        #expect(WidgetLink.destination(from: WidgetLink.nowPlaying(fallback: .album("a 1"))) == .nowPlaying(fallback: .album("a 1")))
        #expect(WidgetLink.destination(from: WidgetLink.nowPlaying(fallback: .playlist("p/1"))) == .nowPlaying(fallback: .playlist("p/1")))
        #expect(WidgetLink.destination(from: WidgetLink.nowPlaying(fallback: .tab("downloads"))) == .nowPlaying(fallback: .tab("downloads")))
        // A player link cannot fall back to another player link; it degrades to the plain one.
        #expect(WidgetLink.destination(from: WidgetLink.nowPlaying(fallback: .nowPlaying(fallback: .album("a")))) == .nowPlaying(fallback: nil))
    }

    @Test func widgetLinksAreUnchanged() throws {
        #expect(WidgetLink.destination(from: WidgetLink.album(id: "a1")) == .album("a1"))
        #expect(WidgetLink.destination(from: WidgetLink.playlist(id: "p1")) == .playlist("p1"))
        #expect(WidgetLink.destination(from: WidgetLink.tab("playlists")) == .tab("playlists"))
        let albumWithoutID = try #require(URL(string: "skyr://album"))
        #expect(WidgetLink.destination(from: albumWithoutID) == nil)
        let otherScheme = try #require(URL(string: "https://now-playing?album=a1"))
        #expect(WidgetLink.destination(from: otherScheme) == nil)
        let playerWithStrayID = try #require(URL(string: "skyr://now-playing?id=a1"))
        #expect(WidgetLink.destination(from: playerWithStrayID) == .nowPlaying(fallback: nil))
    }

    @Test func downloadOwnersNameTheirAlbumOrPlaylist() {
        let profile = "profile:owner|"
        #expect(DownloadOwner.destination(ownerID: profile + DownloadOwner.albumPrefix + "album|with|bars") == .album("album|with|bars"))
        #expect(DownloadOwner.destination(ownerID: profile + DownloadOwner.playlistPrefix + "p1") == .playlist("p1"))
        #expect(DownloadOwner.destination(ownerID: DownloadOwner.albumPrefix + "legacy") == .album("legacy"))
        #expect(DownloadOwner.destination(ownerID: profile + DownloadOwner.albumPrefix) == nil)
        #expect(DownloadOwner.destination(ownerID: "profile:owner|watch:x") == nil)
    }

    #if os(iOS)
    @Test func activitiesFromBeforeLinksWereCarriedStillOpenThePlayer() throws {
        let data = try JSONEncoder().encode(DownloadActivityAttributes(title: "Album", subtitle: "Artist"))
        let decoded = try JSONDecoder().decode(DownloadActivityAttributes.self, from: data)
        #expect(decoded.link == nil)
        #expect(WidgetLink.destination(from: decoded.openURL) == .nowPlaying(fallback: nil))
    }
    #endif
}

@MainActor private final class NowPlayingFixture {
    let suite = "SkyrNowPlayingRouting.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appending(path: "SkyrNowPlayingRouting-\(UUID())")
    let defaults: UserDefaults
    let profiles: ProfileStore
    let library = LibraryStore()
    let model: AppModel

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(3, forKey: "coverCacheVersion")
        profiles = ProfileStore(directory: directory, defaults: defaults)
        #expect(profiles.activate(try #require(profiles.owner)))
        var services = ConnectionServices()
        services.password = { _ in nil }
        services.loadCatalogue = { nil }
        services.deleteCatalogue = {}
        services.log = { _ in }
        model = AppModel(library: library, defaults: defaults, services: services, restoresSession: false)
        model.profiles = profiles
        library.profiles = profiles
        library.replace(with: SampleLibrary.catalogue, drive: nil)
        model.stage = .ready
    }

    func cleanUp() {
        profiles.lock()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Now Playing presentation") @MainActor
struct NowPlayingPresentationTests {
    @Test func aRequestBringsThePlayerUpOnceAndLeavesItUp() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        #expect(!f.model.isNowPlayingPresented)
        f.model.showNowPlaying()
        #expect(f.model.isNowPlayingPresented)
        f.model.showNowPlaying()
        #expect(f.model.isNowPlayingPresented)
    }

    @Test func nothingComesUpBeforeTheLibraryOrWhileLockedOrSigningIn() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.model.stage = .indexing
        f.model.showNowPlaying()
        #expect(!f.model.isNowPlayingPresented)
        f.model.stage = .ready

        f.model.pendingServer = DiscoveredServer(name: "NAS", baseURL: try #require(URL(string: "https://nas.local:5001")), model: nil)
        f.model.showNowPlaying()
        #expect(!f.model.isNowPlayingPresented)
        f.model.pendingServer = nil

        let profile = try #require(f.profiles.active)
        f.profiles.lock()
        f.model.showNowPlaying()
        #expect(!f.model.isNowPlayingPresented)
        #expect(f.profiles.activate(profile))
        f.model.showNowPlaying()
        #expect(f.model.isNowPlayingPresented)
    }

    @Test func anotherDestinationClosesThePlayer() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.model.showNowPlaying()
        f.model.showAlbum(f.library.albums[0])
        #expect(!f.model.isNowPlayingPresented)
        #expect(f.model.selectedTab == .library)

        f.model.showNowPlaying()
        f.model.showTab(named: "downloads")
        #expect(!f.model.isNowPlayingPresented)
        #expect(f.model.selectedTab == .downloads)

        f.model.showNowPlaying()
        f.model.showPlaylist(f.library.libraryShufflePlaylist)
        #expect(!f.model.isNowPlayingPresented)
        #expect(f.model.selectedTab == .playlists)
    }

    @Test func leavingTheLibraryDropsThePlayer() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.model.showNowPlaying()
        f.model.stage = .welcome
        #expect(!f.model.isNowPlayingPresented)
        f.model.stage = .ready
        #expect(!f.model.isNowPlayingPresented)
    }

    @Test func returningFromTheBackgroundWhilePlayingBringsThePlayerUp() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.model.scenePhaseChanged(.background, isPlaying: true)
        f.model.scenePhaseChanged(.inactive, isPlaying: true)
        #expect(!f.model.isNowPlayingPresented)
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(f.model.isNowPlayingPresented)
    }

    @Test func returningWithoutMusicOrWithoutLeavingKeepsTheScreenAsItWas() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        // A plain launch: nothing is playing when the screen first comes up.
        f.model.scenePhaseChanged(.active, isPlaying: false)
        #expect(!f.model.isNowPlayingPresented)
        // Control Center or a Face ID prompt: inactive, never in the background.
        f.model.scenePhaseChanged(.inactive, isPlaying: true)
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(!f.model.isNowPlayingPresented)
        // Paused or stopped: the island is not showing the app.
        f.model.scenePhaseChanged(.background, isPlaying: true)
        f.model.scenePhaseChanged(.active, isPlaying: false)
        #expect(!f.model.isNowPlayingPresented)
        // An arrival is consumed: playing later does not present retroactively.
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(!f.model.isNowPlayingPresented)
    }

    @Test func musicAlreadyPlayingWhenTheScreenFirstComesUpBringsThePlayerUp() throws {
        // A widget's play button launched the app in the background; the island tap is its first activation.
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(f.model.isNowPlayingPresented)

        // A widget cover tapped instead: the album page, decided before the screen is active.
        let linked = try NowPlayingFixture(); defer { linked.cleanUp() }
        linked.model.showAlbum(linked.library.albums[0])
        linked.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(!linked.model.isNowPlayingPresented)
    }

    @Test func activationsWithoutPlaybackStateLeaveTheReturnToThePhone() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.model.scenePhaseChanged(.active, isPlaying: false)
        f.model.scenePhaseChanged(.background)
        // The car's scene and the Mac and television report no playback state and never present.
        f.model.scenePhaseChanged(.active)
        #expect(!f.model.isNowPlayingPresented)
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(f.model.isNowPlayingPresented)
    }

    @Test func aLinkHandledDuringTheReturnDecidesWhereItLands() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.model.scenePhaseChanged(.background, isPlaying: true)
        // A widget cover tapped while music plays: the album page, with no player over it.
        f.model.showAlbum(f.library.albums[0])
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(!f.model.isNowPlayingPresented)

        f.model.scenePhaseChanged(.background, isPlaying: true)
        f.model.showTab(named: "downloads")
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(!f.model.isNowPlayingPresented)

        // The Live Activity's own link asks for the player; the return agrees and nothing flickers.
        f.model.scenePhaseChanged(.background, isPlaying: true)
        f.model.showNowPlaying()
        #expect(f.model.isNowPlayingPresented)
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(f.model.isNowPlayingPresented)
    }

    @Test func aLockedProfileNeverGetsThePlayerOnReturn() throws {
        let f = try NowPlayingFixture(); defer { f.cleanUp() }
        f.profiles.lock()
        f.model.scenePhaseChanged(.background, isPlaying: true)
        f.model.scenePhaseChanged(.active, isPlaying: true)
        #expect(!f.model.isNowPlayingPresented)
    }
}
