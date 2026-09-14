import Foundation
import Testing
@testable import SkyrCore

/// These fixtures never contact Apple or a NAS and use only synthetic artist/album names.
private actor ArtworkRequestFixture {
    enum Pause: Sendable { case none, search, image }
    let pause: Pause
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var urls: [URL] = []
    private(set) var suspended = false
    private(set) var sawCancellation = false

    init(pause: Pause = .none) { self.pause = pause }

    func request(_ url: URL, limit: Int64) async throws -> Data {
        urls.append(url)
        let search = url.host == "itunes.apple.com"
        if (search && pause == .search) || (!search && pause == .image) {
            suspended = true
            if !released { await withCheckedContinuation { continuation = $0 } }
        }
        // A callback already in flight can ignore cancellation: the consumer must reject its data.
        sawCancellation = sawCancellation || Task.isCancelled
        if search {
            return Data(#"{"results":[{"collectionName":"Fixture Album","artistName":"Fixture Artist","artworkUrl100":"https://is1-ssl.mzstatic.com/image/100x100bb.jpg"}]}"#.utf8)
        }
        return Data([1, 2, 3])
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private nonisolated final class ArtworkFixtureDrive: RemoteDrive {
    let id = "artwork-privacy-fixture"
    let displayName = "Fixture NAS"
    let folderImage: Data?
    let tree: [String: [RemoteEntry]]
    init(folderImage: Data? = nil, tree: [String: [RemoteEntry]] = [:]) {
        self.folderImage = folderImage
        self.tree = tree
    }
    func roots() async throws -> [RemoteEntry] { [] }
    func list(_ path: String) async throws -> [RemoteEntry] { tree[path] ?? [] }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { Data() }
    func download(_ path: String, maxBytes: Int64) async throws -> Data {
        if let folderImage { return folderImage }
        throw URLError(.fileDoesNotExist)
    }
    func streamURL(for path: String) -> URL? { nil }
}

@MainActor private func withArtworkPreference(_ body: @MainActor (ArtworkPrivacyPreference) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-artwork-privacy-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(ArtworkPrivacyPreference(fileURL: directory.appending(path: "choice/consent")))
}

@MainActor private func waitForArtwork(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<250 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The synthetic artwork request did not reach the expected state")
}

@Suite @MainActor struct ArtworkPrivacyTests {
    @Test func defaultOffMakesNoRequests() async throws {
        try await withArtworkPreference { preference in
            let fixture = ArtworkRequestFixture()
            let lookup = ArtworkLookup(preference: preference, request: fixture.request)
            #expect(!lookup.isEnabled)
            #expect(await lookup.itunesCover(artist: "Fixture Artist", album: "Fixture Album") == nil)
            #expect(await fixture.urls.isEmpty)
            #expect(!FileManager.default.fileExists(atPath: preference.fileURL.path))
        }
    }

    @Test func explicitChoiceSurvivesRelaunchAndIsExcludedFromBackup() async throws {
        try await withArtworkPreference { preference in
            let fixture = ArtworkRequestFixture()
            let lookup = ArtworkLookup(preference: preference, request: fixture.request)
            lookup.setEnabled(true)
            #expect(lookup.isEnabled)
            #expect(lookup.preferenceError == nil)
            let values = try preference.fileURL.resourceValues(forKeys: [.isExcludedFromBackupKey])
            #expect(values.isExcludedFromBackup == true)
            let relaunched = ArtworkLookup(preference: preference, request: fixture.request)
            #expect(relaunched.isEnabled)
            let anotherDevice = ArtworkLookup(preference: ArtworkPrivacyPreference(fileURL: preference.fileURL.deletingLastPathComponent().appending(path: "another-device")), request: fixture.request)
            #expect(!anotherDevice.isEnabled)
            lookup.setEnabled(false)
            #expect(!ArtworkLookup(preference: preference, request: fixture.request).isEnabled)
        }
    }

    @Test func failedConsentWriteStaysOffAndExplainsFailure() async throws {
        try await withArtworkPreference { preference in
            try FileManager.default.createDirectory(at: preference.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0]).write(to: preference.fileURL)
            let blocked = ArtworkPrivacyPreference(fileURL: preference.fileURL.appending(path: "cannot-create-in-file"))
            let fixture = ArtworkRequestFixture()
            let lookup = ArtworkLookup(preference: blocked, request: fixture.request)
            lookup.setEnabled(true)
            #expect(!lookup.isEnabled)
            #expect(lookup.preferenceError != nil)
            #expect(await lookup.itunesCover(artist: "Fixture Artist", album: "Fixture Album") == nil)
            #expect(await fixture.urls.isEmpty)
        }
    }

    @Test func explicitChoiceSendsOnlyDisclosedSearchTermsThenArtworkRequest() async throws {
        try await withArtworkPreference { preference in
            let fixture = ArtworkRequestFixture()
            let lookup = ArtworkLookup(preference: preference, request: fixture.request)
            lookup.setEnabled(true)
            let cover = try #require(await lookup.itunesCover(artist: "Fixture Artist", album: "Fixture Album"))
            #expect(lookup.acceptedData(from: cover) == Data([1, 2, 3]))
            let urls = await fixture.urls
            #expect(urls.count == 2)
            let search = URLComponents(url: urls[0], resolvingAgainstBaseURL: false)
            #expect(search?.queryItems == [
                URLQueryItem(name: "term", value: "Fixture Artist Fixture Album"),
                URLQueryItem(name: "entity", value: "album"), URLQueryItem(name: "limit", value: "8"),
                URLQueryItem(name: "media", value: "music")
            ])
            #expect(urls[1].absoluteString == "https://is1-ssl.mzstatic.com/image/600x600bb.jpg")
            lookup.setEnabled(false)
            #expect(lookup.acceptedData(from: cover) == nil)
            lookup.setEnabled(true)
            #expect(lookup.acceptedData(from: cover) == nil)
        }
    }

    @Test(arguments: [ArtworkRequestFixture.Pause.search, .image])
    private func disablingCancelsRequestsRejectsLateDataAndStopsNextRequest(pause: ArtworkRequestFixture.Pause) async throws {
        try await withArtworkPreference { preference in
            let fixture = ArtworkRequestFixture(pause: pause)
            let lookup = ArtworkLookup(preference: preference, request: fixture.request)
            lookup.setEnabled(true)
            let pending = Task { await lookup.itunesCover(artist: "Fixture Artist", album: "Fixture Album") }
            try await waitForArtwork { await fixture.suspended }
            lookup.setEnabled(false)
            lookup.setEnabled(true) // A fresh choice must not revive an older request.
            await fixture.release()
            #expect(await pending.value == nil)
            #expect(await fixture.sawCancellation)
            #expect(await fixture.urls.count == (pause == .search ? 1 : 2))
        }
    }

    @Test func cancellingCallerCancelsItsLookup() async throws {
        try await withArtworkPreference { preference in
            let fixture = ArtworkRequestFixture(pause: .search)
            let lookup = ArtworkLookup(preference: preference, request: fixture.request)
            lookup.setEnabled(true)
            let pending = Task { await lookup.itunesCover(artist: "Fixture Artist", album: "Fixture Album") }
            try await waitForArtwork { await fixture.suspended }
            pending.cancel()
            await fixture.release()
            #expect(await pending.value == nil)
            #expect(await fixture.sawCancellation)
            #expect(await fixture.urls.count == 1)
        }
    }

    @Test func enablingAllowsImmediateRetryOfEarlierNASOnlyMisses() async throws {
        try await withArtworkPreference { preference in
            let fixture = ArtworkRequestFixture()
            let lookup = ArtworkLookup(preference: preference, request: fixture.request)
            let earlierMiss = Date.now.addingTimeInterval(-60)
            #expect(!lookup.shouldRetryMissingCover(after: earlierMiss))
            lookup.setEnabled(true)
            #expect(lookup.shouldRetryMissingCover(after: earlierMiss))
            #expect(!lookup.shouldRetryMissingCover(after: .now.addingTimeInterval(60)))
        }
    }

    @Test func manualRefreshStillUsesNASArtworkWhileOnlineLookupIsOff() async throws {
        try await withArtworkPreference { preference in
            try await CoverStore.$directoryOverride.withValue(preference.fileURL.deletingLastPathComponent().appending(path: "covers")) {
                let fixture = ArtworkRequestFixture()
                let lookup = ArtworkLookup(preference: preference, request: fixture.request)
                let drive = ArtworkFixtureDrive(folderImage: Data([4, 5, 6]))
                let library = LibraryStore(artworkLookup: lookup)
                var catalogue = SampleLibrary.catalogue
                catalogue.driveID = drive.id
                catalogue.albums = Array(catalogue.albums.prefix(1))
                catalogue.albums[0].coverPath = "/fixture/cover.jpg"
                library.replace(with: catalogue, drive: drive)
                let album = try #require(library.albums.first)
                let message = await library.refreshCover(for: album)
                #expect(message == "Cover taken from folder image /fixture/cover.jpg")
                #expect(await fixture.urls.isEmpty)
                let saved = try Data(contentsOf: CoverStore.fileURL(for: album.id))
                #expect(saved == Data([4, 5, 6]))
            }
        }
    }

    @Test func automaticScanIsNASOnlyUntilExplicitChoiceThenRetriesMissingCovers() async throws {
        try await withArtworkPreference { preference in
            try await CoverStore.$directoryOverride.withValue(preference.fileURL.deletingLastPathComponent().appending(path: "covers")) {
                let fixture = ArtworkRequestFixture()
                let lookup = ArtworkLookup(preference: preference, request: fixture.request)
                let artistFolder = "/music/Fixture Artist"
                let albumFolder = artistFolder + "/Fixture Album"
                func entry(_ path: String, folder: Bool) -> RemoteEntry {
                    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: folder,
                                size: folder ? nil : 1024, modified: nil)
                }
                let drive = ArtworkFixtureDrive(tree: [
                    "/music": [entry(artistFolder, folder: true)],
                    artistFolder: [entry(albumFolder, folder: true)],
                    albumFolder: [entry(albumFolder + "/01 Song.flac", folder: false)]
                ])
                let indexer = LibraryIndexer(recordDiagnostics: { _ in }, artworkLookup: lookup)
                var catalogue = Catalogue.empty
                indexer.start(drive: drive, rootPath: "/music", serverName: "Fixture NAS", existing: nil) { catalogue = $0 }
                try await waitForArtwork { !indexer.isRunning }
                #expect(indexer.phase == .done)
                #expect(await fixture.urls.isEmpty)
                let album = try #require(catalogue.albums.first)
                #expect(!CoverStore.hasCover(for: album.id))
                #expect(CoverStore.missingCoverDate(for: album.id) != nil)

                lookup.setEnabled(true)
                indexer.start(drive: drive, rootPath: "/music", serverName: "Fixture NAS", existing: catalogue) { catalogue = $0 }
                try await waitForArtwork { !indexer.isRunning }
                #expect(indexer.phase == .done)
                #expect(await fixture.urls.count == 2)
                #expect(CoverStore.hasCover(for: album.id))
            }
        }
    }

    @Test func manualRefreshCannotPublishAppleArtworkAfterOptOut() async throws {
        try await withArtworkPreference { preference in
            await CoverStore.$directoryOverride.withValue(preference.fileURL.deletingLastPathComponent().appending(path: "covers")) {
                let fixture = ArtworkRequestFixture(pause: .image)
                let lookup = ArtworkLookup(preference: preference, request: fixture.request)
                lookup.setEnabled(true)
                let drive = ArtworkFixtureDrive()
                let library = LibraryStore(artworkLookup: lookup)
                var catalogue = SampleLibrary.catalogue
                catalogue.driveID = drive.id
                catalogue.albums = Array(catalogue.albums.prefix(1))
                catalogue.albums[0].title = "Fixture Album"
                catalogue.albums[0].artist = "Fixture Artist"
                catalogue.albums[0].tracks = []
                library.replace(with: catalogue, drive: drive)
                let album = catalogue.albums[0]
                let pending = Task { await library.refreshCover(for: album) }
                try? await waitForArtwork { await fixture.suspended }
                lookup.setEnabled(false)
                await fixture.release()
                _ = await pending.value
                #expect(!CoverStore.hasCover(for: album.id))
                #expect(library.coverURL(for: album) == nil)
            }
        }
    }
}

