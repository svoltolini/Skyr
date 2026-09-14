import Foundation
import Testing
@testable import SkyrCore

private actor IndexingTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    private var released = false

    func wait() async {
        entered = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

private nonisolated final class ReliabilityDrive: RemoteDrive {
    let id: String
    let displayName = "Indexing test drive"
    let tree: [String: [RemoteEntry]]
    let failingPath: String?
    let failure: URLError.Code
    let listingGate: IndexingTestGate?
    let readGate: IndexingTestGate?

    init(id: String = "indexing-test", tree: [String: [RemoteEntry]], failingPath: String? = nil,
         failure: URLError.Code = .timedOut, listingGate: IndexingTestGate? = nil, readGate: IndexingTestGate? = nil) {
        self.id = id
        self.tree = tree
        self.failingPath = failingPath
        self.failure = failure
        self.listingGate = listingGate
        self.readGate = readGate
    }

    func roots() async throws -> [RemoteEntry] { [] }

    func list(_ path: String) async throws -> [RemoteEntry] {
        if let listingGate { await listingGate.wait() }
        if path == failingPath { throw URLError(failure) }
        return tree[path] ?? []
    }

    func read(_ path: String, range: Range<Int64>) async throws -> Data {
        // Deliberately ignores cancellation, as a provider callback already in flight can do.
        if let readGate { await readGate.wait() }
        return Data()
    }

    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw URLError(.fileDoesNotExist) }
    func streamURL(for path: String) -> URL? { nil }
}

private nonisolated func scanEntry(_ path: String, directory: Bool = false) -> RemoteEntry {
    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory,
                size: directory ? nil : 1024, modified: nil)
}

@MainActor private func waitForIndexing(_ condition: @MainActor () async -> Bool) async throws {
    for _ in 0..<250 {
        if await condition() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    Issue.record("The indexing operation did not reach its expected state within 2.5 seconds")
}

@MainActor private func withArtworkDirectory(_ body: @MainActor () async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-indexing-test-\(UUID())")
    defer { try? FileManager.default.removeItem(at: directory) }
    try await CoverStore.$directoryOverride.withValue(directory) { try await body() }
}

@Suite(.serialized) @MainActor struct IndexingReliabilityTests {
    @Test(arguments: [URLError.Code.timedOut, .userAuthenticationRequired, .noPermissionsToReadFile])
    func incompleteRefreshKeepsPreviousCatalogue(failure: URLError.Code) async throws {
        try await withArtworkDirectory {
            let root = "/music"
            let folders = ["A", "B"].map { name in
                ScannedFolder(path: root + "/" + name, audio: [scanEntry(root + "/" + name + "/Song.flac")], cover: nil)
            }
            let previous = Catalogue.build(folders: folders, rootPath: root, serverName: "NAS", driveID: "indexing-test", existing: nil)
            let drive = ReliabilityDrive(tree: [
                root: folders.map { scanEntry($0.path, directory: true) },
                folders[0].path: folders[0].audio
            ], failingPath: folders[1].path, failure: failure)
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var visible = previous
            var publications = 0
            indexer.start(drive: drive, rootPath: root, serverName: "NAS", existing: previous) {
                visible = $0
                publications += 1
            }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .failed(.unreadable(count: 1, path: root)))
            #expect(indexer.listingFailures == 1)
            #expect(publications == 0)
            #expect(visible.trackCount == 2)
            #expect(visible.indexedAt == previous.indexedAt)
        }
    }

    @Test func completeEmptyRefreshCanRemoveDeletedTracks() async throws {
        try await withArtworkDirectory {
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications: [Catalogue] = []
            indexer.start(drive: ReliabilityDrive(tree: ["/music": []]), rootPath: "/music", serverName: "NAS", existing: .empty) {
                publications.append($0)
            }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .done)
            #expect(publications.count == 1)
            #expect(publications.first?.isEmpty == true)
        }
    }

    @Test func cancelledEnrichmentCannotPublishOrWriteArtwork() async throws {
        try await withArtworkDirectory {
            let gate = IndexingTestGate()
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications = 0
            let drive = ReliabilityDrive(tree: ["/old": [scanEntry("/old/Song.flac")]], readGate: gate)
            indexer.start(drive: drive, rootPath: "/old", serverName: "Old NAS", existing: nil) { _ in publications += 1 }
            try await waitForIndexing { await gate.entered }
            #expect(indexer.phase == .enriching)
            #expect(publications == 1)
            indexer.cancel()
            await gate.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(indexer.phase == .idle)
            #expect(publications == 1)
            #expect(indexer.enrichedCount == 0)
            #expect(!FileManager.default.fileExists(atPath: CoverStore.directory.path))
        }
    }

    @Test(arguments: ["/old", "/new-folder"])
    func newerScanOwnsStateAfterDelayedEnrichment(root: String) async throws {
        try await withArtworkDirectory {
            let gate = IndexingTestGate()
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications: [String] = []
            indexer.start(drive: ReliabilityDrive(id: "old", tree: ["/old": [scanEntry("/old/Song.flac")]], readGate: gate),
                          rootPath: "/old", serverName: "Old NAS", existing: nil) { publications.append($0.driveID) }
            try await waitForIndexing { await gate.entered }
            indexer.start(drive: ReliabilityDrive(id: "new", tree: [root: []]), rootPath: root,
                          serverName: "New NAS", existing: .empty) { publications.append($0.driveID) }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .done)
            await gate.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(publications == ["old", "new"])
            #expect(indexer.phase == .done)
            #expect(indexer.enrichedCount == 0)
            #expect(indexer.tracksFound == 0)
            #expect(indexer.coversTotal == 0)
        }
    }

    @Test func cancelledRootErrorCannotReplaceNewScanStatus() async throws {
        try await withArtworkDirectory {
            let gate = IndexingTestGate()
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            indexer.start(drive: ReliabilityDrive(tree: [:], failingPath: "/old", listingGate: gate),
                          rootPath: "/old", serverName: "Old NAS", existing: nil) { _ in Issue.record("Cancelled scan published") }
            try await waitForIndexing { await gate.entered }
            indexer.start(drive: ReliabilityDrive(tree: ["/new": []]), rootPath: "/new", serverName: "New NAS", existing: .empty) { _ in }
            try await waitForIndexing { !indexer.isRunning }
            await gate.release()
            try await Task.sleep(for: .milliseconds(100))
            #expect(indexer.phase == .done)
            #expect(indexer.listingFailures == 0)
        }
    }

    @Test func cancellationInsideCatalogueCallbackStopsEnrichment() async throws {
        try await withArtworkDirectory {
            let indexer = LibraryIndexer(recordDiagnostics: { _ in })
            var publications = 0
            indexer.start(drive: ReliabilityDrive(tree: ["/music": [scanEntry("/music/Song.flac")]]),
                          rootPath: "/music", serverName: "NAS", existing: nil) { _ in
                publications += 1
                indexer.cancel()
            }
            try await waitForIndexing { !indexer.isRunning }
            #expect(indexer.phase == .idle)
            #expect(publications == 1)
        }
    }
}
