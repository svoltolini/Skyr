#if os(iOS)
import SkyrCore
import WatchConnectivity

/// Keeps a paired Apple Watch supplied with the playlists it may download and the sign-in it needs
/// to fetch them from the server itself. The catalogue travels as a file, the credentials as a
/// queued user-info payload; both are delivered even while the watch app is closed.
@MainActor
final class WatchBridge: NSObject, WCSessionDelegate {
    /// Asked for the current state whenever a sync is due.
    var provider: (() -> (catalogue: WatchCatalogue, credentials: WatchCredentials?)?)?
    private var lastCatalogueKey: Data?
    private var lastCredentials: WatchCredentials?

    override init() {
        super.init()
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Sends whatever changed since the last time; nothing when no watch is paired.
    func sync() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else {
            DiagnosticsLog.shared.record("Watch sync skipped: state \(session.activationState.rawValue), paired \(session.isPaired), app installed \(session.isWatchAppInstalled)")
            return
        }
        guard let state = provider?() else {
            DiagnosticsLog.shared.record("Watch sync skipped: nothing to send yet")
            return
        }
        let catalogue = state.catalogue
        if let key = catalogue.contentKey, key != lastCatalogueKey, let data = try? JSONEncoder().encode(catalogue) {
            let url = FileManager.default.temporaryDirectory.appending(path: "watch-catalogue-\(UUID().uuidString).json")
            if (try? data.write(to: url)) != nil {
                _ = session.transferFile(url, metadata: ["kind": "catalogue"])
                lastCatalogueKey = key
                DiagnosticsLog.shared.record("Watch sync: sent \(catalogue.playlists.count) playlists (\(data.count) bytes)")
            }
        }
        if let credentials = state.credentials, credentials != lastCredentials {
            _ = session.transferUserInfo([
                "kind": "credentials",
                "baseURL": credentials.baseURL.absoluteString,
                "account": credentials.account,
                "password": credentials.password,
            ])
            lastCredentials = credentials
        }
    }

    // MARK: WCSessionDelegate

    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: (any Error)?) {
        Task { @MainActor in self.sync() }
    }

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        // A new watch was paired; pick it up.
        session.activate()
    }

    nonisolated func sessionWatchStateDidChange(_ session: WCSession) {
        Task { @MainActor in
            self.lastCatalogueKey = nil
            self.lastCredentials = nil
            self.sync()
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message["kind"] as? String == "requestSync" else { return }
        Task { @MainActor in
            self.lastCatalogueKey = nil
            self.lastCredentials = nil
            self.sync()
        }
    }

    /// The watch app is open and asking: answer straight away with the catalogue and the sign-in.
    /// Live messages reach the watch everywhere, including the simulator, where queued transfers
    /// never arrive. Larger catalogues than a message can carry fall back to the queued file.
    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        nonisolated(unsafe) let reply = replyHandler
        guard message["kind"] as? String == "requestSync" else { reply([:]); return }
        Task { @MainActor in
            reply(self.syncReply())
            self.lastCatalogueKey = nil
            self.lastCredentials = nil
            self.sync()
        }
    }

    private func syncReply() -> [String: Any] {
        guard let state = provider?() else { return ["status": "notReady"] }
        var reply: [String: Any] = ["status": "ok"]
        if let data = try? JSONEncoder().encode(state.catalogue),
           let packed = try? (data as NSData).compressed(using: .lzfse) as Data, packed.count <= 60_000 {
            reply["catalogue"] = packed
            DiagnosticsLog.shared.record("Watch sync: answered with \(state.catalogue.playlists.count) playlists (\(packed.count) bytes packed)")
        } else {
            reply["status"] = "tooLarge"
            DiagnosticsLog.shared.record("Watch sync: catalogue too large for a message; queued as a file")
        }
        if let credentials = state.credentials {
            reply["baseURL"] = credentials.baseURL.absoluteString
            reply["account"] = credentials.account
            reply["password"] = credentials.password
        }
        return reply
    }

    nonisolated func session(_ session: WCSession, didFinish fileTransfer: WCSessionFileTransfer, error: (any Error)?) {
        try? FileManager.default.removeItem(at: fileTransfer.file.fileURL)
        let message = error.map { "Watch sync: catalogue transfer failed: \($0.localizedDescription)" } ?? "Watch sync: catalogue delivered"
        Task { @MainActor in DiagnosticsLog.shared.record(message) }
    }
}
#endif
