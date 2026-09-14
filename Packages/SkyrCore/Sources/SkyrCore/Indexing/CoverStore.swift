import CryptoKit
import Foundation

/// Album covers extracted from files or downloaded from the drive, kept on disk.
public nonisolated enum CoverStore {
    /// Resolved once: every cover lookup used to create the folder again, a file system call per artwork drawn.
    public static let directory: URL = {
        let base = AppDirectories.support
            .appending(path: "Skyr/covers", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    public static func fileURL(for albumID: String) -> URL {
        let digest = SHA256.hash(data: Data(albumID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "\(digest).img")
    }

    public static func hasCover(for albumID: String) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(for: albumID).path)
    }

    public static func save(_ data: Data, for albumID: String) {
        try? data.write(to: fileURL(for: albumID), options: .atomic)
        try? FileManager.default.removeItem(at: missingURL(for: albumID))
        if let pair = CoverPalette.extract(from: data) {
            savePalette(pair, for: albumID)
        } else {
            try? FileManager.default.removeItem(at: paletteURL(for: albumID))
        }
    }

    public static func remove(for albumID: String) {
        try? FileManager.default.removeItem(at: fileURL(for: albumID))
        try? FileManager.default.removeItem(at: paletteURL(for: albumID))
        try? FileManager.default.removeItem(at: missingURL(for: albumID))
    }

    // MARK: Albums with no cover anywhere

    private static func missingURL(for albumID: String) -> URL {
        fileURL(for: albumID).deletingPathExtension().appendingPathExtension("missing")
    }

    /// Remembers that the folder, the files and the store had no picture, so the search is not repeated on every refresh.
    public static func noteMissingCover(for albumID: String) {
        try? Data().write(to: missingURL(for: albumID))
    }

    /// When the last fruitless search for this album's cover happened, if any.
    public static func missingCoverDate(for albumID: String) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: missingURL(for: albumID).path)[.modificationDate]) as? Date
    }

    public static func copy(from sourceID: String, to targetID: String) {
        let source = fileURL(for: sourceID)
        let target = fileURL(for: targetID)
        guard FileManager.default.fileExists(atPath: source.path), !FileManager.default.fileExists(atPath: target.path) else { return }
        try? FileManager.default.copyItem(at: source, to: target)
        try? FileManager.default.copyItem(at: paletteURL(for: sourceID), to: paletteURL(for: targetID))
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
        guard let data = try? JSONEncoder().encode(pair) else { return }
        try? data.write(to: paletteURL(for: albumID), options: .atomic)
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
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Covers found inside files, kept per song until albums settle

    /// Embedded pictures are saved per song while tags are still being read, because the album a
    /// song ends up in can change as more tags arrive. Once albums are final these are removed.
    private static var trackDirectory: URL {
        let base = directory.appending(path: "tracks", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    private static func trackCoverURL(for trackID: String) -> URL {
        let digest = SHA256.hash(data: Data(trackID.utf8)).map { String(format: "%02x", $0) }.joined()
        return trackDirectory.appending(path: "\(digest).img")
    }

    public static func saveTrackCover(_ data: Data, for trackID: String) {
        try? data.write(to: trackCoverURL(for: trackID), options: .atomic)
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
        try? FileManager.default.removeItem(at: directory.appending(path: "tracks", directoryHint: .isDirectory))
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
