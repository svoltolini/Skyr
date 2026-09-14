#if os(iOS)
import ActivityKit
#endif
import CryptoKit
import Foundation
import SkyrShared

/// One file kept on this device for offline playback. Albums and playlists share files: the same song
/// downloaded for both is stored once and only goes when neither needs it any more.
public nonisolated struct DownloadRecord: Codable, Hashable, Sendable {
    public let trackID: String
    public let driveID: String
    /// Name inside the downloads folder; empty for the sample library, which only pretends.
    public let fileName: String
    public let bytes: Int64
    /// The albums and playlists this song was downloaded for, as `DownloadOwner` ids.
    public var owners: Set<String>

    public init(trackID: String, driveID: String, fileName: String, bytes: Int64, owners: Set<String>) {
        self.trackID = trackID
        self.driveID = driveID
        self.fileName = fileName
        self.bytes = bytes
        self.owners = owners
    }

    private enum LegacyKeys: String, CodingKey { case albumID }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        trackID = try container.decode(String.self, forKey: .trackID)
        driveID = try container.decode(String.self, forKey: .driveID)
        fileName = try container.decode(String.self, forKey: .fileName)
        bytes = try container.decode(Int64.self, forKey: .bytes)
        if let owners = try container.decodeIfPresent(Set<String>.self, forKey: .owners) {
            self.owners = owners
        } else if let albumID = try decoder.container(keyedBy: LegacyKeys.self).decodeIfPresent(String.self, forKey: .albumID) {
            // Manifests written before playlists could be downloaded only knew the album.
            owners = [DownloadOwner.albumPrefix + albumID]
        } else {
            owners = []
        }
    }
}

/// What a download was asked for: an album or a playlist, for one profile. Songs are shared
/// between owners, so two people keeping the same album store it once.
public nonisolated struct DownloadOwner: Hashable, Sendable {
    public static let albumPrefix = "album:"
    public static let playlistPrefix = "playlist:"

    public let id: String
    public let title: String
    public let subtitle: String
    public let tracks: [Track]

    public init(album: Album, profileID: String) {
        id = Self.scope(profileID) + Self.albumPrefix + album.id
        title = album.title
        subtitle = album.artist
        tracks = album.tracks
    }

    public init(playlist: Playlist, profileID: String) {
        id = Self.scope(profileID) + Self.playlistPrefix + playlist.id
        title = playlist.name
        subtitle = "Playlist"
        tracks = playlist.tracks
    }

    /// Owner ids start with the profile they belong to.
    public static func scope(_ profileID: String) -> String { "profile:\(profileID)|" }
}

/// What a download control should show.
public nonisolated enum DownloadState: Equatable, Sendable {
    case none
    case downloading(fraction: Double, done: Int, total: Int)
    case downloaded

    public var isDownloading: Bool {
        if case .downloading = self { return true }
        return false
    }
}

