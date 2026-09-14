import Foundation

/// Where the app keeps its own files. Apple TV promises almost no persistent storage, so its copy
/// lives in Caches and is rebuilt from iCloud and the server whenever the system clears it.
public nonisolated enum AppDirectories {
    public static let support: URL = {
        #if os(tvOS)
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        #else
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #endif
    }()
}
