import AppIntents
import Foundation

/// The play button on a widget cover. Audio playback intents are performed by the app itself, which
/// the system launches in the background when it is not running, so the music starts without
/// anything opening on screen.
struct PlayAlbumIntent: AudioPlaybackIntent {
    static let title: LocalizedStringResource = "Play Album"
    static let description = IntentDescription("Plays an album from your Skyr library, or pauses it when it is already playing.")
    static let isDiscoverable = false

    @Parameter(title: "Album")
    var albumID: String

    init() {}

    init(albumID: String) {
        self.albumID = albumID
    }

    func perform() async throws -> some IntentResult {
        await PlaybackIntentBridge.perform(albumID: albumID)
        return .result()
    }
}

/// The app installs the handler at launch; the widget extension never performs the intent itself.
@MainActor
enum PlaybackIntentBridge {
    static var handler: ((String) async -> Void)?

    static func perform(albumID: String) async {
        await handler?(albumID)
    }
}
