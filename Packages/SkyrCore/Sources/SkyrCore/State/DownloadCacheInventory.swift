import Foundation

/// What the downloads folder actually holds, read in one pass. The manifest says which files the
/// app knows about; this says which files exist, so the two can be reconciled after a reinstall,
/// a restored backup, or an interrupted transfer left the folder and the manifest disagreeing.
nonisolated struct DownloadCacheInventory: Sendable {
    /// One file in the folder: a finished song, a partial transfer, or something the app never wrote.
    struct File: Hashable, Sendable {
        let fileName: String
        let bytes: Int64
        /// The song the file was saved for, read back from its name; nil for partial transfers and strangers.
        let cacheKey: String?
        /// Data still being received when it was written; only its transfer knows whether it is complete.
        let isIncoming: Bool
    }

    private(set) var files: [File] = []
    /// Finished files by the song they hold; a song retried after a crash can have more than one.
    private(set) var filesByKey: [String: [File]] = [:]

    /// The manager's own documents, which live next to the songs.
    static let bookkeepingFiles: Set<String> = ["downloads.json", "pending.json", "download-intent.json"]
    static let incomingPrefix = "incoming-"

    var totalBytes: Int64 { files.reduce(0) { $0 + $1.bytes } }

    static func read(directory: URL) -> DownloadCacheInventory {
        var inventory = DownloadCacheInventory()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]) else {
            return inventory
        }
        for url in urls {
            let name = url.lastPathComponent
            guard !bookkeepingFiles.contains(name), let values = try? url.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            let file = File(fileName: name, bytes: Int64(values.fileSize ?? 0), cacheKey: cacheKey(inFileName: name),
                            isIncoming: name.hasPrefix(incomingPrefix))
            inventory.files.append(file)
            if let key = file.cacheKey { inventory.filesByKey[key, default: []].append(file) }
        }
        inventory.files.sort { $0.fileName < $1.fileName }
        return inventory
    }

    /// Reads the song identity the downloader wrote into a finished file's name: `<attempt>-<key>.<ext>`
    /// since transfers were isolated by attempt, `<key>.<ext>` before that. The key is the same
    /// digest `DownloadManager.cacheKey(trackID:driveID:)` gives, so a song can be found again from
    /// the catalogue alone. Partial transfers hash their attempt into the name and cannot be read back.
    static func cacheKey(inFileName name: String) -> String? {
        guard !name.hasPrefix(incomingPrefix) else { return nil }
        var stem = Substring(name)
        if let dot = stem.lastIndex(of: ".") {
            let ext = stem[stem.index(after: dot)...]
            guard !ext.isEmpty, ext.count <= 12, ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) }) else { return nil }
            stem = stem[..<dot]
        }
        guard stem.count >= 64 else { return nil }
        let key = stem.suffix(64)
        guard key.allSatisfy({ ("0"..."9").contains($0) || ("a"..."f").contains($0) }) else { return nil }
        let prefix = stem.dropLast(64)
        guard prefix.isEmpty || prefix.last == "-" else { return nil }
        return String(key)
    }
}
