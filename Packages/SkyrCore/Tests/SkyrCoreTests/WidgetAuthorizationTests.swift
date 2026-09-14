import CoreGraphics
import Foundation
import ImageIO
import SkyrShared
import Testing
import UniformTypeIdentifiers

private nonisolated struct WidgetFixture {
    let directory: URL
    let store: WidgetStore.Storage

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "skyr-widget-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = WidgetStore.Storage(directory: directory)
        store.resetAuthorization()
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    func image() throws -> URL {
        let url = directory.appending(path: "source.png")
        let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 32,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }
}

@Test nonisolated func widgetLegacyOrMissingAuthorizationDoesNotExposeSavedContent() async throws {
    let fixture = try WidgetFixture()
    defer { fixture.cleanUp() }
    await fixture.store.flush()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    try encoder.encode(WidgetSnapshot.sample).write(to: fixture.directory.appending(path: "widget-snapshot.json"))
    #expect(fixture.store.load() == nil)
    #expect(fixture.store.publication(for: UUID()) == nil)
    try FileManager.default.removeItem(at: fixture.directory.appending(path: "widget-authorization.json"))
    #expect(fixture.store.load() == nil)
}

@Test nonisolated func widgetAuthorizedPublicationCanBeReadByTheExtension() async throws {
    let fixture = try WidgetFixture()
    defer { fixture.cleanUp() }
    let session = UUID()
    fixture.store.setSession(session)
    let publication = try #require(fixture.store.publication(for: session))
    let source = try fixture.image()
    let written = await fixture.store.write(.sample, publication: publication, coverSources: ["cover": source], heroKeys: ["cover"])
    #expect(written)
    let reader = WidgetStore.Storage(directory: fixture.directory)
    #expect(reader.load()?.nowPlaying?.id == WidgetSnapshot.sample.nowPlaying?.id)
    #expect(reader.coverURL(key: "cover", pixels: WidgetStore.heroPixels) != nil)
    #expect(reader.coverURL(key: "cover", pixels: WidgetStore.tilePixels) != nil)
    #expect(reader.coverURL(key: "../source", pixels: 240) == nil)
}

@Test nonisolated func widgetLockImmediatelyDeniesReadsAndRemovesCopies() async throws {
    let fixture = try WidgetFixture()
    defer { fixture.cleanUp() }
    let session = UUID()
    fixture.store.setSession(session)
    let publication = try #require(fixture.store.publication(for: session))
    let source = try fixture.image()
    #expect(await fixture.store.write(.sample, publication: publication, coverSources: ["cover": source], heroKeys: []))
    let reader = WidgetStore.Storage(directory: fixture.directory)
    let copiedURL = try #require(reader.coverURL(key: "cover", pixels: WidgetStore.tilePixels))
    fixture.store.setSession(nil)
    #expect(reader.load() == nil)
    #expect(reader.coverURL(key: "cover", pixels: WidgetStore.tilePixels) == nil)
    #expect(fixture.store.publication(for: session) == nil)
    #expect(!(await fixture.store.write(.sample, publication: publication, coverSources: ["cover": source], heroKeys: [])))
    await fixture.store.flush()
    #expect(!FileManager.default.fileExists(atPath: copiedURL.path))
    #expect(!FileManager.default.fileExists(atPath: fixture.directory.appending(path: "widget-snapshot.json").path))
}

@Test nonisolated func widgetSupersededRefreshCannotReplaceTheLatestSnapshot() async throws {
    let fixture = try WidgetFixture()
    defer { fixture.cleanUp() }
    let session = UUID()
    fixture.store.setSession(session)
    let older = try #require(fixture.store.publication(for: session))
    let newer = try #require(fixture.store.publication(for: session))
    let snapshot = WidgetSnapshot(trackTitle: "Latest selection")
    #expect(await fixture.store.write(snapshot, publication: newer, coverSources: [:], heroKeys: []))
    #expect(!(await fixture.store.write(.sample, publication: older, coverSources: [:], heroKeys: [])))
    #expect(fixture.store.load()?.trackTitle == "Latest selection")
}

@Test nonisolated func widgetSwitchAndNewAppLaunchInvalidateEarlierOpenings() async throws {
    let fixture = try WidgetFixture()
    defer { fixture.cleanUp() }
    let firstSession = UUID()
    fixture.store.setSession(firstSession)
    let first = try #require(fixture.store.publication(for: firstSession))
    #expect(await fixture.store.write(.sample, publication: first, coverSources: [:], heroKeys: []))
    let secondSession = UUID()
    fixture.store.setSession(secondSession)
    #expect(fixture.store.load() == nil)
    #expect(!(await fixture.store.write(.sample, publication: first, coverSources: [:], heroKeys: [])))
    let second = try #require(fixture.store.publication(for: secondSession))
    #expect(await fixture.store.write(WidgetSnapshot(trackTitle: "Second profile"), publication: second, coverSources: [:], heroKeys: []))
    #expect(fixture.store.load()?.trackTitle == "Second profile")

    let newAppLaunch = WidgetStore.Storage(directory: fixture.directory)
    newAppLaunch.resetAuthorization()
    #expect(fixture.store.load() == nil)
    #expect(!(await fixture.store.write(.sample, publication: second, coverSources: [:], heroKeys: [])))
    await newAppLaunch.flush()
}

@Test nonisolated func widgetCorruptAuthorizationRefusesBothReadingAndPublication() async throws {
    let fixture = try WidgetFixture()
    defer { fixture.cleanUp() }
    let session = UUID()
    fixture.store.setSession(session)
    let publication = try #require(fixture.store.publication(for: session))
    #expect(await fixture.store.write(.sample, publication: publication, coverSources: [:], heroKeys: []))
    try Data("unreadable authorization".utf8).write(to: fixture.directory.appending(path: "widget-authorization.json"), options: .atomic)
    #expect(fixture.store.load() == nil)
    #expect(fixture.store.publication(for: session) == nil)
    #expect(!(await fixture.store.write(.sample, publication: publication, coverSources: [:], heroKeys: [])))
}
