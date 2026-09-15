import Foundation
import Testing
@testable import SkyrCore

@MainActor private final class AlbumNavigationFixture {
    let suite = "SkyrAlbumNavigation.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appending(path: "SkyrAlbumNavigation-\(UUID())")
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

@Suite("Deferred album navigation") @MainActor
struct AlbumNavigationTests {
    @Test func newestAlbumRequestWinsEvenIfEarlierCompletionArrivesLast() throws {
        let f = try AlbumNavigationFixture(); defer { f.cleanUp() }
        let first = try #require(f.model.beginAlbumNavigation(f.library.albums[0]))
        let second = try #require(f.model.beginAlbumNavigation(f.library.albums[1]))
        f.model.finishAlbumNavigation(second)
        f.model.finishAlbumNavigation(first)
        #expect(f.model.albumToOpen?.id == f.library.albums[1].id)
    }

    @Test func movingAwayAndBackDoesNotRevivePendingPush() throws {
        let f = try AlbumNavigationFixture(); defer { f.cleanUp() }
        let request = try #require(f.model.beginAlbumNavigation(f.library.albums[0]))
        f.model.showTab(named: "downloads")
        f.model.showTab(named: "library")
        f.model.finishAlbumNavigation(request)
        #expect(f.model.albumToOpen == nil)
        let tvRequest = try #require(f.model.beginAlbumNavigation(f.library.albums[0]))
        f.model.cancelPendingAlbumNavigation()
        f.model.finishAlbumNavigation(tvRequest)
        #expect(f.model.albumToOpen == nil)
    }

    @Test func lockAndReopenRejectsThePreviousSessionRequest() throws {
        let f = try AlbumNavigationFixture(); defer { f.cleanUp() }
        let request = try #require(f.model.beginAlbumNavigation(f.library.albums[0]))
        let profile = try #require(f.profiles.active)
        f.profiles.lock()
        #expect(f.model.beginAlbumNavigation(f.library.albums[0]) == nil)
        #expect(f.profiles.activate(profile))
        f.model.finishAlbumNavigation(request)
        #expect(f.model.albumToOpen == nil)
    }

    @Test func sourceReplacementCannotOpenAnIdenticallyNamedAlbum() throws {
        let f = try AlbumNavigationFixture(); defer { f.cleanUp() }
        let request = try #require(f.model.beginAlbumNavigation(f.library.albums[0]))
        var replacement = SampleLibrary.catalogue
        replacement.driveID = "another-source"
        f.library.replace(with: replacement, drive: nil)
        f.model.finishAlbumNavigation(request)
        #expect(f.model.albumToOpen == nil)
    }

    @Test func catalogueRefreshUsesTheCurrentAlbumAndRemovalCancelsThePush() async throws {
        let f = try AlbumNavigationFixture(); defer { f.cleanUp() }
        let album = f.library.albums[0]
        let request = try #require(f.model.beginAlbumNavigation(album))
        var replacement = SampleLibrary.catalogue
        let index = try #require(replacement.albums.firstIndex { $0.id == album.id })
        replacement.albums[index].title = "Updated album title"
        f.library.replace(with: replacement, drive: nil)
        for _ in 0..<200 where f.library.album(id: album.id)?.title != "Updated album title" {
            try await Task.sleep(for: .milliseconds(5))
        }
        f.model.finishAlbumNavigation(request)
        #expect(f.model.albumToOpen?.title == "Updated album title")
        f.model.albumToOpen = nil
        let removed = try #require(f.model.beginAlbumNavigation(album))
        f.library.replace(with: .empty, drive: nil)
        f.model.finishAlbumNavigation(removed)
        #expect(f.model.albumToOpen == nil)
    }
}
