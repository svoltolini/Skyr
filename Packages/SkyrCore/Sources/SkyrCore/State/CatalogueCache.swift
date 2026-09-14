import Darwin
import Foundation

/// A rebuildable cache: prepare large snapshots off the actor, and publish only the latest intent.
nonisolated final class CatalogueCache: @unchecked Sendable {
    enum SaveResult: Equatable, Sendable { case saved, superseded, failed }
    typealias Encoder = @Sendable (Catalogue) async throws -> Data
    typealias Staging = @Sendable (Data, URL) throws -> Void

    static let shared = CatalogueCache(
        fileURL: AppDirectories.support.appending(path: "Skyr/catalogue.json"),
        reportFailure: { message in Task { @MainActor in DiagnosticsLog.shared.record(message) } }
    )

    private let fileURL: URL
    private let encode: Encoder
    private let stage: Staging
    private let beforePublication: @Sendable (Catalogue) async -> Void
    private let reportFailure: @Sendable (String) -> Void
    let stagingCleanup: Task<Void, Never>
    private let lock = NSLock()
    private var generation = UUID()
    private var permitsReads = true

    init(fileURL: URL,
         encode: @escaping Encoder = { try CatalogueCache.encode($0) },
         stage: @escaping Staging = { try $0.write(to: $1) },
         beforePublication: @escaping @Sendable (Catalogue) async -> Void = { _ in },
         reportFailure: @escaping @Sendable (String) -> Void = { _ in }) {
        self.fileURL = fileURL
        self.encode = encode
        self.stage = stage
        self.beforePublication = beforePublication
        self.reportFailure = reportFailure
        stagingCleanup = Task.detached(priority: .utility) { Self.removeAbandonedStagingFiles(for: fileURL) }
    }

    func load() -> Catalogue? {
        guard let readGeneration = lock.withLock({ permitsReads ? generation : nil }),
              let data = try? Data(contentsOf: fileURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let catalogue = try? decoder.decode(Catalogue.self, from: data),
              lock.withLock({ permitsReads && generation == readGeneration }) else { return nil }
        return catalogue
    }

    /// A folder/source change retains the previous cache for its original scope, but forbids an
    /// already preparing old scan from publishing after that change.
    func invalidatePendingWrites() { lock.withLock { generation = UUID() } }

    @discardableResult
    func save(_ snapshot: Catalogue) -> Task<SaveResult, Never> {
        let token = lock.withLock { generation = UUID(); return generation }
        return Task.detached(priority: .utility) { [self] in
            let temporary = fileURL.deletingLastPathComponent().appending(path: "\(Self.stagingPrefix(for: fileURL))\(ProcessInfo.processInfo.processIdentifier)-\(token.uuidString).pending")
            defer { try? FileManager.default.removeItem(at: temporary) }
            do {
                let data = try await encode(snapshot)
                guard !Task.isCancelled, isCurrent(token) else { return .superseded }
                try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try stage(data, temporary)
                // Tests pause here to model a connection change after the full file write. No
                // encoding or full data write holds the state lock used by foreground changes.
                await beforePublication(snapshot)
                return try lock.withLock {
                    guard !Task.isCancelled, generation == token else { return .superseded }
                    // The last check and atomic replacement are one operation relative to a new
                    // request, source/folder invalidation, and explicit removal.
                    try Self.rename(temporary, to: fileURL)
                    permitsReads = true
                    return .saved
                }
            } catch {
                guard !Task.isCancelled, isCurrent(token) else { return .superseded }
                reportFailure("The library cache could not be saved; the previous cache is retained. \(error.localizedDescription)")
                return .failed
            }
        }
    }

    /// Unlink only the cache file, under the same short publication lock. A late staged snapshot
    /// cannot recreate it after sign-out, and a failed removal cannot authorize a stale read.
    func remove() {
        do {
            try lock.withLock {
                generation = UUID()
                permitsReads = false
                let result = fileURL.path.withCString { Darwin.unlink($0) }
                if result != 0, errno != ENOENT { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            }
        } catch {
            reportFailure("The library cache could not be removed. \(error.localizedDescription)")
        }
    }

    private static func stagingPrefix(for fileURL: URL) -> String {
        ".\(fileURL.lastPathComponent).skyr-cache-"
    }

    /// A hard process exit skips the save task's defer. Clean only recognized staging files from
    /// terminated writers, on a worker, so another instance or process never loses an active write.
    private static func removeAbandonedStagingFiles(for fileURL: URL) {
        let prefix = stagingPrefix(for: fileURL)
        let suffix = ".pending"
        let properties: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: fileURL.deletingLastPathComponent(), includingPropertiesForKeys: Array(properties)) else { return }
        for file in files {
            let name = file.lastPathComponent
            guard name.hasPrefix(prefix), name.hasSuffix(suffix) else { continue }
            let owner = name.dropFirst(prefix.count).dropLast(suffix.count).split(separator: "-", maxSplits: 1)
            guard owner.count == 2, let pid = Int32(owner[0]), pid > 0, UUID(uuidString: String(owner[1])) != nil,
                  let values = try? file.resourceValues(forKeys: properties),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            // Signal zero only checks process existence. Any result other than ESRCH keeps the
            // file, including a process we cannot inspect; PID reuse can only defer cleanup.
            let exists = Darwin.kill(pid, 0)
            guard exists != 0, errno == ESRCH else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    private func isCurrent(_ token: UUID) -> Bool { lock.withLock { generation == token } }

    private static func encode(_ snapshot: Catalogue) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(snapshot)
    }

    private static func rename(_ source: URL, to destination: URL) throws {
        let result = source.path.withCString { sourcePath in
            destination.path.withCString { Darwin.rename(sourcePath, $0) }
        }
        if result != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
