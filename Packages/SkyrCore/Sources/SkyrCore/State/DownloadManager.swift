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
    case failed(message: String)
    case partial(done: Int, total: Int, message: String?)
    case cancelled(done: Int, total: Int)

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
    /// A retry is a different transfer, even when it asks for the same NAS file.
    public let attemptID: String

    public var incomingFileName: String {
        let data = Data((cacheKey + "|" + attemptID).utf8)
        return "incoming-" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public init(ownerID: String, trackID: String, driveID: String, fileName: String, expectedBytes: Int64?, ownerTitle: String, ownerSubtitle: String, trackTitle: String, ownerTrackCount: Int, attemptID: String = UUID().uuidString) {
        self.ownerID = ownerID
        self.trackID = trackID
        self.driveID = driveID
        self.fileName = fileName
        self.expectedBytes = expectedBytes
        self.ownerTitle = ownerTitle
        self.ownerSubtitle = ownerSubtitle
        self.trackTitle = trackTitle
        self.ownerTrackCount = ownerTrackCount
        self.attemptID = attemptID
    }

    private enum LegacyKeys: String, CodingKey { case albumID, albumTitle, artist, albumTrackCount }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
        trackID = try container.decode(String.self, forKey: .trackID)
        driveID = try container.decode(String.self, forKey: .driveID)
        fileName = try container.decode(String.self, forKey: .fileName)
        // Old task descriptions must decode to the same identity on every callback.
        let legacyIdentity = try JSONEncoder().encode([driveID, trackID, fileName])
        attemptID = try container.decodeIfPresent(String.self, forKey: .attemptID)
            ?? "legacy:" + SHA256.hash(data: legacyIdentity).map { String(format: "%02x", $0) }.joined()
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

    public private(set) var records: [String: DownloadRecord] = [:] { didSet { stateRevision &+= 1 } }
    /// Changes to download intent or saved-file metadata invalidate display reads.
    /// Byte progress is sampled by readers without cancelling an in-flight filesystem scan.
    public private(set) var stateRevision: UInt64 = 0
    /// Read from the current catalogue, including when its server is offline.
    public var driveIDProvider: () -> String = { "" }
    /// The profile whose downloads the screens show and new downloads belong to.
    public var activeProfileID = "default"
    /// Called when download membership changes (albums/playlists added or removed). Args: driveID, albumIDs, playlistIDs.
    public var onMembershipChanged: ((String, [String], [String]) -> Void)?
    /// 0…1 for every file currently coming down, by track id.
    public var progress: [String: Double] {
        Dictionary(jobs.values.filter { $0.driveID == driveIDProvider() }.compactMap { job in
            progressByKey[job.cacheKey].map { (job.trackID, $0) }
        }, uniquingKeysWith: { first, _ in first })
    }
    private var progressByKey: [String: Double] = [:]
    /// Albums and playlists with a download in flight and the track ids each still waits for.
    public private(set) var pendingByOwner: [String: Set<String>] = [:] { didSet { stateRevision &+= 1 } }
    public private(set) var lastError: String?
    public func clearError() { lastError = nil }

    private var session: URLSession?
    private let delegate: DownloadDelegate
    private var jobs: [String: DownloadJob] = [:]
    private var tasks: [String: URLSessionDownloadTask] = [:]
    private var simulations: [String: Task<Void, Never>] = [:]
    private var simulatedKeys: Set<String> = [] { didSet { stateRevision &+= 1 } }
    private let cacheDirectory: URL
    private let log: (String) -> Void
    private let resumeTask: (URLSessionDownloadTask) -> Void
    private let isTransportAllowed: (URL) -> Bool
    private var isStartingTask = false
    private var expectedAttempts: [String: String] = [:]
    private var retiredAttempts: Set<String> = []
    private var requests: [String: OwnerRequest] = [:] { didSet { stateRevision &+= 1 } }
    private var hasVersionedIntent = false
    private var initialJobs: [String: DownloadJob] = [:]
    private var hasSavedPendingOwners = false
    private var isRestoringTasks = true
    private var deferredSessionEvents: [SessionEvent] = []
    /// Finished background tasks can be absent from getAllTasks. Retain their saved intent until
    /// their callbacks arrive, rather than treating their absence as cancellation.
    private var initialPendingOwners: [String: Set<String>] = [:]
    private var migratesLegacySessionOwners = false
    private var cancelledInitialOwners: [String: Set<String>] = [:]

    private struct OwnerRequest: Codable {
        let ownerID: String
        let driveID: String
        let title: String
        let subtitle: String
        var keys: Set<String>
        var total: Int
        var errors: [String: String] = [:]
        var cancelled = false
    }

    /// Ownership and its exact transfers are one atomic document. The legacy pending file remains
    /// readable for migration, but cannot attach an old callback to a newer attempt after relaunch.
    private struct SavedIntent: Codable {
        var pending: [String: Set<String>]
        var jobs: [String: DownloadJob]
        var requests: [String: OwnerRequest]
        var allowsLegacyRestoration: Bool
    }

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
    #if os(iOS)
    private var activityRequestKey: String?
    private var activityDelivery: Task<Void, Never>?
    #endif

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
         resumeTask: @escaping (URLSessionDownloadTask) -> Void = { $0.resume() },
         isTransportAllowed: @escaping (URL) -> Bool = { NASTransportSecurity.isAllowed($0) },
         log: @escaping (String) -> Void = { _ in }) {
        cacheDirectory = directory
        self.log = log
        self.delegate = delegate
        self.resumeTask = resumeTask
        self.isTransportAllowed = isTransportAllowed
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        delegate.directory = directory
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        self.session = session
        delegate.onProgress = { [weak self] job, fraction in
            Task { @MainActor in self?.update(job: job, fraction: fraction) }
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
        if let data = try? Data(contentsOf: intentURL), let saved = try? JSONDecoder().decode(SavedIntent.self, from: data) {
            pendingByOwner = saved.pending
            initialJobs = saved.jobs
            expectedAttempts = saved.jobs.mapValues(\.attemptID)
            requests = saved.requests
            hasSavedPendingOwners = true
            hasVersionedIntent = !saved.allowsLegacyRestoration
        } else if FileManager.default.fileExists(atPath: intentURL.path) {
            // A damaged authoritative document must not fall back to older ownership without its
            // attempt identities. Existing completed files remain usable and new requests can retry.
            hasSavedPendingOwners = true
            hasVersionedIntent = true
            lastError = "Saved download progress couldn’t be restored. Retry the missing songs; your saved files are still available."
        } else if let data = try? Data(contentsOf: pendingURL), let pending = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
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
    private var intentURL: URL { cacheDirectory.appending(path: "download-intent.json") }

    private func requestKey(ownerID: String, driveID: String) -> String {
        Self.cacheKey(trackID: ownerID, driveID: driveID)
    }

    public nonisolated static func cacheKey(trackID: String, driveID: String) -> String {
        // Length-delimited JSON avoids ambiguity when ids contain ordinary separator characters.
        let data = (try? JSONEncoder().encode([driveID, trackID])) ?? Data()
        // This is also a hot read path for playlist download status. Construct the same lowercase
        // hexadecimal bytes without invoking Foundation's format parser 32 times per song.
        let alphabet = Array("0123456789abcdef".utf8)
        let digest = SHA256.hash(data: data)
        var hex: [UInt8] = []
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(alphabet[Int(byte >> 4)])
            hex.append(alphabet[Int(byte & 0x0f)])
        }
        return String(decoding: hex, as: UTF8.self)
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
        guard !records.isEmpty else { return nil }
        guard let record = records[key(for: track)] else { return nil }
        if record.fileName.isEmpty { return simulatedKeys.contains(key(for: track)) ? record : nil }
        return FileManager.default.fileExists(atPath: cacheDirectory.appending(path: record.fileName).path) ? record : nil
    }

    // MARK: Download membership for iCloud sync

    /// Returns the current download membership (album and playlist IDs) for the active profile on the given drive.
    /// Membership survives reinstall via iCloud; files may need re-fetch from NAS.
    public func downloadMembership(driveID: String) -> (albums: [String], playlists: [String]) {
        let scope = DownloadOwner.scope(activeProfileID)
        var albums: Set<String> = []
        var playlists: Set<String> = []
        
        // Collect from completed records
        for record in records.values where record.driveID == driveID {
            for owner in record.owners where owner.hasPrefix(scope) {
                let stripped = String(owner.dropFirst(scope.count))
                if stripped.hasPrefix(DownloadOwner.albumPrefix) {
                    albums.insert(String(stripped.dropFirst(DownloadOwner.albumPrefix.count)))
                } else if stripped.hasPrefix(DownloadOwner.playlistPrefix) {
                    playlists.insert(String(stripped.dropFirst(DownloadOwner.playlistPrefix.count)))
                }
            }
        }
        
        // Collect from pending downloads
        for ownerID in pendingByOwner.keys where ownerID.hasPrefix(scope) {
            // Check if any pending keys match this driveID
            if let keys = pendingByOwner[ownerID], keys.contains(where: { jobs[$0]?.driveID == driveID }) {
                let stripped = String(ownerID.dropFirst(scope.count))
                if stripped.hasPrefix(DownloadOwner.albumPrefix) {
                    albums.insert(String(stripped.dropFirst(DownloadOwner.albumPrefix.count)))
                } else if stripped.hasPrefix(DownloadOwner.playlistPrefix) {
                    playlists.insert(String(stripped.dropFirst(DownloadOwner.playlistPrefix.count)))
                }
            }
        }
        
        return (albums: albums.sorted(), playlists: playlists.sorted())
    }
    
    /// Restores download membership from iCloud sync state. Called on profile activation to re-populate
    /// the download intent for items that were downloaded before reinstall. Files will re-fetch from NAS.
    public func restoreDownloadMembership(albums: [String], playlists: [String], driveID: String) {
        guard !albums.isEmpty || !playlists.isEmpty else { return }
        let scope = DownloadOwner.scope(activeProfileID)
        var restoredAlbums = 0
        var restoredPlaylists = 0
        
        // Check which album memberships are missing
        for albumID in albums {
            let ownerID = scope + DownloadOwner.albumPrefix + albumID
            let hasAnyRecord = records.values.contains { $0.driveID == driveID && $0.owners.contains(ownerID) }
            let hasPending = pendingByOwner[ownerID]?.contains(where: { jobs[$0]?.driveID == driveID }) == true
            if !hasAnyRecord && !hasPending {
                restoredAlbums += 1
            }
        }
        
        // Check which playlist memberships are missing  
        for playlistID in playlists {
            let ownerID = scope + DownloadOwner.playlistPrefix + playlistID
            let hasAnyRecord = records.values.contains { $0.driveID == driveID && $0.owners.contains(ownerID) }
            let hasPending = pendingByOwner[ownerID]?.contains(where: { jobs[$0]?.driveID == driveID }) == true
            if !hasAnyRecord && !hasPending {
                restoredPlaylists += 1
            }
        }
        
        if restoredAlbums > 0 || restoredPlaylists > 0 {
            log("Download membership restored from iCloud: \(restoredAlbums) albums, \(restoredPlaylists) playlists to re-download")
        }
    }
    
    /// Notifies the membership change callback with the current membership for the given drive.
    private func notifyMembershipChange(driveID: String) {
        guard let callback = onMembershipChanged else { return }
        let membership = downloadMembership(driveID: driveID)
        callback(driveID, membership.albums, membership.playlists)
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

    /// An album renamed through its tags gets a new id; the songs kept for the old one stay kept for the new one.
    public func reassignAlbum(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        let oldSuffix = DownloadOwner.albumPrefix + oldID
        let newSuffix = DownloadOwner.albumPrefix + newID
        var changed = false
        for (trackID, var record) in records {
            let owners = Set(record.owners.map { owner -> String in
                guard let separator = owner.firstIndex(of: "|"), owner[owner.index(after: separator)...] == oldSuffix else { return owner }
                return String(owner[...separator]) + newSuffix
            })
            guard owners != record.owners else { continue }
            record.owners = owners
            records[trackID] = record
            changed = true
        }
        guard changed else { return }
        saveManifest()
        notifyMembershipChange(driveID: driveIDProvider())
    }

    /// Ids of every album and playlist that asked for a download and still has songs here or on the way.
    public var listedOwnerIDs: Set<String> {
        let driveID = driveIDProvider()
        var ids = Set(pendingByOwner.filter { entry in entry.value.contains { jobs[$0]?.driveID == driveID } }.keys)
        for record in records.values where record.driveID == driveID { ids.formUnion(record.owners) }
        for request in requests.values where request.driveID == driveID && (!request.errors.isEmpty || request.cancelled) {
            ids.insert(request.ownerID)
        }
        return ids
    }

    /// Songs of the album or playlist that it has on the device.
    public func downloadedCount(for owner: DownloadOwner) -> Int {
        guard !records.isEmpty else { return 0 }
        return owner.tracks.filter { record(for: $0)?.owners.contains(owner.id) == true }.count
    }

    public func state(for owner: DownloadOwner) -> DownloadState {
        let tracks = owner.tracks
        guard !tracks.isEmpty else { return .none }
        let done = downloadedCount(for: owner)
        if done == tracks.count { return .downloaded }
        let pending = pendingByOwner[owner.id] ?? []
        if !pending.isEmpty, tracks.contains(where: { pending.contains(key(for: $0)) }) {
            let inFlight = tracks.filter { pending.contains(key(for: $0)) }.reduce(0.0) { $0 + (progressByKey[key(for: $1)] ?? 0) }
            return .downloading(fraction: (Double(done) + inFlight) / Double(tracks.count), done: done, total: tracks.count)
        }
        let request = requests[requestKey(ownerID: owner.id, driveID: driveIDProvider())]
        if request?.cancelled == true { return .cancelled(done: done, total: tracks.count) }
        let error = request?.errors.sorted(by: { $0.key < $1.key }).first?.value
        if done > 0 { return .partial(done: done, total: tracks.count, message: error) }
        if let error { return .failed(message: error) }
        return .none
    }

    /// A fresh display read. Hashing and checking files happen off the main actor; playback still
    /// uses localURL(for:) so a previously displayed result never authorizes a missing file.
    public func readState(for owner: DownloadOwner) async throws -> DownloadState {
        try await readState(for: owner, fileExists: { FileManager.default.fileExists(atPath: $0.path) })
    }

    // The injected checker lets tests pause real snapshot work and verify source/cancellation guards.
    func readState(for owner: DownloadOwner, fileExists: @escaping @Sendable (URL) -> Bool) async throws -> DownloadState {
        try Task.checkCancellation()
        let driveID = driveIDProvider()
        let profileID = activeProfileID
        let revision = stateRevision
        guard owner.id.hasPrefix(DownloadOwner.scope(profileID)) else { throw CancellationError() }
        let request = requests[requestKey(ownerID: owner.id, driveID: driveID)]
        let snapshot = DownloadStateSnapshot(owner: owner, driveID: driveID, records: records,
                                             simulatedKeys: simulatedKeys, pending: pendingByOwner[owner.id] ?? [],
                                             progress: progressByKey, cancelled: request?.cancelled == true,
                                             errors: request?.errors ?? [:],
                                             directory: cacheDirectory)
        let worker = Task.detached(priority: .userInitiated) {
            try snapshot.read(fileExists: fileExists)
        }
        let state = try await withTaskCancellationHandler {
            try await worker.value
        } onCancel: {
            worker.cancel()
        }
        try Task.checkCancellation()
        guard driveIDProvider() == driveID, activeProfileID == profileID, stateRevision == revision else {
            throw CancellationError()
        }
        return state
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
        let requestID = requestKey(ownerID: owner.id, driveID: driveID)
        requests[requestID] = OwnerRequest(ownerID: owner.id, driveID: driveID, title: owner.title, subtitle: owner.subtitle,
                                          keys: Set(owner.tracks.map { Self.cacheKey(trackID: $0.id, driveID: driveID) }), total: owner.tracks.count)
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
            let existing = jobs[key] ?? initialJobs[key]
            let hasLiveTask = tasks[key].map { $0.state == .running || $0.state == .suspended } == true
            if let existing, (isRestoringTasks || hasLiveTask || simulations[key] != nil), accept(existing) {
                pending.insert(key)
                continue
            }
            let offeredSource = url(track)
            let source = offeredSource.flatMap { isTransportAllowed($0) ? $0 : nil }
            guard source != nil || (isSample && driveID.isEmpty) else {
                lastError = offeredSource == nil
                    ? "Connect to your NAS, then try downloading “\(owner.title)” again. Your existing downloads are still available."
                    : "Review the server address in Sign in before downloading. HTTPS is recommended; HTTP requires permission on this device. Your existing downloads are still available."
                requests[requestID]?.errors[key] = lastError
                pending.remove(key)
                pendingByOwner[owner.id]?.remove(key)
                initialPendingOwners[owner.id]?.remove(key)
                if let existing, !pendingByOwner.values.contains(where: { $0.contains(key) }),
                   !initialPendingOwners.values.contains(where: { $0.contains(key) }) { retire(existing) }
                continue
            }
            // Enumeration can finish before an old completion callback arrives. Keep its saved
            // ownership until then, but an explicit retry with no live task starts a fresh transfer.
            if let existing { retire(existing) }
            let attemptID = UUID().uuidString
            let name = Self.fileName(for: track, driveID: driveID)
            let job = DownloadJob(
                ownerID: owner.id, trackID: track.id, driveID: driveID, fileName: attemptID + "-" + name,
                expectedBytes: track.fileSize, ownerTitle: owner.title, ownerSubtitle: owner.subtitle,
                trackTitle: track.title, ownerTrackCount: owner.tracks.count, attemptID: attemptID
            )
            jobs[key] = job
            expectedAttempts[key] = job.attemptID
            initialJobs[key] = nil
            for initialOwner in Array(initialPendingOwners.keys) where initialPendingOwners[initialOwner]?.contains(key) == true {
                pendingByOwner[initialOwner, default: []].insert(key)
                initialPendingOwners[initialOwner]?.remove(key)
            }
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
                simulate(track, job: job)
            }
        }
        pendingByOwner[owner.id] = pending.isEmpty ? nil : pending
        saveManifest()
        savePendingOwners()
        log("“\(owner.title)”: queued \(queued) songs, \(shared) already on this iPhone")
        startNextIfIdle()
        refreshActivity(force: true)
        notifyMembershipChange(driveID: driveID)
    }

    /// Starts the first waiting task when nothing is running, so files come down one after another.
    private func startNextIfIdle() {
        guard !isStartingTask, !tasks.values.contains(where: { $0.state == .running }) else { return }
        isStartingTask = true
        defer { isStartingTask = false }
        for trackID in order {
            guard let task = tasks[trackID], task.state == .suspended else { continue }
            // A task can wait behind many songs after its URL was created. A local permission
            // change must take effect before the next task sends its session credentials.
            guard allowsTransport(for: task) else {
                task.cancel()
                if let job = jobs[trackID] {
                    fail(job: job, message: "This connection is no longer allowed on this device. Review the server address in Sign in, then retry.")
                } else {
                    tasks[trackID] = nil
                    order.removeAll { $0 == trackID }
                }
                continue
            }
            progressByKey[trackID] = 0
            resumeTask(task)
            return
        }
    }

    private func allowsTransport(for task: URLSessionTask) -> Bool {
        guard let original = task.originalRequest?.url, let current = task.currentRequest?.url,
              let origin = NASOrigin(url: original), origin == NASOrigin(url: current) else { return false }
        return isTransportAllowed(original) && isTransportAllowed(current)
    }

    /// Stops what is still on its way for the album or playlist; songs another owner also waits for keep coming.
    public func cancel(_ owner: DownloadOwner) {
        let driveID = driveIDProvider()
        let requestID = requestKey(ownerID: owner.id, driveID: driveID)
        if requests[requestID] != nil { requests[requestID]?.cancelled = true }
        if isRestoringTasks || migratesLegacySessionOwners || !initialPendingOwners.isEmpty {
            cancelledInitialOwners[owner.id, default: []].insert(driveID)
        }
        let ownerKeys = Set(owner.tracks.map { Self.cacheKey(trackID: $0.id, driveID: driveID) })
        let pending = (pendingByOwner[owner.id] ?? []).union(initialPendingOwners[owner.id] ?? [])
        let scoped = pending.filter { key in
            let source = jobs[key]?.driveID ?? initialJobs[key]?.driveID
            return source == driveID || (source == nil && ownerKeys.contains(key))
        }
        pendingByOwner[owner.id]?.subtract(scoped)
        if pendingByOwner[owner.id]?.isEmpty == true { pendingByOwner[owner.id] = nil }
        initialPendingOwners[owner.id]?.subtract(scoped)
        if initialPendingOwners[owner.id]?.isEmpty == true { initialPendingOwners[owner.id] = nil }
        for key in scoped {
            let wantedElsewhere = pendingByOwner.values.contains { $0.contains(key) }
                || initialPendingOwners.values.contains { $0.contains(key) }
            guard !wantedElsewhere else { continue }
            let task = tasks[key]
            let simulation = simulations[key]
            // Retire synchronously. A retry can queue immediately while the old OS task cancels.
            if let job = jobs[key] ?? initialJobs[key] { retire(job) }
            task?.cancel()
            simulation?.cancel()
        }
        savePendingOwners()
        startNextIfIdle()
        refreshActivity(force: true)
    }

    /// Lets the album or playlist go; files no other download still needs are deleted from the device.
    public func remove(_ owner: DownloadOwner) {
        cancel(owner)
        requests[requestKey(ownerID: owner.id, driveID: driveIDProvider())] = nil
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
        savePendingOwners()
        log("Removed the download of “\(owner.title)”: \(deleted) files deleted, \(kept) still used by other downloads")
        notifyMembershipChange(driveID: driveIDProvider())
    }

    private func simulate(_ track: Track, job: DownloadJob) {
        let key = job.cacheKey
        simulations[key] = Task { [weak self] in
            // Wait for earlier simulated songs so the demo also goes one at a time.
            while let self, let first = order.first(where: { simulations[$0] != nil }), first != key, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
            }
            let steps = 20
            for step in 1...steps {
                try? await Task.sleep(for: .milliseconds(Int.random(in: 40...90)))
                guard !Task.isCancelled, let self else { return }
                update(job: job, fraction: Double(step) / Double(steps))
            }
            guard !Task.isCancelled, let self, jobs[key]?.attemptID == job.attemptID else { return }
            simulations[key] = nil
            finish(job: job, bytes: track.fileSize ?? 0, status: 200, failure: nil)
        }
    }

    private func restore(_ restored: [(DownloadJob, URLSessionDownloadTask)]) {
        for (job, task) in restored {
            guard accept(job) else { task.cancel(); continue }
            guard allowsTransport(for: task) else {
                task.cancel()
                deferredSessionEvents.append(.failed(job, message: "Review the server address in Sign in, then retry this download. Its saved connection is no longer allowed on this device."))
                continue
            }
            guard tasks[job.cacheKey] == nil else { continue }
            tasks[job.cacheKey] = task
            if task.state == .running { progressByKey[job.cacheKey] = 0 }
        }
        for job in deferredSessionEvents.compactMap(\.job) { _ = accept(job) }
        let completingKeys = Set(deferredSessionEvents.compactMap { event -> String? in
            guard let job = event.job, jobs[job.cacheKey]?.attemptID == job.attemptID else { return nil }
            return job.cacheKey
        })
        let activeKeys = Set(tasks.keys).union(simulations.keys).union(completingKeys)
        // A retry requested during enumeration may have temporarily adopted a saved job. Without
        // its OS task it is still only saved intent, not an active download.
        for key in Array(jobs.keys) where !activeKeys.contains(key) {
            jobs[key] = nil
            progressByKey[key] = nil
            order.removeAll { $0 == key }
        }
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

    /// All callbacks, including progress, are subordinate to the current transfer's identity.
    /// Only a saved pre-migration intent may introduce a legacy transfer not already registered.
    private func accept(_ job: DownloadJob) -> Bool {
        guard !retiredAttempts.contains(job.attemptID) else { return false }
        if let current = jobs[job.cacheKey] { return current.attemptID == job.attemptID }
        guard records[job.cacheKey] == nil else { return false }
        if let expected = expectedAttempts[job.cacheKey] {
            guard expected == job.attemptID else { return false }
        } else {
            guard !hasVersionedIntent else { return false }
        }
        registerInitialOwners(for: job)
        let owners = pendingByOwner.filter { $0.value.contains(job.cacheKey) }.keys
        guard !owners.isEmpty else { return false }
        jobs[job.cacheKey] = job
        expectedAttempts[job.cacheKey] = job.attemptID
        if !order.contains(job.cacheKey) { order.append(job.cacheKey) }
        for owner in owners {
            let id = requestKey(ownerID: owner, driveID: job.driveID)
            if requests[id] == nil {
                let savedKeys = Set(records.filter { $0.value.driveID == job.driveID && $0.value.owners.contains(owner) }.keys)
                let keys = savedKeys.union(pendingByOwner[owner] ?? [])
                requests[id] = OwnerRequest(ownerID: owner, driveID: job.driveID, title: job.ownerTitle, subtitle: job.ownerSubtitle,
                                            keys: keys, total: max(keys.count, job.ownerTrackCount))
            }
        }
        return true
    }

    private func receive(_ event: SessionEvent) {
        guard !isRestoringTasks else {
            deferredSessionEvents.append(event)
            return
        }
        if let job = event.job, !accept(job) {
            if case .finished = event { try? FileManager.default.removeItem(at: cacheDirectory.appending(path: job.incomingFileName)) }
            return
        }
        switch event {
        case .finished(let job, let bytes, let status, let failure):
            finish(job: job, bytes: bytes, status: status, failure: failure)
        case .failed(let job, let message):
            fail(job: job, message: message)
        case .eventsFinished:
            // A saved task that the system neither restored nor completed can be retried.
            for job in initialJobs.values where tasks[job.cacheKey] == nil {
                if accept(job) { fail(job: job, message: "The download was interrupted. Retry to keep the missing songs.") }
            }
            initialPendingOwners.removeAll()
            initialJobs.removeAll()
            migratesLegacySessionOwners = false
            cancelledInitialOwners.removeAll()
            savePendingOwners()
            DownloadManager.backgroundCompletionHandler?()
            DownloadManager.backgroundCompletionHandler = nil
        }
    }

    private func update(job: DownloadJob, fraction: Double) {
        let key = job.cacheKey
        guard jobs[key]?.attemptID == job.attemptID else { return }
        guard progressByKey[key] != nil else { return }
        progressByKey[key] = min(1, max(0, fraction))
        refreshActivity(force: false)
    }

    private func finish(job: DownloadJob, bytes: Int64, status: Int, failure: String?) {
        guard jobs[job.cacheKey]?.attemptID == job.attemptID else { return }
        let destination = cacheDirectory.appending(path: job.fileName)
        let incoming = cacheDirectory.appending(path: job.incomingFileName)
        let simulated = simulatedKeys.contains(job.cacheKey)
        var problem = failure
        if problem == nil, !(200..<300).contains(status) { problem = "The server answered with HTTP \(status)." }
        if !simulated {
            if problem == nil, !FileManager.default.fileExists(atPath: incoming.path) || bytes <= 0 {
                problem = "“\(job.trackTitle)” could not be saved. Try downloading it again."
            }
            if problem == nil, let expected = job.expectedBytes, expected > 0, bytes != expected {
                problem = bytes < expected ? "“\(job.trackTitle)” came down incomplete."
                    : "“\(job.trackTitle)” changed on the NAS. Update the library, then retry."
            }
            if problem == nil, Self.looksLikeServerMessage(incoming) {
                problem = "The server refused “\(job.trackTitle)”."
            }
            if problem != nil { try? FileManager.default.removeItem(at: incoming) }
        }
        if let problem {
            fail(job: job, message: problem)
            return
        }
        // Cancellation removes ownership immediately, even if the session finishes the file later.
        let owners = Set(pendingByOwner.filter { $0.value.contains(job.cacheKey) }.keys)
        if owners.isEmpty {
            if !simulated { try? FileManager.default.removeItem(at: incoming) }
        } else {
            if !simulated {
                do {
                    // Incoming data is isolated by attempt. Only the accepted attempt publishes.
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: incoming, to: destination)
                } catch {
                    try? FileManager.default.removeItem(at: incoming)
                    fail(job: job, message: "“\(job.trackTitle)” could not be saved: \(error.localizedDescription)")
                    return
                }
            }
            records[job.cacheKey] = DownloadRecord(trackID: job.trackID, driveID: job.driveID, fileName: simulated ? "" : job.fileName, bytes: bytes, owners: owners)
        }
        saveManifest()
        settle(job)
        refreshActivity(force: true)
    }

    private func fail(job: DownloadJob, message: String?) {
        guard jobs[job.cacheKey]?.attemptID == job.attemptID else { return }
        let owners = pendingByOwner.filter { $0.value.contains(job.cacheKey) }.keys
        for owner in owners {
            let id = requestKey(ownerID: owner, driveID: job.driveID)
            if let message { requests[id]?.errors[job.cacheKey] = "“\(job.trackTitle)”: \(message)" }
            else { requests[id]?.cancelled = true }
        }
        if let message {
            lastError = "Couldn’t finish “\(job.ownerTitle)”. \(message) Your saved songs are still available; retry to download only the missing songs."
            log("Download failed: \(message)")
        }
        settle(job)
        refreshActivity(force: true)
    }

    private func settle(_ job: DownloadJob) {
        guard jobs[job.cacheKey]?.attemptID == job.attemptID else { return }
        retire(job)
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

    private func retire(_ job: DownloadJob) {
        retiredAttempts.insert(job.attemptID)
        expectedAttempts[job.cacheKey] = nil
        initialJobs[job.cacheKey] = nil
        jobs[job.cacheKey] = nil
        tasks[job.cacheKey] = nil
        progressByKey[job.cacheKey] = nil
        simulations[job.cacheKey] = nil
        order.removeAll { $0 == job.cacheKey }
    }

    /// A tiny file that starts like JSON or HTML is the server explaining an error, not audio.
    nonisolated private static func looksLikeServerMessage(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url), let head = try? handle.read(upToCount: 16) else { return false }
        try? handle.close()
        let text = String(decoding: head, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.hasPrefix("{") || text.hasPrefix("<")
    }

    /// Shared by the Live Activity and isolated tests, including terminal outcomes.
    func progressSnapshot(ownerID: String, driveID: String) -> DownloadProgress? {
        let id = requestKey(ownerID: ownerID, driveID: driveID)
        guard let request = requests[id] else { return nil }
        let done = request.keys.filter { key in
            guard let record = records[key], record.owners.contains(ownerID) else { return false }
            return record.fileName.isEmpty ? simulatedKeys.contains(key) : FileManager.default.fileExists(atPath: cacheDirectory.appending(path: record.fileName).path)
        }.count
        let pending = (pendingByOwner[ownerID] ?? []).intersection(request.keys)
        let inFlight = pending.reduce(0.0) { $0 + (progressByKey[$1] ?? 0) }
        let total = request.total
        let outcome: DownloadOutcome
        if done == total && total > 0 { outcome = .downloaded }
        else if !pending.isEmpty { outcome = .downloading }
        else if request.cancelled { outcome = .cancelled }
        else if done > 0 { outcome = .partial }
        else { outcome = .failed }
        let current = order.first { pending.contains($0) }.flatMap { jobs[$0] }
        return DownloadProgress(fraction: (Double(done) + inFlight) / Double(max(1, total)), done: done, total: total,
                                currentTitle: current?.trackTitle ?? "", outcome: outcome)
    }

    #if os(iOS)
    // MARK: Live Activity

    private func refreshActivity(force: Bool) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        // Keep an owner's activity until that request ends, even if another owner's task is running.
        if let activity, let id = activityRequestKey, let request = requests[id],
           let state = progressSnapshot(ownerID: request.ownerID, driveID: request.driveID), state.outcome == .downloading {
            guard force || Date.now.timeIntervalSince(lastActivityUpdate) > 1 else { return }
            lastActivityUpdate = .now
            push(state, to: activity.id)
            return
        }
        endActivity()
        guard let job = order.lazy.compactMap({ self.jobs[$0] }).first,
              let ownerID = pendingByOwner.keys.sorted().first(where: { pendingByOwner[$0]?.contains(job.cacheKey) == true }) else { return }
        let id = requestKey(ownerID: ownerID, driveID: job.driveID)
        guard let request = requests[id], let state = progressSnapshot(ownerID: ownerID, driveID: job.driveID) else { return }
        let attributes = DownloadActivityAttributes(title: request.title, subtitle: request.subtitle)
        guard let created = try? Activity.request(attributes: attributes, content: ActivityContent(state: state, staleDate: nil)) else { return }
        activity = created
        activityOwnerID = ownerID
        activityRequestKey = id
        lastActivityUpdate = .now
    }

    private func endActivity() {
        guard let activity else { return }
        let request = activityRequestKey.flatMap { requests[$0] }
        let state = request.flatMap { progressSnapshot(ownerID: $0.ownerID, driveID: $0.driveID) }
            ?? DownloadProgress(fraction: 0, done: 0, total: 0, currentTitle: "", outcome: .cancelled)
        self.activity = nil
        activityOwnerID = nil
        activityRequestKey = nil
        push(state, to: activity.id, ending: true)
    }

    /// Serialize updates and the terminal message so an earlier progress task cannot arrive after end.
    private func push(_ state: DownloadActivityAttributes.ContentState, to id: String?, ending: Bool = false) {
        guard let id else { return }
        let previous = activityDelivery
        activityDelivery = Task { @MainActor in
            await previous?.value
            await Self.deliver(state, to: id, ending: ending)
        }
    }

    /// Look up ActivityKit's non-Sendable object on the same executor that awaits its update.
    nonisolated private static func deliver(_ state: DownloadActivityAttributes.ContentState, to id: String, ending: Bool) async {
        guard let activity = Activity<DownloadActivityAttributes>.activities.first(where: { $0.id == id }) else { return }
        let content = ActivityContent(state: state, staleDate: nil)
        if ending {
            await activity.end(content, dismissalPolicy: .after(.now + (state.outcome == .downloaded ? 4 : 30)))
        } else {
            await activity.update(content)
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
        var savedJobs = initialJobs
        for (key, job) in jobs { savedJobs[key] = job }
        savedJobs = savedJobs.filter { expectedAttempts[$0.key] == $0.value.attemptID }
        let saved = SavedIntent(pending: pending, jobs: savedJobs, requests: requests,
                                allowsLegacyRestoration: !hasVersionedIntent && (migratesLegacySessionOwners || !initialPendingOwners.isEmpty))
        if let data = try? JSONEncoder().encode(saved) {
            do {
                try data.write(to: intentURL, options: .atomic)
                // Compatibility copy only. The atomic document above is authoritative on relaunch.
                try? JSONEncoder().encode(pending).write(to: pendingURL, options: .atomic)
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
    public var onProgress: (@Sendable (DownloadJob, Double) -> Void)?
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
        if due { onProgress?(job, fraction) }
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
        let destination = directory.appending(path: job.incomingFileName)
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
