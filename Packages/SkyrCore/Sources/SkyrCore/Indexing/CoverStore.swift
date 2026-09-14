import CryptoKit
import Foundation

/// Album covers extracted from files or downloaded from the drive, kept on disk.
public nonisolated enum CoverStore {
    @TaskLocal static var indexingRun: IndexingRun?
    /// Allows isolated indexing tests to use temporary storage, without touching the user's artwork.
    @TaskLocal static var directoryOverride: URL?
    private static let mutationLock = NSRecursiveLock()

    /// Resolved once: every cover lookup used to create the folder again, a file system call per artwork drawn.
    private static let defaultDirectory = AppDirectories.support
        .appending(path: "Skyr/covers", directoryHint: .isDirectory)
    public static var directory: URL { directoryOverride ?? defaultDirectory }

    private static func mutate(_ description: String, _ operation: () throws -> Void) {
        func write() {
            mutationLock.withLock {
                do {
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try operation()
                } catch {
                    diagnostics("Couldn't \(description): \(error.localizedDescription)")
                }
            }
        }
        if let indexingRun {
            indexingRun.whileActive(write)
        } else {
            write()
        }
    }

    private static func removeIfPresent(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    public static func fileURL(for albumID: String) -> URL {
        let digest = SHA256.hash(data: Data(albumID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).img")
    }

    public static func hasCover(for albumID: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: albumID).path)
    }

    public static func save(_ data: Data, for albumID: String) {
        let pair = CoverPalette.extract(from: data)
        mutate("save album artwork") {
            try data.write(to: fileURL(for: albumID), options: .atomic)
            try removeIfPresent(missingURL(for: albumID))
            if let pair {
                try JSONEncoder().encode(pair).write(to: paletteURL(for: albumID), options: .atomic)
            } else {
                try removeIfPresent(paletteURL(for: albumID))
            }
        }
    }

    public static func remove(for albumID: String) {
        mutate("remove album artwork") {
            try removeIfPresent(fileURL(for: albumID))
            try removeIfPresent(paletteURL(for: albumID))
            try removeIfPresent(missingURL(for: albumID))
        }
    }

    // MARK: Albums with no cover anywhere

    private static func missingURL(for albumID: String) -> URL {
        fileURL(for: albumID).deletingPathExtension().appendingPathExtension("missing")
    }

    /// Remembers that the folder, the files and the store had no picture, so the search is not repeated on every refresh.
    public static func noteMissingCover(for albumID: String) {
        mutate("record missing album artwork") {
            try Data().write(to: missingURL(for: albumID), options: .atomic)
        }
    }

    /// When the last fruitless search for this album's cover happened, if any.
    public static func missingCoverDate(for albumID: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: missingURL(for: albumID).path)[.modificationDate]) as? Date
    }

    public static func copy(from sourceID: String, to targetID: String) {
        mutate("copy album artwork") {
            let source = fileURL(for: sourceID)
            let target = fileURL(for: targetID)
            guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { return }
            try FileManager.default.copyItem(at: source, to: target)
            if FileManager.default.fileExists(atPath: paletteURL(for: sourceID).path) {
                try removeIfPresent(paletteURL(for: targetID))
                try FileManager.default.copyItem(at: paletteURL(for: sourceID), to: paletteURL(for: targetID))
            }
        }
    }

    // MARK: Palettes

    /// Colours read from the cover, kept next to it.
    public static func paletteURL(for albumID: String) -> URL {
        fileURL(for: albumID).deletingPathExtension().appendingPathExtension("palette")
    }

    public static func palette(for albumID: String) -> CoverPalette.Pair? {
        guard let data = try? Data(contentsOf: paletteURL(for: albumID)) else { return nil }
        return try? JSONDecoder().decode(CoverPalette.Pair.self, from: data)
    }

    public static func savePalette(_ pair: CoverPalette.Pair, for albumID: String) {
        mutate("save artwork colours") {
            try JSONEncoder().encode(pair).write(to: paletteURL(for: albumID), options: .atomic)
        }
    }

    public static func storedPalettes(for albumIDs: Set<String>) -> [String: CoverPalette.Pair] {
        var result: [String: CoverPalette.Pair] = [:]
        for id in albumIDs {
            if let pair = palette(for: id) { result[id] = pair }
        }
        return result
    }

    /// Reads the colours of covers that were saved before palettes existed, storing them for next time.
    public static func computePalettes(for albumIDs: Set<String>) -> [String: CoverPalette.Pair] {
        var result: [String: CoverPalette.Pair] = [:]
        for id in albumIDs {
            guard let data = try? Data(contentsOf: fileURL(for: id)), let pair = CoverPalette.extract(from: data) else { continue }
            savePalette(pair, for: id)
            result[id] = pair
        }
        return result
    }

    public static func clear() {
        mutate("clear the artwork cache") {
            try removeIfPresent(directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    // MARK: Covers found inside files, kept per song until albums settle

    /// Embedded pictures are saved per song while tags are still being read, because the album a
    /// song ends up in can change as more tags arrive. Once albums are final these are removed.
    private static var trackDirectory: URL {
        directory.appending(path: "tracks", directoryHint: .isDirectory)
    }

    private static func trackCoverURL(for trackID: String) -> URL {
        let digest = SHA256.hash(data: Data(trackID.utf8)).map { String(format: "%02x", $0) }.joined()
        return trackDirectory.appending(path: "\(digest).img")
    }

    public static func saveTrackCover(_ data: Data, for trackID: String) {
        mutate("save song artwork") {
            try FileManager.default.createDirectory(at: trackDirectory, withIntermediateDirectories: true)
            try data.write(to: trackCoverURL(for: trackID), options: .atomic)
        }
    }

    public static func hasTrackCover(for trackID: String) -> Bool {
        FileManager.default.fileExists(atPath: trackCoverURL(for: trackID).path)
    }

    /// Promotes a song's embedded picture to its album's cover, palette included.
    public static func adoptTrackCover(from trackID: String, for albumID: String) {
        guard let data = try? Data(contentsOf: trackCoverURL(for: trackID)) else { return }
        save(data, for: albumID)
    }

    public static func clearTrackCovers() {
        mutate("clear temporary song artwork") {
            try removeIfPresent(trackDirectory)
        }
    }

    /// Album ids that already have a cover on disk.
    public static func coveredAlbumIDs(among albums: [Album]) -> Set<String> {
        Set(albums.filter { hasCover(for: $0.id) }.map(\.id))
    }

    /// Hashes of the covers already on disk, grouped by lowercased artist, to spot repeated pictures.
    public static func hashesByArtist(among albums: [Album]) -> [String: Set<String>] {
        var result: [String: Set<String>] = [:]
        for album in albums where hasCover(for: album.id) {
            if let data = try? Data(contentsOf: fileURL(for: album.id)) {
                result[album.artist.lowercased(), default: []].insert(ArtworkLookup.hash(data))
            }
        }
        return result
    }
}
