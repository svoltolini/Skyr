import Foundation
import SkyrShared
import Testing
@testable import SkyrCore

@Suite("Now-playing deep links")
struct WidgetLinkNowPlayingTests {
    @Test func nowPlayingURLHasNoQueryAndParsesWithoutAnId() {
        let url = WidgetLink.nowPlaying
        #expect(url.scheme == "skyr")
        #expect(url.host == "nowplaying")
        #expect(url.query == nil)
        #expect(WidgetLink.destination(from: url) == .nowPlaying)
    }

    @Test func nowPlayingHostWinsEvenWhenATrackQueryIsPresent() {
        let url = URL(string: "skyr://nowplaying?id=track-1")
        #expect(WidgetLink.destination(from: url!) == .nowPlaying)
    }

    @Test func albumPlaylistAndTabLinksStillNeedAnId() {
        #expect(WidgetLink.destination(from: WidgetLink.album(id: "a1")) == .album("a1"))
        #expect(WidgetLink.destination(from: WidgetLink.playlist(id: "p1")) == .playlist("p1"))
        #expect(WidgetLink.destination(from: WidgetLink.tab("downloads")) == .tab("downloads"))
        #expect(WidgetLink.destination(from: URL(string: "skyr://album")!) == nil)
        #expect(WidgetLink.destination(from: URL(string: "skyr://tab")!) == nil)
        #expect(WidgetLink.destination(from: URL(string: "https://example.com/nowplaying")!) == nil)
    }

    @Test func playingOrPausedLeadOpensThePlaySheet() {
        #expect(WidgetSnapshot.Lead.playing.isCurrentPlayback)
        #expect(WidgetSnapshot.Lead.paused.isCurrentPlayback)
        #expect(!WidgetSnapshot.Lead.recentlyPlayed.isCurrentPlayback)
        #expect(!WidgetSnapshot.Lead.recentlyAdded.isCurrentPlayback)
    }

    @Test func systemNowPlayingForegroundPresentsOnlyFromBackgroundWithATrack() {
        #expect(WidgetLink.shouldPresentNowPlayingOnForeground(fromBackground: true, handledWidgetURL: false, hasTrack: true))
        #expect(!WidgetLink.shouldPresentNowPlayingOnForeground(fromBackground: true, handledWidgetURL: true, hasTrack: true))
        #expect(!WidgetLink.shouldPresentNowPlayingOnForeground(fromBackground: false, handledWidgetURL: false, hasTrack: true))
        #expect(!WidgetLink.shouldPresentNowPlayingOnForeground(fromBackground: true, handledWidgetURL: false, hasTrack: false))
    }
}

@Suite("Now-playing presentation requests") @MainActor
struct NowPlayingPresentationTests {
    @Test func showNowPlayingIncrementsIndependentlyOfAlbumNavigation() throws {
        let f = try AlbumNavigationFixture(); defer { f.cleanUp() }
        #expect(f.model.nowPlayingPresentationRequest == 0)
        f.model.showNowPlaying()
        f.model.showNowPlaying()
        #expect(f.model.nowPlayingPresentationRequest == 2)
        #expect(f.model.albumToOpen == nil)
        #expect(f.model.selectedTab == .library)
    }

    @Test func returningFromBackgroundWithATrackOpensNowPlayingUnlessAWidgetURLAlreadyRouted() throws {
        let f = try AlbumNavigationFixture(); defer { f.cleanUp() }
        f.model.showNowPlayingIfReturningWithTrack(fromBackground: true, handledWidgetURL: false, hasTrack: true)
        #expect(f.model.nowPlayingPresentationRequest == 1)
        f.model.showNowPlayingIfReturningWithTrack(fromBackground: true, handledWidgetURL: true, hasTrack: true)
        f.model.showNowPlayingIfReturningWithTrack(fromBackground: false, handledWidgetURL: false, hasTrack: true)
        f.model.showNowPlayingIfReturningWithTrack(fromBackground: true, handledWidgetURL: false, hasTrack: false)
        #expect(f.model.nowPlayingPresentationRequest == 1)
    }
}
