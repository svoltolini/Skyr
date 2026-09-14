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
    public var cacheKey: String { DownloadManager.cacheKey(trackID: trackID, driveID: driveID) }
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
    /// Read from the current catalogue, including when its server is offline.
    public var driveIDProvider: () -> String = { "" }
    /// The profile whose downloads the screens show and new downloads belong to.
    public var activeProfileID = "default"
    /// 0…1 for every file currently coming down, by track id.
    public var progress: [String: Double] {
        Dictionary(jobs.values.filter { $0.driveID == driveIDProvider() }.compactMap { job in
            progressByKey[job.cacheKey].map { (job.trackID, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
    private var progressByKey: [String: Double] = [:]
    /// Albums and playlists with a download in flight and the track ids each still waits for.
    public private(set) var pendingByOwner: [String: Set<String>] = [:]
    public private(set) var lastError: String?
    public func clearError() { lastError = nil }

    private var session: URLSession?
    private let delegate: DownloadDelegate
    private var jobs: [String: DownloadJob] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var simulations: [String: Task<Void, Never>] = [:]
    private var simulatedKeys: Set<String> = []
    private let cacheDirectory: URL
    private let log: (String) -> Void
    private var hasSavedPendingOwners = false
    private var isRestoringTasks = true
    private var deferredSessionEvents: [SessionEvent] = []
    /// Finished background tasks can be absent from getAllTasks. Retain their saved intent until
    /// their callbacks arrive, rather than treating their absence as cancellation.
    private var initialPendingOwners: [String: Set<String>] = [:]
    private var migratesLegacySessionOwners = false
    private var cancelledInitialOwners: [String: Set<String>] = [:]

    private enum SessionEvent {
        case finished(DownloadJob, bytes: Int64, status: Int, failure: String?)
        case failed(DownloadJob, message: String?)
        case eventsFinished

        var job: DownloadJob? {
            switch self {
            case .finished(let job, _, _, _), .failed(let job, _): job
            case .eventsFinished: nil
            }
        }
    }
    /// Order in which songs were queued; the session runs them one at a time in this order.
    private var order: [String] = []
    #if os(iOS)
    private var activity: Activity<DownloadActivityAttributes>?
    #endif
    private var activityOwnerID: String?
    private var lastActivityUpdate = Date.distantPast

    public convenience init() {
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionIdentifier)
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.timeoutIntervalForResource = 12 * 60 * 60
        self.init(directory: Self.directory, configuration: configuration, log: diagnostics)
    }

    /// An isolated directory and session also let tests exercise persistence without touching user downloads.
    init(directory: URL, configuration: URLSessionConfiguration,
         delegate: DownloadDelegate = DownloadDelegate(),
         restoreTasks: ((URLSession, @escaping @Sendable ([URLSessionTask]) -> Void) -> Void)? = nil,
         log: @escaping (String) -> Void = { _ in }) {
        cacheDirectory = directory
        self.log = log
        self.delegate = delegate
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delegate.directory = directory
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        delegate.onProgress = { [weak self] key, fraction in
            Task { @MainActor in self?.update(key: key, fraction: fraction) }
        }
        delegate.onFinish = { [weak self] job, bytes, status, failure in
            Task { @MainActor in self?.receive(.finished(job, bytes: bytes, status: status, failure: failure)) }
        }
        delegate.onError = { [weak self] job, message in
            Task { @MainActor in self?.receive(.failed(job, message: message)) }
        }
        delegate.onEventsFinished = { [weak self] in
            Task { @MainActor in self?.receive(.eventsFinished) }
        }
        records = Self.loadManifest(at: manifestURL)
        pruneMissingFiles()
        saveManifest()
        if let data = try? Data(contentsOf: pendingURL), let pending = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            pendingByOwner = pending
            hasSavedPendingOwners = true
        }
        initialPendingOwners = pendingByOwner
        migratesLegacySessionOwners = !hasSavedPendingOwners
        // Songs still queued from an earlier launch keep going; pick their bookkeeping back up.
        // Answered on the session's own queue, so the closure stays off the main actor and hands
        // the tasks across explicitly.
        let restored: @Sendable ([URLSessionTask]) -> Void = { [weak self] tasks in
            let found = tasks.compactMap { task -> (DownloadJob, URLSessionDownloadTask)? in
                guard let download = task as? URLSessionDownloadTask, let job = DownloadJob.decode(task.taskDescription) else { return nil }
                return (job, download)
            }
            Task { @MainActor in self?.restore(found) }
        }
        if let restoreTasks { restoreTasks(session, restored) }
        else { session.getAllTasks(completionHandler: restored) }
    }

    // MARK: Where files live

    public nonisolated static let directory: URL = {
        let base = AppDirectories.support
            .appending(path: "Skyr/downloads", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var manifestURL: URL { cacheDirectory.appending(path: "downloads.json") }
    private var pendingURL: URL { cacheDirectory.appending(path: "pending.json") }

    public nonisolated static func cacheKey(trackID: String, driveID: String) -> String {
        // Length-delimited JSON avoids ambiguity when ids contain ordinary separator characters.
        let data = (try? JSONEncoder().encode([driveID, trackID])) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public nonisolated static func fileName(for track: Track, driveID: String) -> String {
        let digest = cacheKey(trackID: track.id, driveID: driveID)
        let ext = safeExtension(track.fileExtension)
        return ext.isEmpty ? digest : "\(digest).\(ext)"
    }

    public nonisolated static func safeExtension(_ value: String) -> String {
        let ext = value.lowercased()
        return !ext.isEmpty && ext.count <= 12 && ext.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) } ? ext : "audio"
    }

    private func key(for track: Track) -> String { Self.cacheKey(trackID: track.id, driveID: driveIDProvider()) }

    private func record(for track: Track) -> DownloadRecord? {
        guard let record = records[key(for: track)] else { return nil }
        if record.fileName.isEmpty { return simulatedKeys.contains(key(for: track)) ? record : nil }
        return FileManager.default.fileExists(atPath: cacheDirectory.appending(path: record.fileName).path) ? record : nil
    }

    // MARK: Reading state

    /// The song is on the device, whichever album or playlist brought it.
    public func isDownloaded(_ track: Track) -> Bool { record(for: track) != nil }

    /// The file on this device for a track, when it is there.
    public func localURL(for track: Track) -> URL? {
        guard let record = record(for: track), !record.fileName.isEmpty else { return nil }
        let url = cacheDirectory.appending(path: record.fileName)
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
        let driveID = driveIDProvider()
        var ids = Set(pendingByOwner.filter { entry in entry.value.contains { jobs[$0]?.driveID == driveID } }.keys)
        for record in records.values where record.driveID == driveID { ids.formUnion(record.owners) }
        return ids
    }

    /// Songs of the album or playlist that it has on the device.
    public func downloadedCount(for owner: DownloadOwner) -> Int {
        owner.tracks.filter { record(for: $0)?.owners.contains(owner.id) == true }.count
    }

    public func state(for owner: DownloadOwner) -> DownloadState {
        let tracks = owner.tracks
        guard !tracks.isEmpty else { return .none }
        let done = downloadedCount(for: owner)
        if done == tracks.count { return .downloaded }
        guard let pending = pendingByOwner[owner.id] else { return .none }
        guard tracks.contains(where: { pending.contains(key(for: $0)) }) else { return .none }
        let inFlight = tracks.filter { pending.contains(key(for: $0)) }.reduce(0.0) { $0 + (progressByKey[key(for: $1)] ?? 0) }
        return .downloading(fraction: (Double(done) + inFlight) / Double(tracks.count), done: done, total: tracks.count)
    }

    public var totalBytes: Int64 { records.values.reduce(0) { $0 + $1.bytes } }

    /// A song that is queued but whose file has not started coming down yet.
    public func isQueued(_ track: Track) -> Bool {
        jobs[key(for: track)] != nil && progressByKey[key(for: track)] == nil
    }

    // MARK: Downloading

    /// Keeps every song of the album or playlist on the device. Songs already here are shared at once,
    /// songs already on their way for another owner are waited for, and the rest are queued to come
    /// down strictly one at a time. Only an explicitly selected sample library may simulate files.
    public func download(_ owner: DownloadOwner, driveID: String, isSample: Bool = false, url: (Track) -> URL?) {
        lastError = nil
        guard let session else { return }
        var pending = pendingByOwner[owner.id] ?? []
        var shared = 0
        var queued = 0
        for track in owner.tracks {
            let key = Self.cacheKey(trackID: track.id, driveID: driveID)
            if let existing = records[key], existing.fileName.isEmpty || !FileManager.default.fileExists(atPath: cacheDirectory.appending(path: existing.fileName).path) {
                if !existing.fileName.isEmpty || !isSample { records[key] = nil }
            }
            if var record = records[key] {
                if record.owners.insert(owner.id).inserted {
                    records[key] = record
                    shared += 1
                }
                continue
            }
            if jobs[key] != nil {
                pending.insert(key)
                continue
            }
            let source = url(track)
            guard source != nil || (isSample && driveID.isEmpty) else {
                lastError = "Connect to your NAS, then try downloading “\(owner.title)” again. Your existing downloads are still available."
                continue
            }
            let job = DownloadJob(
                ownerID: owner.id, trackID: track.id, driveID: driveID, fileName: Self.fileName(for: track, driveID: driveID),
                expectedBytes: track.fileSize, ownerTitle: owner.title, ownerSubtitle: owner.subtitle,
                trackTitle: track.title, ownerTrackCount: owner.tracks.count
            )
            jobs[key] = job
            pending.insert(key)
            order.append(key)
            queued += 1
            if let source {
                let task = session.downloadTask(with: source)
                task.taskDescription = job.encoded
                tasks[key] = task
            } else {
                simulatedKeys.insert(key)
                progressByKey[key] = 0
                simulate(track, key: key)
            }
        }
        if !pending.isEmpty { pendingByOwner[owner.id] = pending }
        saveManifest()
        savePendingOwners()
        log("“\(owner.title)”: queued \(queued) songs, \(shared) already on this iPhone")
        startNextIfIdle()
        refreshActivity(force: true)
    }

    /// Starts the first waiting task when nothing is running, so files come down one after another.
    private func startNextIfIdle() {
        guard !tasks.values.contains(where: { $0.state == .running }) else { return }
        for trackID in order {
            guard let task = tasks[trackID], task.state == .suspended else { continue }
            progressByKey[trackID] = 0
            task.resume()
            return
        }
    }

    /// Stops what is still on its way for the album or playlist; songs another owner also waits for keep coming.
    public func cancel(_ owner: DownloadOwner) {
        let driveID = driveIDProvider()
        if isRestoringTasks || migratesLegacySessionOwners || !initialPendingOwners.isEmpty {
            cancelledInitialOwners[owner.id, default: []].insert(driveID)
        }
        let ownerKeys = Set(owner.tracks.map { Self.cacheKey(trackID: $0.id, driveID: driveID) })
        initialPendingOwners[owner.id]?.subtract(ownerKeys)
        if initialPendingOwners[owner.id]?.isEmpty == true { initialPendingOwners[owner.id] = nil }
        guard let pending = pendingByOwner[owner.id] else {
            savePendingOwners()
            return
        }
        let scoped = pending.filter { jobs[$0]?.driveID == driveID || (jobs[$0] == nil && ownerKeys.contains($0)) }
        pendingByOwner[owner.id]?.subtract(scoped)
        if pendingByOwner[owner.id]?.isEmpty == true { pendingByOwner[owner.id] = nil }
        initialPendingOwners[owner.id]?.subtract(scoped)
        if initialPendingOwners[owner.id]?.isEmpty == true { initialPendingOwners[owner.id] = nil }
        savePendingOwners()
        for trackID in scoped {
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
        for (trackID, var record) in records where record.driveID == driveIDProvider() && record.owners.contains(owner.id) {
            record.owners.remove(owner.id)
            if record.owners.isEmpty {
                records[trackID] = nil
                if !record.fileName.isEmpty {
                    try? FileManager.default.removeItem(at: cacheDirectory.appending(path: record.fileName))
                }
                deleted += 1
            } else {
                records[trackID] = record
                kept += 1
            }
        }
        saveManifest()
        log("Removed the download of “\(owner.title)”: \(deleted) files deleted, \(kept) still used by other downloads")
    }

    private func simulate(_ track: Track, key: String) {
        simulations[key] = Task { [weak self] in
            // Wait for earlier simulated songs so the demo also goes one at a time.
            while let self, let first = order.first(where: { simulations[$0] != nil }), first != key, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 40...90)))
                guard !Task.isCancelled, let self else { return }
                update(key: key, fraction: Double(step) / Double(steps))
            }
            guard !Task.isCancelled, let self, let job = jobs[key] else { return }
            simulations[key] = nil
            finish(job: job, bytes: track.fileSize ?? 0, status: 200, failure: nil)
        }
    }

    private func restore(_ restored: [(DownloadJob, URLSessionDownloadTask)]) {
        for job in restored.map(\.0) + deferredSessionEvents.compactMap(\.job) {
            registerInitialOwners(for: job)
        }
        for (job, task) in restored where records[job.cacheKey] == nil && jobs[job.cacheKey] == nil {
            guard pendingByOwner.values.contains(where: { $0.contains(job.cacheKey) }) else { task.cancel(); continue }
            jobs[job.cacheKey] = job
            tasks[job.cacheKey] = task
            if task.state == .running { progressByKey[job.cacheKey] = 0 }
            order.append(job.cacheKey)
        }
        let activeKeys = Set(jobs.keys).union(deferredSessionEvents.compactMap { $0.job?.cacheKey })
        for owner in Array(pendingByOwner.keys) {
            pendingByOwner[owner]?.formIntersection(activeKeys)
            if pendingByOwner[owner]?.isEmpty == true { pendingByOwner[owner] = nil }
        }
        savePendingOwners()
        isRestoringTasks = false
        let events = deferredSessionEvents
        deferredSessionEvents.removeAll()
        for event in events { receive(event) }
        if !restored.isEmpty { log("Picked up \(restored.count) downloads still queued from the last launch") }
        startNextIfIdle()
        refreshActivity(force: true)
    }

    // MARK: Results from the session

    private func registerInitialOwners(for job: DownloadJob) {
        for (owner, keys) in initialPendingOwners where keys.contains(job.cacheKey) {
            if cancelledInitialOwners[owner]?.contains(job.driveID) == true {
                initialPendingOwners[owner]?.remove(job.cacheKey)
                pendingByOwner[owner]?.remove(job.cacheKey)
            } else {
                pendingByOwner[owner, default: []].insert(job.cacheKey)
            }
        }
        guard migratesLegacySessionOwners, jobs[job.cacheKey] == nil, records[job.cacheKey] == nil else { return }
        let owner = job.ownerID.hasPrefix("profile:") ? job.ownerID : DownloadOwner.scope(activeProfileID) + job.ownerID
        guard cancelledInitialOwners[owner]?.contains(job.driveID) != true else { return }
        pendingByOwner[owner, default: []].insert(job.cacheKey)
        initialPendingOwners[owner, default: []].insert(job.cacheKey)
    }

    private func receive(_ event: SessionEvent) {
        guard !isRestoringTasks else {
            deferredSessionEvents.append(event)
            return
        }
        if let job = event.job { registerInitialOwners(for: job) }
        switch event {
        case .finished(let job, let bytes, let status, let failure):
            finish(job: job, bytes: bytes, status: status, failure: failure)
        case .failed(let job, let message):
            fail(job: job, message: message)
        case .eventsFinished:
            initialPendingOwners.removeAll()
            migratesLegacySessionOwners = false
            cancelledInitialOwners.removeAll()
            savePendingOwners()
            DownloadManager.backgroundCompletionHandler?()
            DownloadManager.backgroundCompletionHandler = nil
        }
    }

    private func update(key: String, fraction: Double) {
        guard progressByKey[key] != nil else { return }
        progressByKey[key] = min(1, max(0, fraction))
        refreshActivity(force: false)
    }

    private func finish(job: DownloadJob, bytes: Int64, status: Int, failure: String?) {
        let destination = cacheDirectory.appending(path: job.fileName)
        let simulated = simulatedKeys.contains(job.cacheKey)
        var problem = failure
        if problem == nil, status >= 400 { problem = "The server answered with HTTP \(status)." }
        if !simulated {
            if problem == nil, !FileManager.default.fileExists(atPath: destination.path) || bytes <= 0 {
                problem = "“\(job.trackTitle)” could not be saved. Try downloading it again."
            }
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
        // Cancellation removes ownership immediately, even if the session finishes the file later.
        let owners = Set(pendingByOwner.filter { $0.value.contains(job.cacheKey) }.keys)
        if owners.isEmpty {
            if !simulated { try? FileManager.default.removeItem(at: destination) }
        } else {
            records[job.cacheKey] = DownloadRecord(trackID: job.trackID, driveID: job.driveID, fileName: simulated ? "" : job.fileName, bytes: bytes, owners: owners)
        }
        settle(job)
        saveManifest()
        refreshActivity(force: true)
    }

    private func fail(job: DownloadJob, message: String?) {
        if let message {
            lastError = message
            log("Download failed: \(message)")
        }
        settle(job)
        refreshActivity(force: true)
    }

    private func settle(_ job: DownloadJob) {
        jobs[job.cacheKey] = nil
        tasks[job.cacheKey] = nil
        progressByKey[job.cacheKey] = nil
        simulations[job.cacheKey] = nil
        order.removeAll { $0 == job.cacheKey }
        for ownerID in Array(pendingByOwner.keys) {
            pendingByOwner[ownerID]?.remove(job.cacheKey)
            if pendingByOwner[ownerID]?.isEmpty == true { pendingByOwner[ownerID] = nil }
        }
        for ownerID in Array(initialPendingOwners.keys) {
            initialPendingOwners[ownerID]?.remove(job.cacheKey)
            if initialPendingOwners[ownerID]?.isEmpty == true { initialPendingOwners[ownerID] = nil }
        }
        savePendingOwners()
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
        let inFlight = progressByKey[job.cacheKey] ?? 0
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

    private static func loadManifest(at url: URL) -> [String: DownloadRecord] {
        guard let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([DownloadRecord].self, from: data) else { return [:] }
        // Existing manifests already contain their source drive. Retain valid files in place and
        // reindex by that source; discard old simulated/false records so they can be retried.
        return Dictionary(list.filter { !$0.fileName.isEmpty && !$0.driveID.isEmpty && ($0.fileName as NSString).lastPathComponent == $0.fileName }.map {
            (cacheKey(trackID: $0.trackID, driveID: $0.driveID), $0)
        }, uniquingKeysWith: { first, _ in first })
    }

    private func saveManifest() {
        let list = records.values.filter { !$0.fileName.isEmpty }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: manifestURL, options: .atomic) }
    }

    private func savePendingOwners() {
        var pending = initialPendingOwners
        for (owner, keys) in pendingByOwner { pending[owner, default: []].formUnion(keys) }
        pending = pending.filter { !$0.value.isEmpty }
        if let data = try? JSONEncoder().encode(pending) {
            do {
                try data.write(to: pendingURL, options: .atomic)
                hasSavedPendingOwners = true
            } catch {
                lastError = "Download progress could not be saved. Keep Skyr open until downloads finish."
            }
        }
    }

    private func pruneMissingFiles() {
        let directory = cacheDirectory
        let missing = records.values.filter { !$0.fileName.isEmpty && !FileManager.default.fileExists(atPath: directory.appending(path: $0.fileName).path) }
        guard !missing.isEmpty else { return }
        for record in missing { records[Self.cacheKey(trackID: record.trackID, driveID: record.driveID)] = nil }
        saveManifest()
    }
}

/// Receives background session callbacks, throttles progress, and moves finished files into place
/// before the temporary copy disappears.
public nonisolated final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    var directory = DownloadManager.directory
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
        if due { onProgress?(job.cacheKey, fraction) }
    }

    public func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let job = DownloadJob.decode(downloadTask.taskDescription) else { return }
        lock.lock()
        lastReport[downloadTask.taskIdentifier] = nil
        lock.unlock()
        guard (job.fileName as NSString).lastPathComponent == job.fileName, !job.fileName.isEmpty else {
            onError?(job, "This download needs to be requested again.")
            return
        }
        let destination = directory.appending(path: job.fileName)
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
