import Foundation
import Testing
@testable import SkyrCore

private actor CacheWriteGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private nonisolated func cacheFixture(_ root: String, source: String = "cache-fixture-source") -> Catalogue {
    var value = SampleLibrary.catalogue
    value.albums = Array(value.albums.prefix(1))
    value.rootPath = root
    value.driveID = source
    return value
}

private nonisolated func cacheFixtureEncoding(_ value: Catalogue) throws -> Data {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    return try encoder.encode(value)
}

private nonisolated func awaitCacheGate(_ gate: CacheWriteGate) async throws {
    for _ in 0..<1000 {
        if await gate.entered { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(await gate.entered)
}

private nonisolated func withCacheDirectory(_ body: (URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-cache-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(directory.appending(path: "catalogue.json"))
}

@Suite struct CatalogueCacheTests {
    @Test func aFreshInstanceCleansOnlyRecognizedFilesFromExitedWriters() async throws {
        try await withCacheDirectory { url in
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let child = Process()
            child.executableURL = URL(filePath: "/usr/bin/true")
            try child.run()
            child.waitUntilExit()
            let exitedPID = child.processIdentifier
            let abandoned = directory.appending(path: ".catalogue.json.skyr-cache-\(exitedPID)-\(UUID()).pending")
            let active = directory.appending(path: ".catalogue.json.skyr-cache-\(ProcessInfo.processInfo.processIdentifier)-\(UUID()).pending")
            let otherCache = directory.appending(path: ".other.json.skyr-cache-\(exitedPID)-\(UUID()).pending")
            let unrecognized = directory.appending(path: ".catalogue.json.skyr-cache-not-a-writer.pending")
            let music = directory.appending(path: "Song.m4a")
            let folder = directory.appending(path: ".catalogue.json.skyr-cache-\(exitedPID)-\(UUID()).pending")
            let link = directory.appending(path: ".catalogue.json.skyr-cache-\(exitedPID)-\(UUID()).pending")
            let committed = try cacheFixtureEncoding(cacheFixture("/previous"))
            try committed.write(to: url)
            for file in [abandoned, active, otherCache, unrecognized, music] { try Data("fixture".utf8).write(to: file) }
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: music)
            let cache = CatalogueCache(fileURL: url)
            await cache.stagingCleanup.value
            #expect(!FileManager.default.fileExists(atPath: abandoned.path))
            for file in [active, otherCache, unrecognized, music, folder, link] { #expect(FileManager.default.fileExists(atPath: file.path)) }
            #expect(try Data(contentsOf: url) == committed)
            #expect(cache.load()?.rootPath == "/previous")
        }
    }

    @Test func aFreshInstanceCannotCleanAnActiveStagedWrite() async throws {
        try await withCacheDirectory { url in
            let gate = CacheWriteGate()
            let cache = CatalogueCache(fileURL: url, beforePublication: { _ in await gate.wait() })
            let save = cache.save(cacheFixture("/new"))
            try await awaitCacheGate(gate)
            let fresh = CatalogueCache(fileURL: url)
            await fresh.stagingCleanup.value
            let files = try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)
            #expect(files.filter { $0.hasSuffix(".pending") }.count == 1)
            await gate.release()
            #expect(await save.value == .saved)
            #expect(fresh.load()?.rootPath == "/new")
        }
    }

    @Test func olderEncoderCannotReplaceANewerCompletedSave() async throws {
        try await withCacheDirectory { url in
            let gate = CacheWriteGate()
            let cache = CatalogueCache(fileURL: url, encode: { catalogue in
                if catalogue.rootPath == "/old" { await gate.wait() }
                return try cacheFixtureEncoding(catalogue)
            })
            let old = cache.save(cacheFixture("/old"))
            try await awaitCacheGate(gate)
            #expect(await cache.save(cacheFixture("/new")).value == .saved)
            await gate.release()
            #expect(await old.value == .superseded)
            #expect(cache.load()?.rootPath == "/new")
            #expect(CatalogueCache(fileURL: url).load()?.rootPath == "/new")
        }
    }

    @Test func sourceSwitchAfterStagingCannotPublishTheOldSource() async throws {
        try await withCacheDirectory { url in
            let gate = CacheWriteGate()
            let cache = CatalogueCache(fileURL: url, beforePublication: { catalogue in
                if catalogue.driveID == "old-source" { await gate.wait() }
            })
            #expect(await cache.save(cacheFixture("/previous")).value == .saved)
            let old = cache.save(cacheFixture("/same-path", source: "old-source"))
            try await awaitCacheGate(gate)
            cache.invalidatePendingWrites()
            #expect(await cache.save(cacheFixture("/same-path", source: "new-source")).value == .saved)
            await gate.release()
            #expect(await old.value == .superseded)
            #expect(CatalogueCache(fileURL: url).load()?.driveID == "new-source")
        }
    }

    @Test func folderChangeAfterStagingRetainsTheLastRecoverableCache() async throws {
        try await withCacheDirectory { url in
            let gate = CacheWriteGate()
            let cache = CatalogueCache(fileURL: url, beforePublication: { catalogue in
                if catalogue.rootPath == "/old-refresh" { await gate.wait() }
            })
            #expect(await cache.save(cacheFixture("/previous")).value == .saved)
            let old = cache.save(cacheFixture("/old-refresh"))
            try await awaitCacheGate(gate)
            cache.invalidatePendingWrites()
            await gate.release()
            #expect(await old.value == .superseded)
            #expect(CatalogueCache(fileURL: url).load()?.rootPath == "/previous")
        }
    }

    @Test func cancellationAfterStagingCannotReplaceTheCache() async throws {
        try await withCacheDirectory { url in
            let gate = CacheWriteGate()
            let cache = CatalogueCache(fileURL: url, beforePublication: { catalogue in
                if catalogue.rootPath == "/cancelled" { await gate.wait() }
            })
            #expect(await cache.save(cacheFixture("/previous")).value == .saved)
            let save = cache.save(cacheFixture("/cancelled"))
            try await awaitCacheGate(gate)
            save.cancel()
            await gate.release()
            #expect(await save.value == .superseded)
            #expect(cache.load()?.rootPath == "/previous")
            #expect(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path) == ["catalogue.json"])
        }
    }

    @Test func removalAfterStagingCannotBeUndoneByALateWrite() async throws {
        try await withCacheDirectory { url in
            let gate = CacheWriteGate()
            let cache = CatalogueCache(fileURL: url, beforePublication: { catalogue in
                if catalogue.rootPath == "/pending" { await gate.wait() }
            })
            #expect(await cache.save(cacheFixture("/previous")).value == .saved)
            let save = cache.save(cacheFixture("/pending"))
            try await awaitCacheGate(gate)
            cache.remove()
            #expect(cache.load() == nil)
            await gate.release()
            #expect(await save.value == .superseded)
            #expect(!FileManager.default.fileExists(atPath: url.path))
            #expect(CatalogueCache(fileURL: url).load() == nil)
            #expect(await cache.save(cacheFixture("/reconnected")).value == .saved)
            #expect(cache.load()?.rootPath == "/reconnected")
        }
    }

    @Test(arguments: ["encoding", "staging", "publication"])
    func failedSavePreservesTheExistingCache(failure: String) async throws {
        try await withCacheDirectory { url in
            let good = CatalogueCache(fileURL: url)
            #expect(await good.save(cacheFixture("/previous")).value == .saved)
            let previous = try Data(contentsOf: url)
            let cache = CatalogueCache(fileURL: url, encode: { catalogue in
                if failure == "encoding" { throw CocoaError(.fileWriteOutOfSpace) }
                return try cacheFixtureEncoding(catalogue)
            }, stage: { data, temporary in
                if failure == "staging" { throw CocoaError(.fileWriteOutOfSpace) }
                try data.write(to: temporary)
            }, beforePublication: { catalogue in
                if failure == "publication" {
                    // An ordinary temporary-file disappearance makes final rename fail; the
                    // currently committed file must remain byte-for-byte intact.
                    let files = (try? FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)) ?? []
                    for file in files where file.lastPathComponent.hasSuffix(".pending") { try? FileManager.default.removeItem(at: file) }
                }
            })
            #expect(await cache.save(cacheFixture("/new")).value == .failed)
            #expect(try Data(contentsOf: url) == previous)
            #expect(CatalogueCache(fileURL: url).load()?.rootPath == "/previous")
        }
    }

    @Test func cancelledOlderFailureCannotDiscardANewerSavedCache() async throws {
        try await withCacheDirectory { url in
            let gate = CacheWriteGate()
            let cache = CatalogueCache(fileURL: url, encode: { catalogue in
                if catalogue.rootPath == "/old" {
                    await gate.wait()
                    throw CocoaError(.fileWriteOutOfSpace)
                }
                return try cacheFixtureEncoding(catalogue)
            })
            let old = cache.save(cacheFixture("/old"))
            try await awaitCacheGate(gate)
            #expect(await cache.save(cacheFixture("/new")).value == .saved)
            await gate.release()
            #expect(await old.value == .superseded)
            #expect(cache.load()?.rootPath == "/new")
        }
    }
}
