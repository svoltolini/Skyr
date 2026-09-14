import Foundation

/// Walks a drive to build the catalogue, then reads tags and covers in the background.
@Observable
public final class LibraryIndexer {
    public enum Phase: Equatable {
        case idle, scanning, enriching, done, failed(Failure)
    }

    /// Why a scan produced no library, worded for the screen; the technical detail goes to Diagnostics.
    public nonisolated enum Failure: Equatable, Sendable {
        case noMusic(path: String)
        case unreadable(count: Int, path: String)
        case missing(path: String)
        case other(String)

        public var title: String {
            switch self {
            case .noMusic: "No music in this folder"
            case .unreadable: "Some folders couldn't be read"
            case .missing: "This folder no longer exists"
            case .other: "Couldn't read the folder"
            }
        }

        /// One short line under the title, only when it helps.
        public var detail: String? {
            switch self {
            case .noMusic, .missing: nil
            case .unreadable(_, let path): "Check that this account can open everything in “\(Self.name(of: path))”."
            case .other(let message): message
            }
        }

        public static func name(of path: String) -> String {
            path.split(separator: "/").last.map(String.init) ?? path
        }
    }

    public private(set) var phase: Phase = .idle
    /// Requests in flight at once. Over a home link the NAS is the limit; over the internet it is
    /// latency, and a dozen requests at a time hides most of it.
    nonisolated static let parallelism = 12
    public private(set) var foldersScanned = 0
    public private(set) var tracksFound = 0
    public private(set) var enrichedCount = 0
    public private(set) var enrichTotal = 0
    public private(set) var listingFailures = 0
    public private(set) var coversDone = 0
    public private(set) var coversTotal = 0
    private var task: Task<Void, Never>?
    private var currentRun: IndexingRun?
    private let recordDiagnostics: @Sendable (String) -> Void
    private let artworkLookup: ArtworkLookup

    public init(artworkLookup: ArtworkLookup = .shared) {
        self.artworkLookup = artworkLookup
        recordDiagnostics = { diagnostics($0) }
    }

    init(recordDiagnostics: @escaping @Sendable (String) -> Void, artworkLookup: ArtworkLookup = .shared) {
        self.artworkLookup = artworkLookup
        self.recordDiagnostics = recordDiagnostics
    }

    public var isRunning: Bool { phase == .scanning || phase == .enriching }
    public var isScanning: Bool { phase == .scanning }
    public var isEnriching: Bool { phase == .enriching }
    /// True once albums exist, even while tags are still being read.
    public var structureReady: Bool { phase == .enriching || phase == .done }
    public var enrichProgress: Double { enrichTotal > 0 ? Double(enrichedCount) / Double(enrichTotal) : 1 }

    public var statusText: String? {
        switch phase {
        case .scanning: "Scanning…"
        case .enriching:
            if coversTotal > 0 && coversDone < coversTotal {
                "Scanning · covers \(coversDone.formatted()) of \(coversTotal.formatted())"
            } else if enrichTotal > 0 && enrichedCount < enrichTotal {
                "Scanning · \(Int((enrichProgress * 100).rounded()))%"
            } else {
                "Checking for changes…"
            }
        default: nil
        }
    }

    private var lastProgressPublish = Date.distantPast

    private func checkActive(_ run: IndexingRun) throws {
        try Task.checkCancellation()
        guard currentRun === run, run.isActive else { throw CancellationError() }
    }

    /// Progress reaches the screen at most twice a second. Every published change re-evaluates the
    /// views that show it, and on a wide window with a large library that is the whole Library
    /// screen; publishing per song once froze the Mac app for minutes (2026-09-13).
    private func noteScanProgress(folders: Int, tracks: Int) {
        guard Date.now.timeIntervalSince(lastProgressPublish) > 0.5 else { return }
        lastProgressPublish = .now
        foldersScanned = folders
        tracksFound = tracks
    }

    /// Same pacing for the tag and cover counters; `force` publishes the final value.
    private func noteEnrichProgress(enriched: Int? = nil, covers: Int? = nil, force: Bool = false) {
        guard force || Date.now.timeIntervalSince(lastProgressPublish) > 0.5 else { return }
        lastProgressPublish = .now
        if let enriched, enrichedCount != enriched { enrichedCount = enriched }
        if let covers, coversDone != covers { coversDone = covers }
    }

