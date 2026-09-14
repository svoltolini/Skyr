import Foundation

nonisolated struct PreparedProfileCloudState: Sendable {
    var digest: String
    var document: Data?
    var updatedAt: Date
}

/// Explicit detached boundaries are necessary with the package's caller-isolated async default.
/// These workers prepare values only; account checks and CloudKit access stay with CloudSync.
nonisolated enum ProfileCloudPreparation {
    static func prepare(_ state: ProfileState, acknowledgedDigest: String? = nil) async throws -> PreparedProfileCloudState {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let normalized = state.normalizedForSync()
            let digest = normalized.syncDigest
            let document = digest == acknowledgedDigest ? nil : try ProfileCloudDocument.encode(normalized)
            try Task.checkCancellation()
            return PreparedProfileCloudState(digest: digest, document: document, updatedAt: state.updatedAt)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }

    static func decode(_ data: Data) async throws -> (state: ProfileState, digest: String) {
        let worker = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            let state = try ProfileCloudDocument.decode(data)
            let digest = state.syncDigest
            try Task.checkCancellation()
            return (state, digest)
        }
        return try await withTaskCancellationHandler { try await worker.value } onCancel: { worker.cancel() }
    }
}
