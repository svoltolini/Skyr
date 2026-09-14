import Foundation

/// One entry of a directory listing on a remote drive.
public nonisolated struct RemoteEntry: Hashable, Sendable, Identifiable {
    public let path: String
    public let name: String
    public let isDirectory: Bool
    public let size: Int64?
    public let modified: Date?

    public var id: String { path }
    public var fileExtension: String { (name as NSString).pathExtension.lowercased() }
    public var isAudio: Bool { !isDirectory && RemoteDriveSupport.audioExtensions.contains(fileExtension) }
    public var isImage: Bool { !isDirectory && RemoteDriveSupport.imageExtensions.contains(fileExtension) }
}

/// A remote file system the app can index and stream music from.
public nonisolated protocol RemoteDrive: Sendable {
    /// Stable identifier used for caches, e.g. the server host plus account.
    var id: String { get }
    var displayName: String { get }

    /// Top-level locations the user can pick a music folder from.
    func roots() async throws -> [RemoteEntry]
    /// One directory level, files and folders.
    func list(_ path: String) async throws -> [RemoteEntry]
    /// Reads `range` of a file; used for tag parsing.
    func read(_ path: String, range: Range<Int64>) async throws -> Data
    /// Downloads a whole file into memory; used for cover images.
    func download(_ path: String, maxBytes: Int64) async throws -> Data
    /// A URL AVPlayer can stream, including any credentials it needs.
    func streamURL(for path: String) -> URL?
}

nonisolated extension Error {
    /// True when the drive reports that a path no longer exists.
    public var isMissingPath: Bool {
        if let synology = self as? SynologyError, case .api(let code, _) = synology { return code == 408 }
        return false
    }
}

public nonisolated enum RemoteDriveError: LocalizedError, Sendable {
    case notSignedIn
    case http(Int)
    case tooLarge
    case api(code: Int, api: String)

    public var errorDescription: String? {
        switch self {
        case .notSignedIn: "Sign in to the server first."
        case .http(let status): "The server answered with HTTP \(status)."
        case .tooLarge: "The file is too large to read."
        case .api(let code, let api): "\(api) failed with error \(code)."
        }
    }
}

public nonisolated enum RemoteDriveSupport {
    public static let audioExtensions: Set<String> = ["flac", "mp3", "m4a", "aac", "alac", "wav", "aif", "aiff", "ogg", "oga", "opus", "wma", "ape", "wv", "dsf", "dff", "mp4", "caf"]
    public static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic"]
    /// Image file names that conventionally hold album art, in order of preference.
    public static let coverNames = ["cover", "folder", "front", "album", "albumart", "artwork", "thumb"]

    /// Picks the image most likely to be the album cover from a folder listing.
    public static func coverImage(in entries: [RemoteEntry]) -> RemoteEntry? {
        let images = entries.filter(\.isImage)
        for name in coverNames {
            if let hit = images.first(where: { ($0.name as NSString).deletingPathExtension.lowercased() == name }) { return hit }
        }
        for name in coverNames {
            if let hit = images.first(where: { $0.name.lowercased().contains(name) }) { return hit }
        }
        return images.count == 1 ? images[0] : nil
    }
}
