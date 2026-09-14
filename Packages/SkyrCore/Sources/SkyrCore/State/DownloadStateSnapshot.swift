import Foundation

/// Immutable display input. No FileManager access or per-song hashing runs in a view body.
nonisolated struct DownloadStateSnapshot: Sendable {
    let owner: DownloadOwner
    let driveID: String
    let records: [String: DownloadRecord]
    let simulatedKeys: Set<String>
    let pending: Set<String>
    let progress: [String: Double]
    let cancelled: Bool
    let errors: [String: String]
    let directory: URL

    func read(fileExists: @Sendable (URL) -> Bool) throws -> DownloadState {
        let total = owner.tracks.count
        guard total > 0 else { return .none }
        var done = 0
        var inFlight = 0.0
        var hasPending = false
        // Repeated playlist occurrences count separately, but need only one file check per read.
        var available: [String: Bool] = [:]
        if !records.isEmpty || !pending.isEmpty {
            for track in owner.tracks {
                try Task.checkCancellation()
                let key = DownloadManager.cacheKey(trackID: track.id, driveID: driveID)
                let exists: Bool
                if let cached = available[key] {
                    exists = cached
                } else if let record = records[key], record.owners.contains(owner.id) {
                    exists = record.fileName.isEmpty ? simulatedKeys.contains(key) : fileExists(directory.appending(path: record.fileName))
                    available[key] = exists
                } else {
                    exists = false
                    available[key] = false
                }
                if exists { done += 1 }
                if pending.contains(key) {
                    hasPending = true
                    inFlight += progress[key] ?? 0
                }
            }
        }
        try Task.checkCancellation()
        if done == total { return .downloaded }
        if hasPending { return .downloading(fraction: (Double(done) + inFlight) / Double(total), done: done, total: total) }
        if cancelled { return .cancelled(done: done, total: total) }
        let error = errors.min(by: { $0.key < $1.key })?.value
        if done > 0 { return .partial(done: done, total: total, message: error) }
        if let error { return .failed(message: error) }
        return .none
    }
}