/// Everything the session needs to remember about a file, stored in the task description so it
/// survives the app being relaunched for a background session.
public nonisolated struct DownloadJob: Codable, Sendable {
    /// The album or playlist that queued the song; others can wait for the same file.
    public let ownerID: String
    public let trackID: String
    public let driveID: String
    public let fileName: String
    public let expectedBytes: Int64?
    public let ownerTitle: String
    public let ownerSubtitle: String
    public let trackTitle: String
    /// Songs in the album or playlist, for "3 of 12" style progress.
    public let ownerTrackCount: Int

    public init(ownerID: String, trackID: String, driveID: String, fileName: String, expectedBytes: Int64?, ownerTitle: String, ownerSubtitle: String, trackTitle: String, ownerTrackCount: Int) {
        self.ownerID = ownerID
        self.trackID = trackID
        self.driveID = driveID
        self.fileName = fileName
        self.expectedBytes = expectedBytes
        self.ownerTitle = ownerTitle
        self.ownerSubtitle = ownerSubtitle
        self.trackTitle = trackTitle
        self.ownerTrackCount = ownerTrackCount
    }

    private enum LegacyKeys: String, CodingKey { case albumID, albumTitle, artist, albumTrackCount }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        trackID = try container.decode(String.self, forKey: .trackID)
        driveID = try container.decode(String.self, forKey: .driveID)
        fileName = try container.decode(String.self, forKey: .fileName)
        expectedBytes = try container.decodeIfPresent(Int64.self, forKey: .expectedBytes)
        trackTitle = try container.decode(String.self, forKey: .trackTitle)
        // Tasks queued by an earlier version of the app described their album under other names.
        ownerID = try container.decodeIfPresent(String.self, forKey: .ownerID)
            ?? DownloadOwner.albumPrefix + (try legacy.decodeIfPresent(String.self, forKey: .albumID) ?? "")
        ownerTitle = try container.decodeIfPresent(String.self, forKey: .ownerTitle)
            ?? (try legacy.decodeIfPresent(String.self, forKey: .albumTitle)) ?? ""
        ownerSubtitle = try container.decodeIfPresent(String.self, forKey: .ownerSubtitle)
            ?? (try legacy.decodeIfPresent(String.self, forKey: .artist)) ?? ""
        ownerTrackCount = try container.decodeIfPresent(Int.self, forKey: .ownerTrackCount)
            ?? (try legacy.decodeIfPresent(Int.self, forKey: .albumTrackCount)) ?? 0
    }

    public var encoded: String? {
        (try? JSONEncoder().encode(self)).map { $0.base64EncodedString() }
    }

    public static func decode(_ description: String?) -> DownloadJob? {
        guard let description, let data = Data(base64Encoded: description) else { return nil }
        return try? JSONDecoder().decode(DownloadJob.self, from: data)
    }
}

/// Downloads albums and playlists one song at a time through a background session, so leaving the app
/// does not stop them, reports progress per song, shows a Live Activity, and hands the files back to
/// the player. A song already on the device is never fetched twice.
@Observable
public final class DownloadManager {
    public static let sessionIdentifier = "com.samuelvoltolini.skyr.downloads"
    /// Set by the app delegate when the system relaunches the app for session events.
    public static var backgroundCompletionHandler: (() -> Void)?

    public private(set) var records: [String: DownloadRecord] = [:]
    /// The profile whose downloads the screens show and new downloads belong to.
    public var activeProfileID = "default"
    /// 0…1 for every file currently coming down, by track id.
    public private(set) var progress: [String: Double] = [:]
    /// Albums and playlists with a download in flight and the track ids each still waits for.
    public private(set) var pendingByOwner: [String: Set<String>] = [:]
    public private(set) var lastError: String?

    private var session: URLSession?
    private let delegate = DownloadDelegate()
    private var jobs: [String: DownloadJob] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var simulations: [String: Task<Void, Never>] = [:]
    /// Order in which songs were queued; the session runs them one at a time in this order.
    private var order: [String] = []
    #if os(iOS)
    private var activity: Activity<DownloadActivityAttributes>?
    #endif
    private var activityOwnerID: String?
    private var lastActivityUpdate = Date.distantPast