/// URLSession's real AsyncBytes path receives headers and an ordinary partial body, then waits.
/// The URLProtocol intercepts every request locally; no network connection is made.
private nonisolated final class ArtworkBodyProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sentBody = false
    nonisolated(unsafe) private static var wasStopped = false

    static func reset() { lock.withLock { sentBody = false; wasStopped = false } }
    static var hasSentBody: Bool { lock.withLock { sentBody } }
    static var stopped: Bool { lock.withLock { wasStopped } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Length": "128"]) else { return }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data([0x7b]))
        Self.lock.withLock { Self.sentBody = true }
    }
    override func stopLoading() { Self.lock.withLock { Self.wasStopped = true } }
}

@Suite(.serialized) @MainActor struct ArtworkTransportCancellationTests {
    @Test func optingOutCancelsTheActualURLSessionBodyTransfer() async throws {
        try await withArtworkPreference { preference in
            ArtworkBodyProtocol.reset()
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ArtworkBodyProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let lookup = ArtworkLookup(preference: preference, request: { url, limit in
                try await ArtworkDownload.data(from: url, maximum: limit, session: session)
            })
            lookup.setEnabled(true)
            let pending = Task { await lookup.itunesCover(artist: "Fixture Artist", album: "Fixture Album") }
            try await waitForArtwork { ArtworkBodyProtocol.hasSentBody }
            // Let the AsyncBytes iterator consume the first byte and await the remainder.
            try await Task.sleep(for: .milliseconds(30))
            lookup.setEnabled(false)
            try await waitForArtwork { ArtworkBodyProtocol.stopped }
            #expect(ArtworkBodyProtocol.stopped)
            #expect(await pending.value == nil)
        }
    }
}