    /// Scans `rootPath` on the drive; `onCatalogue` receives the catalogue when the structure is known and again as tags arrive.
    public func start(drive: any RemoteDrive, rootPath: String, serverName: String, existing: Catalogue?, onCatalogue: @escaping @MainActor (Catalogue) -> Void) {
        cancel()
        let run = IndexingRun()
        currentRun = run
        phase = .scanning
        foldersScanned = 0
        tracksFound = 0
        enrichedCount = 0
        enrichTotal = 0
        listingFailures = 0
        coversDone = 0
        coversTotal = 0
        lastProgressPublish = .distantPast
        recordDiagnostics("Scan started at \(rootPath) on \(drive.displayName)")
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                run.cancel()
                if currentRun === run {
                    currentRun = nil
                    task = nil
                }
            }
            await CoverStore.$indexingRun.withValue(run) {
                do {
                    let scan = try await Self.scan(drive: drive, root: rootPath, recordDiagnostics: recordDiagnostics) { [weak self] scanned, found in
                        Task { @MainActor in
                            guard let self, self.currentRun === run, run.isActive else { return }
                            self.noteScanProgress(folders: scanned, tracks: found)
                        }
                    }
                    try checkActive(run)
                    listingFailures = scan.failures
                    foldersScanned = scan.foldersListed
                    recordDiagnostics("Scan finished: \(scan.foldersListed) folders listed, \(scan.filesSeen) files seen, \(scan.folders.reduce(0) { $0 + $1.audio.count }) audio files, \(scan.failures) listing failures\(scan.firstError.map { ", first error: \($0)" } ?? "").")
                    // A partial answer cannot establish what was deleted. Keep the complete previous
                    // catalogue until every subtree can be read, including on background refreshes.
                    guard scan.failures == 0 else {
                        recordDiagnostics("Refresh incomplete; the previous library was kept.")
                        phase = .failed(.unreadable(count: scan.failures, path: rootPath))
                        return
                    }
                    let folders = scan.folders
                    if folders.isEmpty {
                        if scan.foldersListed == 0 {
                            // Not one folder was read, not even the root, and nothing failed: that is the
                            // scanner going wrong, never a real answer. The library people have is kept.
                            recordDiagnostics("Scan listed no folders at all under \(rootPath); keeping the library as it was.")
                            phase = .failed(.other("The server didn't answer for this folder. Your library was kept; try again."))
                            return
                        }
                        if existing != nil {
                            // Every folder was read and none holds music: the library really is empty now.
                            recordDiagnostics("Scan found no music under \(rootPath); the library is now empty.")
                            onCatalogue(Catalogue(serverName: serverName, albums: [], indexedAt: .now, rootPath: rootPath, driveID: drive.id))
                            try checkActive(run)
                            phase = .done
                            return
                        }
                        recordDiagnostics("No music files were found under \(rootPath); \(scan.filesSeen.formatted()) other files were seen.")
                        phase = .failed(.noMusic(path: rootPath))
                        return
                    }
                    let driveID = drive.id
                    let coverDirectory = CoverStore.directory
                    let catalogue = await Task.detached(priority: .userInitiated) {
                        CoverStore.$directoryOverride.withValue(coverDirectory) {
                            CoverStore.$indexingRun.withValue(run) {
                                var built = Catalogue.build(folders: folders, rootPath: rootPath, serverName: serverName, driveID: driveID, existing: existing)
                                if run.isActive, built.enrichedTrackCount > 0 { built.regroupByTags() }
                                return built
                            }
                        }
                    }.value
                    try checkActive(run)
                    tracksFound = catalogue.trackCount
                    onCatalogue(catalogue)
                    try checkActive(run)
                    phase = .enriching
                    try await runEnrichment(catalogue: catalogue, drive: drive, run: run, onCatalogue: onCatalogue)
                    try checkActive(run)
                    phase = .done
                } catch is CancellationError {
                    return
                } catch {
                    guard currentRun === run, run.isActive, !Task.isCancelled else { return }
                    if error.isMissingPath {
                        // The chosen folder itself is gone; show an empty library rather than the old one.
                        recordDiagnostics("The folder \(rootPath) no longer exists; the library is now empty.")
                        if existing != nil {
                            onCatalogue(Catalogue(serverName: serverName, albums: [], indexedAt: .now, rootPath: rootPath, driveID: drive.id))
                        }
                        guard currentRun === run, run.isActive else { return }
                        phase = .failed(.missing(path: rootPath))
                    } else {
                        recordDiagnostics("Scan failed: \(error.localizedDescription)")
                        phase = .failed(.other(error.localizedDescription))
                    }
                }
            }
        }
    }

    public func cancel() {
        currentRun?.cancel()
        currentRun = nil
        task?.cancel()
        task = nil
        if isRunning { phase = .idle }
    }

    // MARK: Scanning

    /// One folder's listing as it comes back from a worker. A plain struct on purpose: a tuple with a
    /// `Result` inside came back corrupted from worker tasks in release builds (2026-09-13).
    nonisolated private struct Listing: Sendable {
        let path: String
        let entries: [RemoteEntry]
        let error: (any Error)?
    }

    nonisolated private struct ScanResult: Sendable {
        var folders: [ScannedFolder] = []
        var foldersListed = 0
        var filesSeen = 0
        var failures = 0
        var firstError: String?
    }

    /// Breadth-first walk with a few listings in flight; unreadable folders are counted and skipped.
    nonisolated private static func scan(drive: any RemoteDrive, root: String, recordDiagnostics: @escaping @Sendable (String) -> Void, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> ScanResult {
        var result = ScanResult()
        var queue = [root]
        var found = 0
        var isFirst = true
        while !queue.isEmpty {
            try Task.checkCancellation()
            let batch = Array(queue.prefix(parallelism))
            queue.removeFirst(batch.count)
            let listings: [Listing] = await parallelResults(batch) { path in
                do {
                    return Listing(path: path, entries: try await drive.list(path), error: nil)
                } catch {
                    return Listing(path: path, entries: [], error: error)
                }
            }
            try Task.checkCancellation()
            for listing in listings.sorted(by: { $0.path < $1.path }) {
                let path = listing.path
                if let error = listing.error {
                    if isFirst { throw error }
                    result.failures += 1
                    if result.firstError == nil { result.firstError = "\(path): \(error.localizedDescription)" }
                    continue
                }
                let entries = listing.entries
                isFirst = false
                let directories = entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") && $0.name != "@eaDir" && $0.name != "#recycle" }
                queue.append(contentsOf: directories.map(\.path))
                let audio = entries.filter(\.isAudio)
                result.filesSeen += entries.filter { !$0.isDirectory }.count
                if result.foldersListed < 3 {
                    recordDiagnostics("Listed \(path): \(entries.count) entries, \(directories.count) folders, \(audio.count) audio. Sample: \(entries.prefix(3).map { "\($0.name)\($0.isDirectory ? "/" : "")" }.joined(separator: ", "))")
                }
                if !audio.isEmpty {
                    result.folders.append(ScannedFolder(path: path, audio: audio, cover: RemoteDriveSupport.coverImage(in: entries)))
                    found += audio.count
                }
                result.foldersListed += 1
                progress(result.foldersListed, found)
            }
        }
        return result
    }

    // MARK: Enrichment

    /// A cover fetched for an album, as a struct for the same reason as `Listing`.
    nonisolated private struct CoverFetch: Sendable {
        let album: Album
        let data: Data?
        let source: String?
    }

    private struct EnrichmentResult: Sendable {
        let track: Track
        let cover: Data?
    }

    private func runEnrichment(catalogue: Catalogue, drive: any RemoteDrive, run: IndexingRun, onCatalogue: @escaping @MainActor (Catalogue) -> Void) async throws {
        try checkActive(run)
        var working = catalogue
        // Album ids that already asked one of their songs for embedded art; ids change as albums regroup,
        // which at worst costs one extra request per album.
        var coverRequested: Set<String> = []
        // Only songs never read, or read by an older version, and not the ones that already failed
        // three times this week: those wait so a refresh does not read the whole library again.
        let now = Date.now
        var restingCount = 0
        let pending = working.albums.flatMap(\.tracks).filter { track in
            guard !track.isEnriched || track.tagVersion != Track.currentTagVersion else { return false }
            let attempts = track.enrichAttempts ?? 0
            if attempts < 3 { return true }
            if let last = track.enrichAttemptedAt, now.timeIntervalSince(last) < 7 * 24 * 3600 {
                restingCount += 1
                return false
            }
            return true
        }
        let rereads = pending.filter(\.isEnriched).count
        if rereads > 0 { recordDiagnostics("Reading tags again for \(rereads) tracks indexed by an older version") }
        if restingCount > 0 { recordDiagnostics("Leaving \(restingCount) songs that could not be read three times; they are tried again after a week") }
        if !pending.isEmpty { recordDiagnostics("Reading tags for \(pending.count) songs") }
        enrichTotal = pending.count
        enrichedCount = 0
        var enrichedSoFar = 0
        var lastPublish = Date.now

        for start in stride(from: 0, to: pending.count, by: Self.parallelism) {
            try checkActive(run)
            let chunk = pending[start..<min(start + Self.parallelism, pending.count)]
            // Decide who should bring back a picture using the albums as they are grouped right now.
            var requests: [(track: Track, coverPath: String?, wantsArt: Bool, albumID: String)] = []
            for track in chunk {
                let album = working.album(containing: track.id)
                let albumID = album?.id ?? track.albumID
                let wantsArt = !CoverStore.hasCover(for: albumID) && !coverRequested.contains(albumID)
                if wantsArt { coverRequested.insert(albumID) }
                requests.append((track, wantsArt ? album?.coverPath : nil, wantsArt, albumID))
            }
            let results = await parallelResults(requests) { request in
                await Self.enrich(track: request.track, coverPath: request.coverPath, wantsEmbeddedArt: request.wantsArt, drive: drive)
            }
            try checkActive(run)
            for result in results {
                var track = result.track
                if !track.isEnriched || track.tagVersion != Track.currentTagVersion {
                    // Still not read: remember the failure so it is not retried forever.
                    track.enrichAttempts = (track.enrichAttempts ?? 0) + 1
                    track.enrichAttemptedAt = .now
                }
                working.apply(track)
                let request = requests.first { $0.track.id == result.track.id }
                if let cover = result.cover {
                    // Kept per song too, so the album that finally owns this song can adopt it after regrouping.
                    CoverStore.saveTrackCover(cover, for: result.track.id)
                    if let albumID = working.album(containing: result.track.id)?.id, !CoverStore.hasCover(for: albumID) {
                        CoverStore.save(cover, for: albumID)
                    }
                } else if let request, request.wantsArt {
                    // Let a later song of the album try its embedded picture.
                    coverRequested.remove(request.albumID)
                }
                enrichedSoFar += 1
            }
            noteEnrichProgress(enriched: enrichedSoFar)
            if Date.now.timeIntervalSince(lastPublish) > 6 {
                // Show albums as their tags settle instead of the folder grouping until the very end.
                working.regroupByTags()
                onCatalogue(working)
                try checkActive(run)
                lastPublish = .now
            }
        }
        noteEnrichProgress(enriched: enrichedSoFar, force: true)
        working.indexedAt = .now
        let finished = working
        let coverDirectory = CoverStore.directory
        working = await Task.detached(priority: .userInitiated) {
            CoverStore.$directoryOverride.withValue(coverDirectory) {
                CoverStore.$indexingRun.withValue(run) {
                    var regrouped = finished
                    if run.isActive { regrouped.regroupByTags() }
                    return regrouped
                }
            }
        }.value
        try checkActive(run)
        let multiDisc = working.albums.filter(\.hasMultipleDiscs)
        recordDiagnostics("Regrouped by tags: \(working.albums.count) albums, \(multiDisc.count) with more than one disc" + (multiDisc.isEmpty ? "" : ": " + multiDisc.prefix(6).map { "“\($0.title)” (\($0.discs.count))" }.joined(separator: ", ")))
        onCatalogue(working)
        try checkActive(run)
        try await runCoverPass(catalogue: working, drive: drive, run: run)
        try checkActive(run)
        noteEnrichProgress(covers: coversTotal, force: true)
        CoverStore.clearTrackCovers()
        onCatalogue(working)
    }

    /// Fetches a cover for every album that still lacks one, from its folder image or its own tracks.
    /// With this device's permission, missing or repeated pictures can be looked up through Apple.
    private func runCoverPass(catalogue: Catalogue, drive: any RemoteDrive, run: IndexingRun) async throws {
        try checkActive(run)
        // Albums that had no cover anywhere last time are looked at again after a week, not on every refresh.
        let now = Date.now
        var resting = 0
        let missing = catalogue.albums.filter { album in
            guard !CoverStore.hasCover(for: album.id) else { return false }
            if let tried = CoverStore.missingCoverDate(for: album.id), now.timeIntervalSince(tried) < 7 * 24 * 3600,
               !artworkLookup.shouldRetryMissingCover(after: tried) {
                resting += 1
                return false
            }
            return true
        }
        coversTotal = missing.count
        coversDone = 0
        var coversSoFar = 0
        if resting > 0 { recordDiagnostics("Cover pass: \(resting) albums without any cover are left until next week") }
        guard !missing.isEmpty else { return }
        recordDiagnostics("Cover pass: \(missing.count) albums without covers")
        var seenHashes = CoverStore.hashesByArtist(among: catalogue.albums)
        for start in stride(from: 0, to: missing.count, by: Self.parallelism) {
            try checkActive(run)
            let chunk = missing[start..<min(start + Self.parallelism, missing.count)]
            let results: [CoverFetch] = await parallelResults(Array(chunk)) { album in
                let found = await Self.fetchCover(for: album, drive: drive)
                return CoverFetch(album: album, data: found?.0, source: found?.1)
            }
            try checkActive(run)
            for fetch in results {
                let album = fetch.album
                let found: (Data, String)? = fetch.data.flatMap { data in fetch.source.map { (data, $0) } }
                let artistKey = album.artist.lowercased()
                var chosen = found
                let embeddedHash = found.map { ArtworkLookup.hash($0.0) }
                let isDuplicate = embeddedHash.map { seenHashes[artistKey, default: []].contains($0) } ?? false
                if found == nil || isDuplicate {
                    if let result = await artworkLookup.itunesCover(artist: album.artist, album: album.title),
                       let online = artworkLookup.acceptedData(from: result) {
                        chosen = (online, isDuplicate ? "iTunes Store, because the files share one picture" : "iTunes Store")
                    }
                    try checkActive(run)
                }
                if let (data, source) = chosen {
                    CoverStore.save(data, for: album.id)
                    seenHashes[artistKey, default: []].insert(ArtworkLookup.hash(data))
                    recordDiagnostics("Cover for “\(album.title)” by \(album.artist): \(source)")
                } else {
                    CoverStore.noteMissingCover(for: album.id)
                    recordDiagnostics("No cover found for “\(album.title)” by \(album.artist)")
                }
                coversSoFar += 1
                noteEnrichProgress(covers: coversSoFar)
            }
        }
        recordDiagnostics("Cover pass finished: \(missing.filter { CoverStore.hasCover(for: $0.id) }.count) covers found")
    }

    /// The cover image and a description of where it came from.
    public nonisolated static func fetchCover(for album: Album, drive: any RemoteDrive) async -> (Data, String)? {
        if let coverPath = album.coverPath, let data = try? await drive.download(coverPath, maxBytes: 12 * 1024 * 1024), !data.isEmpty {
            return (data, "folder image \(coverPath)")
        }
        for track in album.tracks.prefix(3) {
            guard let path = track.path else { continue }
            if track.codec == "flac" {
                if let info = try? await readFLAC(path: path, drive: drive), let picture = info.picture {
                    return (picture, "embedded art in \(path)")
                }
            } else if let url = drive.streamURL(for: path) {
                if let artwork = await MediaProbe.probe(url: url).artwork {
                    return (artwork, "embedded art in \(path)")
                }
            }
        }
        return nil
    }

    /// Reads one file's headers and tags; FLAC by hand, everything else through AVFoundation.
    nonisolated private static func enrich(track: Track, coverPath: String?, wantsEmbeddedArt: Bool, drive: any RemoteDrive) async -> EnrichmentResult {
        var updated = track
        var cover: Data?
        if let coverPath, let data = try? await drive.download(coverPath, maxBytes: 12 * 1024 * 1024), !data.isEmpty {
            cover = data
        }
        guard let path = track.path else {
            updated.isEnriched = true
            updated.tagVersion = Track.currentTagVersion
            return EnrichmentResult(track: updated, cover: cover)
        }

        if track.codec == "flac" {
            if var info = try? await readFLAC(path: path, drive: drive) {
                updated.sampleRate = info.sampleRate ?? updated.sampleRate
                updated.bitDepth = info.bitsPerSample
                if let duration = info.duration { updated.duration = duration }
                if let size = track.fileSize, let bitrate = MediaBounds.bitrate(bytes: size, duration: updated.duration) {
                    updated.bitrate = bitrate
                }
                if let title = info.tag("TITLE") { updated.title = title }
                if let number = info.number("TRACKNUMBER") { updated.number = number }
                if let disc = info.number("DISCNUMBER"), disc > 0 { updated.disc = disc }
                updated.artist = info.tag("ARTIST") ?? updated.artist
                updated.albumTitleTag = info.tag("ALBUM")
                updated.albumArtistTag = info.tag("ALBUMARTIST") ?? info.tag("ALBUM ARTIST")
                updated.yearTag = info.year
                updated.genreTag = info.tag("GENRE")
                updated.normalizeDiscFromAlbumTag()
                updated.format = FormatLabel.make(codec: "flac", sampleRate: updated.sampleRate, bitrate: nil, bitDepth: updated.bitDepth)
                updated.isEnriched = true
                updated.tagVersion = Track.currentTagVersion
                if cover == nil, wantsEmbeddedArt, let picture = info.picture { cover = picture }
                info.picture = nil
            }
            return EnrichmentResult(track: updated, cover: cover)
        }

        // MP4 and MP3 files are read in one or two ranged requests; anything else still asks AVFoundation,
        // which fetches the file piece by piece and is slow over the internet.
        let probe: ProbedMedia
        if let native = await readNatively(track: track, path: path, drive: drive) {
            probe = native
        } else {
            guard let url = drive.streamURL(for: path) else { return EnrichmentResult(track: updated, cover: cover) }
            probe = await MediaProbe.probe(url: url)
        }
        if let duration = probe.duration { updated.duration = duration }
        if let codec = probe.codec, !codec.isEmpty { updated.codec = codec }
        updated.sampleRate = probe.sampleRate ?? updated.sampleRate
        if let bits = probe.bitsPerChannel, bits > 0 { updated.bitDepth = bits }
        if let bitrate = probe.bitrate {
            updated.bitrate = bitrate
        } else if let size = track.fileSize, let duration = probe.duration,
                  let bitrate = MediaBounds.bitrate(bytes: size, duration: duration) {
            updated.bitrate = bitrate
        }
        if let title = probe.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty { updated.title = title }
        if let number = probe.trackNumber, number > 0 { updated.number = number }
        if let disc = probe.discNumber, disc > 0 { updated.disc = disc }
        if let artist = probe.artist, !artist.isEmpty { updated.artist = artist }
        updated.albumTitleTag = probe.album
        updated.albumArtistTag = probe.albumArtist
        updated.yearTag = probe.year
        updated.genreTag = probe.genre
        updated.normalizeDiscFromAlbumTag()
        updated.format = FormatLabel.make(codec: updated.codec, sampleRate: updated.sampleRate, bitrate: updated.isLossless ? nil : updated.bitrate, bitDepth: updated.bitDepth)
        if probe.duration != nil || probe.title != nil {
            updated.isEnriched = true
            updated.tagVersion = Track.currentTagVersion
        }
        if cover == nil, wantsEmbeddedArt, let artwork = probe.artwork { cover = artwork }
        return EnrichmentResult(track: updated, cover: cover)
    }

    nonisolated private static func readNatively(track: Track, path: String, drive: any RemoteDrive) async -> ProbedMedia? {
        let read: (Range<Int64>) async throws -> Data = { range in try await drive.read(path, range: range) }
        switch (path as NSString).pathExtension.lowercased() {
        case "m4a", "mp4", "aac", "alac":
            return try? await MP4Tags.read(read: read)
        case "mp3":
            return try? await ID3Tags.read(fileSize: track.fileSize, read: read)
        default:
            return nil
        }
    }

    nonisolated private static func readFLAC(path: String, drive: any RemoteDrive) async throws -> FLACInfo? {
        let head = try await drive.read(path, range: 0..<FLACHeader.initialRead)
        guard let info = FLACHeader.parse(head) else { return nil }
        if let needed = info.neededPrefix, Int64(needed) > Int64(head.count), Int64(needed) <= FLACHeader.maximumRead {
            let longer = try await drive.read(path, range: 0..<Int64(needed))
            return FLACHeader.parse(longer) ?? info
        }
        return info
    }
}