    public init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        delegate.onProgress = { [weak self] trackID, fraction in
            Task { @MainActor in self?.update(trackID: trackID, fraction: fraction) }
        }
        delegate.onFinish = { [weak self] job, bytes, status, failure in
            Task { @MainActor in self?.finish(job: job, bytes: bytes, status: status, failure: failure) }
        }
        delegate.onError = { [weak self] job, message in
            Task { @MainActor in self?.fail(job: job, message: message) }
        }
        delegate.onEventsFinished = {
            Task { @MainActor in
                DownloadManager.backgroundCompletionHandler?()
                DownloadManager.backgroundCompletionHandler = nil
            }
        }
        records = Self.loadManifest()
        pruneMissingFiles()
        // Songs still queued from an earlier launch keep going; pick their bookkeeping back up.
        // Answered on the session's own queue, so the closure stays off the main actor and hands
        // the tasks across explicitly.
        session.getAllTasks { @Sendable [weak self] tasks in
            let found = tasks.compactMap { task -> (DownloadJob, URLSessionDownloadTask)? in
                guard let download = task as? URLSessionDownloadTask, let job = DownloadJob.decode(task.taskDescription) else { return nil }
                return (job, download)
            }
            nonisolated(unsafe) let restored = found
            Task { @MainActor in self?.restore(restored) }
        }
    }

    // MARK: Where files live

    public nonisolated static let directory: URL = {
        let base = AppDirectories.support
            .appending(path: "Skyr/downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var manifestURL: URL { directory.appending(path: "downloads.json") }

    public nonisolated static func fileName(for track: Track) -> String {
        let digest = SHA256.hash(data: Data(track.id.utf8)).map { String(format: "%02x", $0) }.joined()
        return track.fileExtension.isEmpty ? digest : "\(digest).\(track.fileExtension)"
    }

    // MARK: Reading state

    /// The song is on the device, whichever album or playlist brought it.
    public func isDownloaded(_ track: Track) -> Bool { records[track.id] != nil }

    /// The file on this device for a track, when it is there.
    public func localURL(for track: Track) -> URL? {
        guard let record = records[track.id], !record.fileName.isEmpty else { return nil }
        let url = Self.directory.appending(path: record.fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    public func owner(for album: Album) -> DownloadOwner { DownloadOwner(album: album, profileID: activeProfileID) }
    public func owner(for playlist: Playlist) -> DownloadOwner { DownloadOwner(playlist: playlist, profileID: activeProfileID) }

    /// Downloads made before profiles existed belong to the first profile from now on.
    public func adoptLegacyOwners(into profileID: String) {
        var changed = false
        for (trackID, var record) in records {
            let owners = Set(record.owners.map { $0.hasPrefix("profile:") ? $0 : DownloadOwner.scope(profileID) + $0 })
            if owners != record.owners {
                record.owners = owners
                records[trackID] = record
                changed = true
            }
        }
        if changed { saveManifest() }
    }

    /// Ids of every album and playlist that asked for a download and still has songs here or on the way.
    public var listedOwnerIDs: Set<String> {
        var ids = Set(pendingByOwner.keys)
        for record in records.values { ids.formUnion(record.owners) }
        return ids
    }

    /// Songs of the album or playlist that it has on the device.
    public func downloadedCount(for owner: DownloadOwner) -> Int {
        owner.tracks.filter { records[$0.id]?.owners.contains(owner.id) == true }.count
    }

    public func state(for owner: DownloadOwner) -> DownloadState {
        let tracks = owner.tracks
        guard !tracks.isEmpty else { return .none }
        let done = downloadedCount(for: owner)
        if done == tracks.count { return .downloaded }
        guard let pending = pendingByOwner[owner.id] else { return .none }
        let inFlight = tracks.filter { pending.contains($0.id) }.reduce(0.0) { $0 + (progress[$1.id] ?? 0) }
        return .downloading(fraction: (Double(done) + inFlight) / Double(tracks.count), done: done, total: tracks.count)
    }

    public var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    /// A song that is queued but whose file has not started coming down yet.
    public func isQueued(_ track: Track) -> Bool {
        jobs[track.id] != nil && progress[track.id] == nil
    }

    // MARK: Downloading

    /// Keeps every song of the album or playlist on the device. Songs already here are shared at once,
    /// songs already on their way for another owner are waited for, and the rest are queued to come
    /// down strictly one at a time. Without a URL for a song (the sample library) the download is only simulated.
    public func download(_ owner: DownloadOwner, driveID: String, url: (Track) -> URL?) {
        lastError = nil
        guard let session else { return }
        var pending = pendingByOwner[owner.id] ?? []
        var shared = 0
        var queued = 0
        for track in owner.tracks {
            if var record = records[track.id] {
                if record.owners.insert(owner.id).inserted {
                    records[track.id] = record
                    shared += 1
                }
                continue
            }
            if jobs[track.id] != nil {
                pending.insert(track.id)
                continue
            }
            let job = DownloadJob(
                ownerID: owner.id, trackID: track.id, driveID: driveID, fileName: Self.fileName(for: track),
                expectedBytes: track.fileSize, ownerTitle: owner.title, ownerSubtitle: owner.subtitle,
                trackTitle: track.title, ownerTrackCount: owner.tracks.count
            )
            jobs[track.id] = job
            pending.insert(track.id)
            order.append(track.id)
            queued += 1
            if let source = url(track) {
                let task = session.downloadTask(with: source)
                task.taskDescription = job.encoded
                tasks[track.id] = task
            } else {
                progress[track.id] = 0
                simulate(track)
            }
        }
        if !pending.isEmpty { pendingByOwner[owner.id] = pending }
        if shared > 0 { saveManifest() }
        diagnostics("“\(owner.title)”: queued \(queued) songs, \(shared) already on this iPhone")
        startNextIfIdle()
        refreshActivity(force: true)
    }

    /// Starts the first waiting task when nothing is running, so files come down one after another.
    private func startNextIfIdle() {
        guard !tasks.values.contains(where: { $0.state == .running }) else { return }
        for trackID in order {
            guard let task = tasks[trackID], task.state == .suspended else { continue }
            progress[trackID] = 0
            task.resume()
            return
        }
    }

    /// Stops what is still on its way for the album or playlist; songs another owner also waits for keep coming.
    public func cancel(_ owner: DownloadOwner) {
        guard let pending = pendingByOwner[owner.id] else { return }
        pendingByOwner[owner.id] = nil
        for trackID in pending {
            let wantedElsewhere = pendingByOwner.values.contains { $0.contains(trackID) }
            guard !wantedElsewhere else { continue }
            tasks[trackID]?.cancel()
            if let simulation = simulations[trackID] {
                simulation.cancel()
                if let job = jobs[trackID] { fail(job: job, message: nil) }
            }
        }
        refreshActivity(force: true)
    }

    /// Lets the album or playlist go; files no other download still needs are deleted from the device.
    public func remove(_ owner: DownloadOwner) {
        cancel(owner)
        var deleted = 0
        var kept = 0
        for (trackID, var record) in records where record.owners.contains(owner.id) {
            record.owners.remove(owner.id)
            if record.owners.isEmpty {
                records[trackID] = nil
                if !record.fileName.isEmpty {
                    try? FileManager.default.removeItem(at: Self.directory.appending(path: record.fileName))
                }
                deleted += 1
            } else {
                records[trackID] = record
                kept += 1
            }
        }
        saveManifest()
        diagnostics("Removed the download of “\(owner.title)”: \(deleted) files deleted, \(kept) still used by other downloads")
    }

    private func simulate(_ track: Track) {
        simulations[track.id] = Task { [weak self] in
            // Wait for earlier simulated songs so the demo also goes one at a time.
            while let self, let first = order.first(where: { simulations[$0] != nil }), first != track.id, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 40...90)))
                guard !Task.isCancelled, let self else { return }
                update(trackID: track.id, fraction: Double(step) / Double(steps))
            }
            guard !Task.isCancelled, let self, let job = jobs[track.id] else { return }
            simulations[track.id] = nil
            finish(job: job, bytes: track.fileSize ?? 0, status: 200, failure: nil)
        }
    }

    private func restore(_ restored: [(DownloadJob, URLSessionDownloadTask)]) {
        guard !restored.isEmpty else { return }
        for (job, task) in restored where records[job.trackID] == nil && jobs[job.trackID] == nil {
            jobs[job.trackID] = job
            tasks[job.trackID] = task
            if task.state == .running { progress[job.trackID] = 0 }
            order.append(job.trackID)
            pendingByOwner[job.ownerID, default: []].insert(job.trackID)
        }
        diagnostics("Picked up \(restored.count) downloads still queued from the last launch")
        startNextIfIdle()
        refreshActivity(force: true)
    }

    // MARK: Results from the session

    private func update(trackID: String, fraction: Double) {
        guard progress[trackID] != nil else { return }
        progress[trackID] = min(1, max(0, fraction))
        refreshActivity(force: false)
    }

    private func finish(job: DownloadJob, bytes: Int64, status: Int, failure: String?) {
        let destination = Self.directory.appending(path: job.fileName)
        let simulated = simulations[job.trackID] != nil || tasks[job.trackID] == nil && !FileManager.default.fileExists(atPath: destination.path)
        var problem = failure
        if problem == nil, status >= 400 { problem = "The server answered with HTTP \(status)." }
        if !simulated {
            if problem == nil, let expected = job.expectedBytes, expected > 0, bytes < Int64(Double(expected) * 0.98) {
                problem = "“\(job.trackTitle)” came down incomplete."
            }
            if problem == nil, bytes < 4096, Self.looksLikeServerMessage(destination) {
                problem = "The server refused “\(job.trackTitle)”."
            }
            if problem != nil { try? FileManager.default.removeItem(at: destination) }
        }
        if let problem {
            fail(job: job, message: problem)
            return
        }
        // Everyone who waited for this song gets to keep it; a job from before profiles goes to the profile in front.
        var owners = Set(pendingByOwner.filter { $0.value.contains(job.trackID) }.keys)
        owners.insert(job.ownerID.hasPrefix("profile:") ? job.ownerID : DownloadOwner.scope(activeProfileID) + job.ownerID)
        records[job.trackID] = DownloadRecord(trackID: job.trackID, driveID: job.driveID, fileName: simulated ? "" : job.fileName, bytes: bytes, owners: owners)
        settle(job)
        saveManifest()
        refreshActivity(force: true)
    }

    private func fail(job: DownloadJob, message: String?) {
        if let message {
            lastError = message
            diagnostics("Download failed: \(message)")
        }
        settle(job)
        refreshActivity(force: true)
    }

    private func settle(_ job: DownloadJob) {
        jobs[job.trackID] = nil
        tasks[job.trackID] = nil
        progress[job.trackID] = nil
        simulations[job.trackID] = nil
        order.removeAll { $0 == job.trackID }
        for ownerID in Array(pendingByOwner.keys) {
            pendingByOwner[ownerID]?.remove(job.trackID)
            if pendingByOwner[ownerID]?.isEmpty == true { pendingByOwner[ownerID] = nil }
        }
        startNextIfIdle()
    }

    /// A tiny file that starts like JSON or HTML is the server explaining an error, not audio.
    nonisolated private static func looksLikeServerMessage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 16) else { return false }
        try? handle.close()
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("{") || text.hasPrefix("<")
    }

    #if os(iOS)
    // MARK: Live Activity

    /// The job whose song is coming down right now.
    private var currentJob: DownloadJob? {
        order.lazy.compactMap { self.jobs[$0] }.first
    }

    private func refreshActivity(force: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        guard let job = currentJob else {
            endActivity()
            return
        }
        let pending = pendingByOwner[job.ownerID]?.count ?? 0
        let done = max(0, job.ownerTrackCount - pending)
        let inFlight = progress[job.trackID] ?? 0
        let state = DownloadActivityAttributes.ContentState(
            fraction: (Double(done) + inFlight) / Double(max(1, job.ownerTrackCount)),
            done: done, total: job.ownerTrackCount, currentTitle: job.trackTitle
        )
        if activity == nil || activityOwnerID != job.ownerID {
            endActivity()
            let attributes = DownloadActivityAttributes(title: job.ownerTitle, subtitle: job.ownerSubtitle)
            activity = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil))
            activityOwnerID = job.ownerID
            lastActivityUpdate = .now
            return
        }
        guard force || Date.now.timeIntervalSince(lastActivityUpdate) > 1 else { return }
        lastActivityUpdate = .now
        Self.push(state, to: activity?.id)
    }

    private func endActivity() {
        guard let activity else { return }
        self.activity = nil
        let ownerID = activityOwnerID
        activityOwnerID = nil
        let total = jobs.values.first { $0.ownerID == ownerID }?.ownerTrackCount ?? 0
        let final = DownloadActivityAttributes.ContentState(fraction: 1, done: total, total: total, currentTitle: "")
        Self.push(final, to: activity.id, ending: true)
    }

    /// Activities are not Sendable, so look the activity up again by id off the main actor before talking to it.
    nonisolated private static func push(_ state: DownloadActivityAttributes.ContentState, to id: String?, ending: Bool = false) {
        guard let id else { return }
        Task.detached {
            guard let activity = Activity<DownloadActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
            let content = ActivityContent(state: state, staleDate: nil)
            if ending {
                await activity.end(content, dismissalPolicy: .after(.now + 4))
            } else {
                await activity.update(content)
            }
        }
    }

    #else
    private func refreshActivity(force: Bool) {}
    #endif

    // MARK: Manifest

    private static func loadManifest() -> [String: DownloadRecord] {
        guard let data = try? Data(contentsOf: manifestURL), let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [:] }
        return Dictionary(list.map { ($0.trackID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private func saveManifest() {
        let list = Array(records.values)
        let url = Self.manifestURL
        Task.detached(priority: .utility) {
            if let data = try? JSONEncoder().encode(list) { try? data.write(to: url, options: .atomic) }
        }
    }

    private func pruneMissingFiles() {
        let directory = Self.directory
        let missing = records.values.filter { !$0.fileName.isEmpty && !FileManager.default.fileExists(atPath: directory.appending(path: $0.fileName).path) }
        guard !missing.isEmpty else { return }
        for record in missing { records[record.trackID] = nil }
        saveManifest()
    }
}

/// Receives background session callbacks, throttles progress, and moves finished files into place
/// before the temporary copy disappears.
public nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    public var onProgress: (@Sendable (String, Double) -> Void)?
    public var onFinish: (@Sendable (DownloadJob, Int64, Int, String?) -> Void)?
    public var onError: (@Sendable (DownloadJob, String?) -> Void)?
    public var onEventsFinished: (@Sendable () -> Void)?

    private let lock = NSLock()
    private var lastReport: [Int: (fraction: Double, at: Date)] = [:]

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let job = DownloadJob.decode(downloadTask.taskDescription) else { return }
        let expected = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : (job.expectedBytes ?? 0)
        let fraction = expected > 0 ? Double(totalBytesWritten) / Double(expected) : 0
        // Only bother the app when the number has moved; the session can call this thousands of times.
        lock.lock()
        let last = lastReport[downloadTask.taskIdentifier]
        let due = last == nil || fraction - last!.fraction >= 0.01 || Date.now.timeIntervalSince(last!.at) > 0.5
        if due { lastReport[downloadTask.taskIdentifier] = (fraction, .now) }
        lock.unlock()
        if due { onProgress?(job.trackID, fraction) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = DownloadJob.decode(downloadTask.taskDescription) else { return }
        lock.lock()
        lastReport[downloadTask.taskIdentifier] = nil
        lock.unlock()
        let destination = DownloadManager.directory.appending(path: job.fileName)
        let bytes = (try? FileManager.default.attributesOfItem(atPath: location.path)[.size] as? Int64) ?? 0
        var failure: String?
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error.localizedDescription
        }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 200
        onFinish?(job, bytes, status, failure)
    }

    public func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        guard let error, let job = DownloadJob.decode(task.taskDescription) else { return }
        lock.lock()
        lastReport[task.taskIdentifier] = nil
        lock.unlock()
        let cancelled = (error as NSError).code == NSURLErrorCancelled
        onError?(job, cancelled ? nil : error.localizedDescription)
    }

    public func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        onEventsFinished?()
    }
}
