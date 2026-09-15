import Foundation

public nonisolated enum DownloadOutcome: String, Codable, Hashable, Sendable {
    case downloading, downloaded, partial, failed, cancelled
}

/// Saved-song counts, rather than the number of unfinished tasks, determine completion.
public nonisolated struct DownloadProgress: Codable, Hashable, Sendable {
    public var fraction: Double
    public var done: Int
    public var total: Int
    public var currentTitle: String
    public var outcome: DownloadOutcome

    public init(fraction: Double, done: Int, total: Int, currentTitle: String, outcome: DownloadOutcome = .downloading) {
        self.fraction = min(1, max(0, fraction))
        self.done = done
        self.total = total
        self.currentTitle = currentTitle
        self.outcome = outcome
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        fraction = try values.decode(Double.self, forKey: .fraction)
        done = try values.decode(Int.self, forKey: .done)
        total = try values.decode(Int.self, forKey: .total)
        currentTitle = try values.decode(String.self, forKey: .currentTitle)
        outcome = try values.decodeIfPresent(DownloadOutcome.self, forKey: .outcome)
            ?? (total > 0 && done == total ? .downloaded : .downloading)
    }

    public var statusLine: String {
        switch outcome {
        case .downloaded: "Downloaded · \(done) songs"
        case .failed: "Download failed · Retry in Skyr"
        case .partial: "\(done) of \(total) saved · Retry in Skyr"
        case .cancelled: "Cancelled · \(done) of \(total) saved"
        case .downloading:
            currentTitle.isEmpty ? "\(done) of \(total) songs saved" : "\(done) of \(total) saved · \(currentTitle)"
        }
    }
}

#if os(iOS)
import ActivityKit

/// Live Activity payload for an album or playlist download: what is fixed when it starts, and what changes as songs land.
public nonisolated struct DownloadActivityAttributes: ActivityAttributes {
    public typealias ContentState = DownloadProgress

    public var title: String
    /// The artist for an album, "Playlist" for a playlist.
    public var subtitle: String
    /// Where a tap on the activity lands: the player for the song playing now, otherwise the album or
    /// playlist being saved. Optional so activities started by an earlier build still decode.
    public var link: URL?

    public init(title: String, subtitle: String, link: URL? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.link = link
    }

    /// The link to open, with the plain player link for activities from before links were carried.
    public var openURL: URL { link ?? WidgetLink.nowPlaying() }
}
#endif
