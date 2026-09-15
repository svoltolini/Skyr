import Foundation

nonisolated struct ProfilePersistenceToken: Codable, Equatable, Sendable {
    var generation: UUID
    var sequence: UInt64
}

/// Local checkpoint fields are additive JSON keys; CloudKit continues to receive ProfileState.
nonisolated private struct ProfileLocalDocument: Codable {
    var state: ProfileState
    var token: ProfilePersistenceToken?
    private enum CodingKeys: String, CodingKey { case localCheckpoint }

    init(state: ProfileState, token: ProfilePersistenceToken) { self.state = state; self.token = token }
    init(from decoder: any Decoder) throws {
        state = try ProfileState(from: decoder)
        token = try decoder.container(keyedBy: CodingKeys.self).decodeIfPresent(ProfilePersistenceToken.self, forKey: .localCheckpoint)
    }
    func encode(to encoder: any Encoder) throws {
        try state.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(token, forKey: .localCheckpoint)
    }
}

nonisolated struct ProfilePersistenceHooks: Sendable {
    var beforeSnapshotEncoding: @Sendable () -> Void = {}
    var afterJournalEnumeration: @Sendable () -> Void = {}
    var writeJournal: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var writeSnapshot: @Sendable (Data, URL) throws -> Void = { try $0.write(to: $1, options: .atomic) }
    var removeJournal: @Sendable (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) }
}

