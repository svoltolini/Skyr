import Foundation
import Testing
@testable import SkyrCore

/// A drive made of a dictionary: path → entries.
final class FakeDrive: RemoteDrive, @unchecked Sendable {
    let id = "fake"
    let displayName = "Fake drive"
    let tree: [String: [RemoteEntry]]

    init(tree: [String: [RemoteEntry]]) { self.tree = tree }

    func roots() async throws -> [RemoteEntry] { tree["/"] ?? [] }
    func list(_ path: String) async throws -> [RemoteEntry] { tree[path] ?? [] }
    func read(_ path: String, range: Range<Int64>) async throws -> Data { throw URLError(.badServerResponse) }
    func download(_ path: String, maxBytes: Int64) async throws -> Data { throw URLError(.badServerResponse) }
    func streamURL(for path: String) -> URL? { nil }
}

private func entry(_ path: String, directory: Bool) -> RemoteEntry {
    RemoteEntry(path: path, name: (path as NSString).lastPathComponent, isDirectory: directory, size: directory ? nil : 5_000_000, modified: nil)
}

/// A root with one subfolder holding album folders must come back as albums, not as an empty library.
@Test @MainActor func scanWalksNestedFolders() async throws {
    let root = "/Skyr/Music Albuns"
    var tree: [String: [RemoteEntry]] = [:]
    tree[root] = [entry(root + "/Apple Music", directory: true)]
    let albums = (0..<3).map { root + "/Apple Music/Album \($0)" }
    tree[root + "/Apple Music"] = albums.map { entry($0, directory: true) }
    for album in albums {
        tree[album] = (1...4).map { entry("\(album)/0\($0) Song.m4a", directory: false) }
    }
    let indexer = LibraryIndexer(recordDiagnostics: { _ in })
    defer { indexer.cancel() }
    var received: Catalogue?
    indexer.start(drive: FakeDrive(tree: tree), rootPath: root, serverName: "Fake", existing: nil) { catalogue in
        if received == nil {
            received = catalogue
            indexer.cancel()
        }
    }
    // Wait for the scan to settle one way or the other, then report what it did.
    for _ in 0..<50 {
        if received != nil || !indexer.isRunning { break }
        try await Task.sleep(for: .milliseconds(100))
    }
    print("SCANDBG phase \(indexer.phase) folders \(indexer.foldersScanned) tracks \(indexer.tracksFound) albums \(received?.albums.count ?? -1)")
    #expect(received?.albums.count == 3, "three album folders should make three albums")
    #expect(received?.trackCount == 12)
}
