import Foundation
import Observation
import SkyrCore
import WatchConnectivity

/// What the phone has told the watch: the playlists it may download and the sign-in for the server.
/// The catalogue is kept on disk, the password in the Keychain, so both survive relaunches.
@Observable
@MainActor
final class WatchStore: NSObject, WCSessionDelegate {
    private(set) var catalogue: WatchCatalogue?
    private(set) var hasCredentials = false
    private(set) var isSample = false

    private static let catalogueURL = AppDirectories.support.appending(path: "Skyr/watch-catalogue.json")
    private static let accountKey = "watch.account"
    private static let baseURLKey = "watch.baseURL"
    private static let driveIDKey = "watch.driveID"

    override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.catalogueURL), let saved = try? JSONDecoder().decode(WatchCatalogue.self, from: data) {
            catalogue = saved
            WatchDownloads.shared.reconcile(saved)
        }
        hasCredentials = credentials() != nil
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// The server sign-in the phone handed over, or nil until it has.
    func credentials() -> WatchCredentials? {
        let defaults = UserDefaults.standard
        guard let account = defaults.string(forKey: Self.accountKey),
              let base = defaults.string(forKey: Self.baseURLKey), let url = URL(string: base),
              let password = KeychainStore.password(for: "watch|\(account)") else { return nil }
        return WatchCredentials(baseURL: url, account: account, password: password, driveID: defaults.string(forKey: Self.driveIDKey))
    }

    /// Asks the phone for everything, when it is within reach. The phone answers the message
    /// directly with the catalogue and the sign-in; queued transfers cover the times it cannot.
    func requestSync() {
        guard WCSession.isSupported(), WCSession.default.isReachable else { return }
        // These run on WatchConnectivity's own queue, so they must not be tied to the main actor.
        WCSession.default.sendMessage(["kind": "requestSync"], replyHandler: { @Sendable reply in
            let packed = reply["catalogue"] as? Data
            let status = reply["status"] as? String ?? "?"
            let base = reply["baseURL"] as? String
            let account = reply["account"] as? String
            let password = reply["password"] as? String
            let driveID = reply["driveID"] as? String
            Task { @MainActor in
                DiagnosticsLog.shared.record("Watch: sync answered, status \(status), \(packed?.count ?? 0) bytes")
                if let packed, let data = try? (packed as NSData).decompressed(using: .lzfse) as Data {
                    self.apply(catalogueData: data)
                }
                if let base, let url = URL(string: base), let account, let password {
                    self.apply(credentials: WatchCredentials(baseURL: url, account: account, password: password, driveID: driveID))
                }
            }
        }, errorHandler: { @Sendable error in
            let message = error.localizedDescription
            Task { @MainActor in DiagnosticsLog.shared.record("Watch: sync request failed: \(message)") }
        })
    }

    /// The demo playlists, for looking at the watch app without a phone or a server.
    func loadSample() {
        let playlists = SampleLibrary.playlists.map { playlist in
            WatchPlaylist(
                id: playlist.id, name: playlist.name, isSmart: playlist.kind == .smart,
                coverColours: playlist.covers.prefix(4).map { WatchColourPair(a: $0.colorA, b: $0.colorB) },
                tracks: playlist.tracks.prefix(WatchCatalogue.songLimit).map { track in
                    let album = SampleLibrary.catalogue.albums.first { $0.id == track.albumID }
                    return WatchTrack(
                        id: track.id, title: track.title, artist: track.artist ?? album?.artist ?? "",
                        album: album?.title ?? "", duration: track.duration,
                        path: track.path ?? "/music/\(track.id).flac", fileSize: track.fileSize ?? 28_000_000,
                        format: track.format, isLossless: track.isLossless
                    )
                },
                totalSongs: playlist.tracks.count
            )
        }
        catalogue = WatchCatalogue(serverName: SampleLibrary.serverName, profileName: "Me", playlists: playlists)
        isSample = true
        if let catalogue { WatchDownloads.shared.reconcile(catalogue) }
    }

    private func apply(catalogueData data: Data) {
        guard let received = try? JSONDecoder().decode(WatchCatalogue.self, from: data) else {
            DiagnosticsLog.shared.record("Watch: catalogue could not be read (\(data.count) bytes)")
            return
        }
        DiagnosticsLog.shared.record("Watch: received \(received.playlists.count) playlists")
        catalogue = received
        isSample = false
        WatchDownloads.shared.reconcile(received)
        try? FileManager.default.createDirectory(at: Self.catalogueURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.catalogueURL, options: .atomic)
    }

    private func apply(credentials: WatchCredentials) {
        let defaults = UserDefaults.standard
        if let previous = defaults.string(forKey: Self.accountKey), previous != credentials.account {
            KeychainStore.delete(account: "watch|\(previous)")
        }
        defaults.set(credentials.account, forKey: Self.accountKey)
        defaults.set(credentials.baseURL.absoluteString, forKey: Self.baseURLKey)
        defaults.set(credentials.driveID, forKey: Self.driveIDKey)
        KeychainStore.save(password: credentials.password, for: "watch|\(credentials.account)")
        hasCredentials = true
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.requestSync() }
    }

    nonisolated func session(_ session: WCSession, didReceive file: WCSessionFile) {
        // The file lives only for the length of this call: read it here, decode on the main actor.
        let kind = file.metadata?["kind"] as? String ?? "?"
        let data = try? Data(contentsOf: file.fileURL)
        Task { @MainActor in
            DiagnosticsLog.shared.record("Watch: file arrived, kind \(kind), \(data?.count ?? -1) bytes")
            guard kind == "catalogue", let data else { return }
            self.apply(catalogueData: data)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            if self.catalogue == nil { self.requestSync() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        guard userInfo["kind"] as? String == "credentials",
              let base = userInfo["baseURL"] as? String, let url = URL(string: base),
              let account = userInfo["account"] as? String, let password = userInfo["password"] as? String else { return }
        let credentials = WatchCredentials(baseURL: url, account: account, password: password, driveID: userInfo["driveID"] as? String)
        Task { @MainActor in self.apply(credentials: credentials) }
    }
}
