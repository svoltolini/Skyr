import Foundation
import Observation
import SkyrCore

/// Fetches a playlist's songs from the server straight onto the watch, through a background
/// session so a download carries on after the app leaves the screen. Files live under
/// Application Support, one folder per playlist, with a manifest of which song is which file.
@Observable
@MainActor
final class WatchDownloads: NSObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case none
        case downloading(done: Int, total: Int)
        case downloaded
        case failed(String)
    }

    static let shared = WatchDownloads()
    nonisolated static let sessionIdentifier = "com.samuelvoltolini.skyr.watch.downloads"

    private(set) var states: [String: State] = [:]
    /// Playlist id → (track id → file name).
    private var manifests: [String: [String: String]] = [:]
    /// Track ids still expected per playlist while a download runs.
    private var expected: [String: Set<String>] = [:]
    private var backgroundCompletion: (() -> Void)?

    private nonisolated static let root = AppDirectories.support.appending(path: "Skyr/watch-playlists", directoryHint: .isDirectory)
    private nonisolated static let manifestURL = root.appending(path: "manifests.json")

    @ObservationIgnored private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.allowsCellularAccess = true
        configuration.timeoutIntervalForResource = 60 * 60 * 6
        return URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }()

    override init() {
        super.init()
        if let data = try? Data(contentsOf: Self.manifestURL), let saved = try? JSONDecoder().decode([String: [String: String]].self, from: data) {
            manifests = saved
            for id in saved.keys { states[id] = .downloaded }
        }
    }

    func state(of playlist: WatchPlaylist) -> State { states[playlist.id] ?? .none }

    func isDownloaded(_ playlist: WatchPlaylist) -> Bool {
        if case .downloaded = state(of: playlist) { return true }
        return false
    }

    /// Local files in the playlist's own order, for playback.
    func files(for playlist: WatchPlaylist) -> [(track: WatchTrack, url: URL)] {
        guard let manifest = manifests[playlist.id] else { return [] }
        return playlist.tracks.compactMap { track in
            manifest[track.id].map { (track, Self.root.appending(path: playlist.id).appending(path: $0)) }
        }
    }

    var bytesOnWatch: Int64 {
        guard let items = try? FileManager.default.enumerator(at: Self.root, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in items {
            total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }

    /// Signs in and queues every song the watch does not have yet.
    func download(_ playlist: WatchPlaylist, credentials: WatchCredentials) async {
        let have = manifests[playlist.id] ?? [:]
        let missing = playlist.tracks.filter { have[$0.id] == nil }
        guard !missing.isEmpty else { states[playlist.id] = .downloaded; return }
        states[playlist.id] = .downloading(done: 0, total: missing.count)
        expected[playlist.id] = Set(missing.map(\.id))
        do {
            let dsm = try await SynologyClient.login(baseURL: credentials.baseURL, account: credentials.account, password: credentials.password, otpCode: nil)
            let drive = SynologyDrive(session: dsm, displayName: "NAS")
            try FileManager.default.createDirectory(at: Self.root.appending(path: playlist.id), withIntermediateDirectories: true)
            for track in missing {
                guard let url = drive.streamURL(for: track.path) else { continue }
                let task = session.downloadTask(with: url)
                task.taskDescription = "\(playlist.id)|\(track.id)|\(track.fileExtension)"
                task.resume()
            }
        } catch {
            states[playlist.id] = .failed(error.localizedDescription)
            expected[playlist.id] = nil
        }
    }

    func cancel(_ playlist: WatchPlaylist) {
        expected[playlist.id] = nil
        session.getAllTasks { @Sendable tasks in
            for task in tasks where task.taskDescription?.hasPrefix(playlist.id + "|") == true { task.cancel() }
        }
        remove(playlist)
    }

    func remove(_ playlist: WatchPlaylist) {
        try? FileManager.default.removeItem(at: Self.root.appending(path: playlist.id))
        manifests[playlist.id] = nil
        states[playlist.id] = .none
        saveManifests()
    }

    /// Called when the system relaunches the app for the session's finished transfers.
    func reconnect(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionIdentifier else { completion(); return }
        backgroundCompletion = completion
        _ = session
    }

    private func record(playlistID: String, trackID: String, fileName: String) {
        manifests[playlistID, default: [:]][trackID] = fileName
        expected[playlistID]?.remove(trackID)
        saveManifests()
        updateState(playlistID)
    }

    private func fail(playlistID: String, trackID: String, message: String) {
        expected[playlistID]?.remove(trackID)
        if case .downloading = states[playlistID] { states[playlistID] = .failed(message) }
    }

    private func updateState(_ playlistID: String) {
        guard let remaining = expected[playlistID] else { return }
        if case .downloading(_, let total) = states[playlistID] {
            if remaining.isEmpty {
                states[playlistID] = .downloaded
                expected[playlistID] = nil
            } else {
                states[playlistID] = .downloading(done: total - remaining.count, total: total)
            }
        }
    }

    private func saveManifests() {
        try? FileManager.default.createDirectory(at: Self.root, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(manifests) { try? data.write(to: Self.manifestURL, options: .atomic) }
    }

    // MARK: URLSessionDownloadDelegate

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is gone once this returns, so it is moved here, before any actor hop.
        guard let parts = downloadTask.taskDescription?.split(separator: "|"), parts.count == 3 else { return }
        let playlistID = String(parts[0]), trackID = String(parts[1]), ext = String(parts[2])
        if let response = downloadTask.response as? HTTPURLResponse, response.statusCode != 200 {
            Task { @MainActor in self.fail(playlistID: playlistID, trackID: trackID, message: "The server answered \(response.statusCode).") }
            return
        }
        let fileName = "\(trackID).\(ext)"
        let folder = Self.root.appending(path: playlistID)
        let destination = folder.appending(path: fileName)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            Task { @MainActor in self.fail(playlistID: playlistID, trackID: trackID, message: error.localizedDescription) }
            return
        }
        Task { @MainActor in self.record(playlistID: playlistID, trackID: trackID, fileName: fileName) }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let parts = task.taskDescription?.split(separator: "|"), parts.count == 3 else { return }
        let playlistID = String(parts[0]), trackID = String(parts[1])
        let message = error.localizedDescription
        Task { @MainActor in self.fail(playlistID: playlistID, trackID: trackID, message: message) }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletion?()
            self.backgroundCompletion = nil
        }
    }
}
