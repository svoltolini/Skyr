import Foundation

/// Buffers at most the caller's limit, including responses with no reliable Content-Length.
nonisolated enum BoundedBytes {
    static func collect<S: AsyncSequence>(_ bytes: S, maximum: Int64, expectedLength: Int64 = -1) async throws -> Data
    where S.Element == UInt8 {
        guard maximum >= 0, let limit = Int(exactly: maximum), expectedLength <= maximum else {
            throw RemoteDriveError.tooLarge
        }
        try Task.checkCancellation()
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < limit else { throw RemoteDriveError.tooLarge }
            data.append(byte)
        }
        try Task.checkCancellation()
        return data
    }
}
