import Foundation

/// Large documents use a versioned envelope in the existing CloudKit Data field. The new reader
/// accepts both formats; old clients need this app update to read an enveloped large document.
nonisolated enum ProfileCloudDocument {
    static let maximumRecordBytes = 900_000
    private static let magic = Data("SKYR-PROFILE-1\0".utf8)

    enum Failure: LocalizedError {
        case tooLarge
        var errorDescription: String? {
            "This profile's saved data is too large for iCloud. It remains saved on this device."
        }
    }

    static func encode(_ state: ProfileState) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = try encoder.encode(state.normalizedForSync())
        if json.count <= maximumRecordBytes { return json }
        let compressed = magic + (try ProfileStateSyncCodec.compress(json))
        guard compressed.count <= maximumRecordBytes else { throw Failure.tooLarge }
        return compressed
    }

    static func decode(_ data: Data) throws -> ProfileState {
        let json = data.starts(with: magic) ? try ProfileStateSyncCodec.decompress(data.dropFirst(magic.count)) : data
        guard ProfileStateSyncCodec.permitsDecodedSize(json.count) else { throw CocoaError(.fileReadCorruptFile) }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProfileState.self, from: json)
    }
}
