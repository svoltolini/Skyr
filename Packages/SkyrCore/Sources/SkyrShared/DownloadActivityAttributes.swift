#if os(iOS)
import ActivityKit
import Foundation

/// Live Activity payload for an album or playlist download: what is fixed when it starts, and what changes as songs land.
public nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    public nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// 0…1 across the whole album or playlist.
        public var fraction: Double
        public var done: Int
        public var total: Int
        /// The song coming down right now, or empty once everything is there.
        public var currentTitle: String

        public init(fraction: Double, done: Int, total: Int, currentTitle: String) {
            self.fraction = fraction
            self.done = done
            self.total = total
            self.currentTitle = currentTitle
        }
    }

    public var title: String
    /// The artist for an album, "Playlist" for a playlist.
    public var subtitle: String

    public init(title: String, subtitle: String) {
        self.title = title
        self.subtitle = subtitle
    }
}
#endif