/// Small journal writes run before an edit is published. Large snapshot preparation runs on a
/// dedicated serial queue. Only checkpoint replacement and short journal operations take the
/// per-profile lock, shared by stores opened on the same directory during one process lifetime.
nonisolated final class ProfilePersistence: @unchecked Sendable {
    struct Loaded: Sendable { var state: ProfileState; var token: ProfilePersistenceToken }
    private struct Entry: Codable {
        var profileID: String
        var token: ProfilePersistenceToken
        var edit: ProfileStateEdit
        var requiresSnapshot: Bool
    }
    private final class Context: @unchecked Sendable {
        let lock = NSLock()
        var initialized = false
        var generation = UUID()
        var latest: UInt64 = 0
        var checkpoint: UInt64 = 0
        var hasSnapshot = false
        var retired = false
    }
    private final class Registry: @unchecked Sendable {
        static let shared = Registry()
        private let lock = NSLock()
        private var contexts: [String: Context] = [:]
        func context(_ key: String) -> Context {
            lock.withLock {
                if let known = contexts[key] { return known }
                let context = Context()
                contexts[key] = context
                return context
            }
        }
    }
    private struct Job: Sendable {
        var id: String
        var state: ProfileState
        var token: ProfilePersistenceToken
        var completion: @Sendable (Result<Void, any Error>) -> Void
    }

    let directory: URL
    private let hooks: ProfilePersistenceHooks
    private let queue = DispatchQueue(label: "Skyr.profile-snapshots", qos: .utility)
    private let workLock = NSLock()
    private var pending: [String: Job] = [:]
    private var running = false

    init(directory: URL, hooks: ProfilePersistenceHooks = .init()) { self.directory = directory; self.hooks = hooks }

    private func context(_ id: String) -> Context { Registry.shared.context(stateURL(id).standardizedFileURL.path) }
    private func stateURL(_ id: String) -> URL { directory.appending(path: "\(id).json") }
    private func journalURL(_ id: String) -> URL { directory.appending(path: "\(id).journal", directoryHint: .isDirectory) }
    private func entryURL(_ id: String, _ token: ProfilePersistenceToken) -> URL {
        journalURL(id).appending(path: "\(token.generation.uuidString)-\(String(format: "%020llu", token.sequence)).json")
    }
    private static func encoder() -> JSONEncoder { let value = JSONEncoder(); value.dateEncodingStrategy = .iso8601; return value }
    private static func decoder() -> JSONDecoder { let value = JSONDecoder(); value.dateDecodingStrategy = .iso8601; return value }

    private func journalFiles(_ id: String) throws -> [URL] {
        let folder = journalURL(id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Caller holds the context lock. A snapshot plus its unacknowledged entries form one read.
    private func read(_ id: String, context: Context) throws -> Loaded {
        guard !context.retired else { throw CocoaError(.fileNoSuchFile) }
        let url = stateURL(id)
        let document = FileManager.default.fileExists(atPath: url.path)
            ? try Self.decoder().decode(ProfileLocalDocument.self, from: Data(contentsOf: url)) : nil
        var state = document?.state ?? ProfileState()
        let files = try journalFiles(id)
        hooks.afterJournalEnumeration()
        let entries = try files.compactMap { url -> Entry? in
            // Cleanup runs outside this lock. A file already covered by the document may have
            // disappeared since enumeration, so never open those acknowledged entries.
            if let checkpoint = document?.token,
               url.lastPathComponent.hasPrefix(checkpoint.generation.uuidString + "-"),
               let sequence = UInt64(url.deletingPathExtension().lastPathComponent.dropFirst(37)),
               sequence <= checkpoint.sequence { return nil }
            let entry = try Self.decoder().decode(Entry.self, from: Data(contentsOf: url))
            guard entry.profileID == id, entryURL(id, entry.token).lastPathComponent == url.lastPathComponent,
                  !entry.requiresSnapshot || document != nil else { throw CocoaError(.fileReadCorruptFile) }
            return entry
        }.sorted { $0.token.sequence < $1.token.sequence }
        let generation = document?.token?.generation ?? entries.first?.token.generation ?? context.generation
        let checkpoint = document?.token?.sequence ?? 0
        var latest = checkpoint
        for entry in entries {
            guard entry.token.generation == generation else { throw CocoaError(.fileReadCorruptFile) }
            latest = max(latest, entry.token.sequence)
            if entry.token.sequence > checkpoint { state = entry.edit.applying(to: state) }
        }
        if state.sync == nil { state = state.normalizedForSync() }
        context.initialized = true
        context.generation = generation
        context.latest = max(context.latest, latest)
        context.checkpoint = max(context.checkpoint, checkpoint)
        context.hasSnapshot = document != nil
        return Loaded(state: state, token: .init(generation: generation, sequence: latest))
    }

    func load(id: String) throws -> Loaded {
        let context = context(id)
        return try context.lock.withLock { try read(id, context: context) }
    }

    func append(_ edit: ProfileStateEdit, id: String) throws -> ProfilePersistenceToken {
        let context = context(id)
        return try context.lock.withLock {
            if !context.initialized { _ = try read(id, context: context) }
            guard !context.retired, context.latest < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
            let token = ProfilePersistenceToken(generation: context.generation, sequence: context.latest + 1)
            let data = try Self.encoder().encode(Entry(profileID: id, token: token, edit: edit, requiresSnapshot: context.hasSnapshot))
            try FileManager.default.createDirectory(at: journalURL(id), withIntermediateDirectories: true)
            try write(data, to: entryURL(id, token), using: hooks.writeJournal)
            context.latest = token.sequence
            return token
        }
    }

    /// Rare full replacements (remote merge, recovery, creation) retain their synchronous durable
    /// acknowledgement. Their higher checkpoint prevents an older background snapshot winning.
    func replace(_ state: ProfileState, id: String) throws -> ProfilePersistenceToken {
        let context = context(id)
        let token = try context.lock.withLock {
            if !context.initialized { _ = try read(id, context: context) }
            guard !context.retired, context.latest < UInt64.max else { throw CocoaError(.fileWriteUnknown) }
            context.latest += 1
            return ProfilePersistenceToken(generation: context.generation, sequence: context.latest)
        }
        let data = try Self.encoder().encode(ProfileLocalDocument(state: state.normalizedForSync(), token: token))
        guard try commit(data, id: id, token: token) else { throw CocoaError(.fileWriteUnknown) }
        return token
    }

    @discardableResult
    private func commit(_ data: Data, id: String, token: ProfilePersistenceToken) throws -> Bool {
        let context = context(id)
        let committed = try context.lock.withLock {
            guard !context.retired, context.generation == token.generation, token.sequence > context.checkpoint else { return false }
            try write(data, to: stateURL(id), using: hooks.writeSnapshot)
            context.checkpoint = token.sequence
            context.hasSnapshot = true
            return true
        }
        guard committed else { return false }
        // The replacement already acknowledges these entries. Failed cleanup is safe to replay:
        // the checkpoint skips them, including history events with non-idempotent user meaning.
        for url in (try? journalFiles(id)) ?? [] {
            let prefix = token.generation.uuidString + "-"
            guard url.lastPathComponent.hasPrefix(prefix),
                  let sequence = UInt64(url.deletingPathExtension().lastPathComponent.dropFirst(prefix.count)), sequence <= token.sequence else { continue }
            do { try hooks.removeJournal(url) }
            catch { continue } // A later compaction retries cleanup; the durable checkpoint skips it.
        }
        return true
    }

    /// A filesystem adapter can report an error after its atomic replacement succeeded. Confirm
    /// that exact document before rejecting the edit, so memory and relaunch agree on acceptance.
    private func write(_ data: Data, to url: URL, using action: @Sendable (Data, URL) throws -> Void) throws {
        do { try action(data, url) }
        catch {
            guard (try? Data(contentsOf: url)) == data else { throw error }
        }
    }

    func enqueue(_ state: ProfileState, id: String, token: ProfilePersistenceToken, completion: @escaping @Sendable (Result<Void, any Error>) -> Void) {
        let shouldStart = workLock.withLock {
            if let existing = pending[id], existing.token.sequence > token.sequence { return false }
            pending[id] = Job(id: id, state: state, token: token, completion: completion)
            guard !running else { return false }
            running = true
            return true
        }
        if shouldStart { queue.async { self.run() } }
    }

    private func run() {
        while let job = workLock.withLock({ () -> Job? in
            guard let key = pending.keys.sorted().first else { running = false; return nil }
            return pending.removeValue(forKey: key)
        }) {
            do {
                hooks.beforeSnapshotEncoding()
                let document = ProfileLocalDocument(state: job.state.normalizedForSync(), token: job.token)
                let bytes = try Self.encoder().encode(document)
                try commit(bytes, id: job.id, token: job.token)
                job.completion(.success(()))
            } catch { job.completion(.failure(error)) }
        }
    }

    func retire(id: String) throws {
        let context = context(id)
        try context.lock.withLock {
            context.retired = true
            context.generation = UUID()
            for url in [stateURL(id), journalURL(id)] + setAsideURLs(id) where FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        workLock.withLock { _ = pending.removeValue(forKey: id) }
    }

    /// Moves a document that cannot be read, and its journal, next to where they were so the
    /// profile can start again from nothing. Nothing is deleted: the files keep their bytes under a
    /// name that says when they were set aside, for a later repair or a bug report.
    /// Returns the destinations, or an empty list when there was nothing to move.
    @discardableResult
    func setAside(id: String) throws -> [URL] {
        let context = context(id)
        let moved = try context.lock.withLock { () -> [URL] in
            guard !context.retired else { throw CocoaError(.fileNoSuchFile) }
            let stamp = "\(Int(Date.now.timeIntervalSince1970))-\(UUID().uuidString.prefix(8))"
            var destinations: [URL] = []
            for source in [stateURL(id), journalURL(id)] where FileManager.default.fileExists(atPath: source.path) {
                let destination = directory.appending(path: "\(id).\(Self.setAsideMarker)-\(stamp).\(source.pathExtension)")
                try FileManager.default.moveItem(at: source, to: destination)
                destinations.append(destination)
            }
            // The next read starts a fresh generation; a checkpoint still in flight for the old
            // files is rejected by its stale generation rather than resurrecting them.
            context.initialized = false
            context.generation = UUID()
            context.latest = 0
            context.checkpoint = 0
            context.hasSnapshot = false
            return destinations
        }
        workLock.withLock { _ = pending.removeValue(forKey: id) }
        return moved
    }

    private static let setAsideMarker = "unreadable"

    /// Earlier documents of this profile that were set aside, oldest first.
    func setAsideURLs(_ id: String) -> [URL] {
        let prefix = "\(id).\(Self.setAsideMarker)-"
        let contents = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return contents.filter { $0.lastPathComponent.hasPrefix(prefix) }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    func drain() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
}
