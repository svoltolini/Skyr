import CryptoKit
import Compression
import Foundation

/// A hybrid logical clock: a local edit follows every observed edit even after clock rollback.
/// The operation ID breaks concurrent ties without depending on device arrival order.
nonisolated struct ProfileRevision: Codable, Sendable, Equatable, Comparable {
    var time: Double
    var operation: String

    static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.time == rhs.time ? lhs.operation < rhs.operation : lhs.time < rhs.time
    }
}

nonisolated private func canonical<Value: Encodable>(_ value: Value) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    // These values contain only finite clocks and ordinary Codable primitives.
    return (try? encoder.encode(value)) ?? Data()
}

nonisolated struct ProfileRegister<Value: Codable & Sendable & Equatable>: Codable, Sendable, Equatable {
    var value: Value
    var revision: ProfileRevision

    func merged(with other: Self) -> Self {
        if revision != other.revision { return revision < other.revision ? other : self }
        if let date = value as? Date, let otherDate = other.value as? Date, date != otherDate {
            return date < otherDate ? other : self
        }
        // Legacy documents can have equal timestamps and different values. Resolve those ties too.
        return canonical(value).lexicographicallyPrecedes(canonical(other.value)) ? other : self
    }
}

/// An ordered set of occurrences. Membership and position have separate revisions, so a reorder
/// does not restore a removed item. Occurrence keys also retain duplicate tracks in old playlists.
nonisolated struct ProfileSequence: Codable, Sendable, Equatable {
    struct Entry: Codable, Sendable, Equatable {
        var value: String
        var present: ProfileRegister<Bool>
        var position: ProfileRegister<[Int]>
    }

    var entries: [String: Entry] = [:]

    private static func keys(_ values: [String]) -> [String] {
        var occurrences: [String: Int] = [:]
        return values.map { value in
            let occurrence = occurrences[value, default: 0]
            occurrences[value] = occurrence + 1
            return canonical([value, String(occurrence)]).base64EncodedString()
        }
    }

    var values: [String] {
        entries.filter { $0.value.present.value }.sorted { left, right in
            let a = left.value.position, b = right.value.position
            if a.value != b.value { return a.value.lexicographicallyPrecedes(b.value) }
            if a.revision != b.revision { return b.revision < a.revision }
            return left.key < right.key
        }.map(\.value.value)
    }

    /// Histories rank independent new events by their clocks, keeping one operation's input order.
    var recentValues: [String] {
        entries.filter { $0.value.present.value }.sorted { left, right in
            let a = left.value.position, b = right.value.position
            if a.revision != b.revision { return b.revision < a.revision }
            if a.value != b.value { return a.value.lexicographicallyPrecedes(b.value) }
            return left.key < right.key
        }.map(\.value.value)
    }

    /// Fractional positions avoid renumbering unchanged songs when another song is inserted.
    /// Digits can grow to arbitrary depth; concurrent insertions at a gap use the revision tie-break.
    private static func between(_ left: [Int]?, _ right: [Int]?) -> [Int] {
        if left == nil && right == nil { return [0] }
        if let first = left?.first, right == nil, first < Int.max - 1_024 { return [first + 1_024] }
        if let first = right?.first, left == nil, first > Int.min + 1_024 { return [first - 1_024] }
        var result: [Int] = []
        var index = 0
        var upperBound = right
        while true {
            let low = left.flatMap { index < $0.count ? $0[index] : nil } ?? 0
            let high = upperBound.flatMap { index < $0.count ? $0[index] : nil } ?? 65_536
            // This midpoint remains inside the interval even when its span exceeds Int.max.
            let middle = midpoint(low, high)
            if middle > low { return result + [middle] }
            result.append(low)
            if low != high { upperBound = nil }
            index += 1
        }
    }

    static func midpoint(_ low: Int, _ high: Int) -> Int { (low & high) + ((low ^ high) >> 1) }

    mutating func update(from old: [String], to new: [String], revision: ProfileRevision) {
        let oldKeys = Self.keys(old), newKeys = Self.keys(new)
        let oldSet = Set(oldKeys), newSet = Set(newKeys)
        for key in oldSet.subtracting(newSet) {
            entries[key]?.present = .init(value: false, revision: revision)
        }
        let inserted = Set(newKeys.difference(from: oldKeys).compactMap { change -> String? in
            if case .insert(_, let key, _) = change { return key }
            return nil
        })
        var following: [String?] = Array(repeating: nil, count: newKeys.count)
        var nextUnchanged: String?
        for index in newKeys.indices.reversed() {
            following[index] = nextUnchanged
            if !inserted.contains(newKeys[index]), entries[newKeys[index]] != nil { nextUnchanged = newKeys[index] }
        }
        var previous: [Int]?
        for index in newKeys.indices {
            let key = newKeys[index]
            if inserted.contains(key) || entries[key] == nil {
                let next = following[index]
                let bytes = Array(SHA256.hash(data: Data((revision.operation + key).utf8)).prefix(16))
                let suffix = stride(from: 0, to: bytes.count, by: 2).map { Int(bytes[$0]) * 256 + Int(bytes[$0 + 1]) + 1 }
                let position = Self.between(previous, next.flatMap { entries[$0]?.position.value }) + suffix
                if var entry = entries[key] {
                    if !oldSet.contains(key) { entry.present = .init(value: true, revision: revision) }
                    entry.position = .init(value: position, revision: revision)
                    entries[key] = entry
                } else {
                    entries[key] = Entry(value: new[index], present: .init(value: true, revision: revision),
                                         position: .init(value: position, revision: revision))
                }
            }
            previous = entries[key]?.position.value
        }
    }

    func merged(with other: Self) -> Self {
        var result = self
        for (key, incoming) in other.entries {
            guard let local = result.entries[key] else { result.entries[key] = incoming; continue }
            result.entries[key] = Entry(value: max(local.value, incoming.value), present: local.present.merged(with: incoming.present),
                                        position: local.position.merged(with: incoming.position))
        }
        return result
    }

    mutating func importMissing(_ values: [String], revision: ProfileRevision) {
        let known = Set(entries.keys)
        let extra = zip(Self.keys(values), values).filter { !known.contains($0.0) }.map(\.1)
        let current = self.values
        update(from: current, to: current + extra, revision: revision)
    }
}

nonisolated struct ProfilePlaylistSync: Codable, Sendable, Equatable {
    var name: ProfileRegister<String>
    var created: ProfileRegister<Date>
    var tracks = ProfileSequence()

    func merged(with other: Self) -> Self {
        Self(name: name.merged(with: other.name), created: created.merged(with: other.created),
             tracks: tracks.merged(with: other.tracks))
    }
}

// Sync metadata is saved on every device and in every family member's iCloud copy, so a field
// added by one release must decode from documents that predate it. Synthesized Decodable treats
// every non-optional stored property as required, even one with a default value: the download
// membership added in #74 made every earlier document unreadable (#94). These decoders live in
// extensions so the memberwise initializers stay available.
nonisolated extension ProfilePlaylistSync {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(ProfileRegister<String>.self, forKey: .name)
        created = try container.decode(ProfileRegister<Date>.self, forKey: .created)
        tracks = try container.decodeIfPresent(ProfileSequence.self, forKey: .tracks) ?? ProfileSequence()
    }
}

nonisolated struct ProfileLibrarySync: Codable, Sendable, Equatable {
    var favourites = ProfileSequence()
    var playlistOrder = ProfileSequence()
    var playlists: [String: ProfilePlaylistSync] = [:]
    var played = ProfileHistorySync()
    var recentAlbums = ProfileHistorySync()
    var searches = ProfileHistorySync()
    /// Album ids marked for offline download. Membership survives reinstall; files re-fetch from NAS.
    var downloadedAlbums = ProfileSequence()
    /// Playlist ids marked for offline download. Membership survives reinstall; files re-fetch from NAS.
    var downloadedPlaylists = ProfileSequence()

    mutating func update(from old: LibraryState, to new: LibraryState, revision: ProfileRevision, recordingHistory: ProfileHistory? = nil) {
        if old.favourites != new.favourites { favourites.update(from: old.favourites, to: new.favourites, revision: revision) }
        if old.played != new.played || recordingHistory == .played { played.update(from: old.played, to: new.played, revision: revision, forceFirst: recordingHistory == .played) }
        if old.recentAlbums != new.recentAlbums || recordingHistory == .recentAlbums { recentAlbums.update(from: old.recentAlbums, to: new.recentAlbums, revision: revision, forceFirst: recordingHistory == .recentAlbums) }
        if old.searches != new.searches || recordingHistory == .searches { searches.update(from: old.searches, to: new.searches, revision: revision, forceFirst: recordingHistory == .searches) }
        if old.downloadedAlbums != new.downloadedAlbums { downloadedAlbums.update(from: old.downloadedAlbums, to: new.downloadedAlbums, revision: revision) }
        if old.downloadedPlaylists != new.downloadedPlaylists { downloadedPlaylists.update(from: old.downloadedPlaylists, to: new.downloadedPlaylists, revision: revision) }
        guard old.playlists != new.playlists else { return }
        playlistOrder.update(from: old.playlists.map(\.id), to: new.playlists.map(\.id), revision: revision)
        for playlist in new.playlists {
            let previous = old.playlists.first { $0.id == playlist.id }
            var saved = playlists[playlist.id] ?? ProfilePlaylistSync(
                name: .init(value: playlist.name, revision: revision), created: .init(value: playlist.created, revision: revision))
            if previous?.name != playlist.name { saved.name = .init(value: playlist.name, revision: revision) }
            if previous?.created != playlist.created { saved.created = .init(value: playlist.created, revision: revision) }
            if previous?.trackIDs != playlist.trackIDs { saved.tracks.update(from: previous?.trackIDs ?? [], to: playlist.trackIDs, revision: revision) }
            playlists[playlist.id] = saved
        }
    }

    func merged(with other: Self) -> Self {
        var result = Self(favourites: favourites.merged(with: other.favourites),
                          playlistOrder: playlistOrder.merged(with: other.playlistOrder), playlists: playlists,
                          played: played.merged(with: other.played), recentAlbums: recentAlbums.merged(with: other.recentAlbums),
                          searches: searches.merged(with: other.searches),
                          downloadedAlbums: downloadedAlbums.merged(with: other.downloadedAlbums),
                          downloadedPlaylists: downloadedPlaylists.merged(with: other.downloadedPlaylists))
        for (id, incoming) in other.playlists {
            result.playlists[id] = result.playlists[id].map { $0.merged(with: incoming) } ?? incoming
        }
        return result
    }

    var library: LibraryState {
        var result = LibraryState()
        result.favourites = favourites.values
        result.played = Array(played.values.prefix(100))
        result.recentAlbums = Array(recentAlbums.values.prefix(30))
        result.searches = Array(searches.values.prefix(8))
        result.playlists = playlistOrder.values.compactMap { id in
            guard let playlist = playlists[id] else { return nil }
            return LocalPlaylist(id: id, name: playlist.name.value, trackIDs: playlist.tracks.values, created: playlist.created.value)
        }
        result.downloadedAlbums = downloadedAlbums.values
        result.downloadedPlaylists = downloadedPlaylists.values
        return result
    }
}

nonisolated extension ProfileLibrarySync {
    /// A key an older release never wrote means that part of the library had no edits yet.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        favourites = try container.decodeIfPresent(ProfileSequence.self, forKey: .favourites) ?? ProfileSequence()
        playlistOrder = try container.decodeIfPresent(ProfileSequence.self, forKey: .playlistOrder) ?? ProfileSequence()
        playlists = try container.decodeIfPresent([String: ProfilePlaylistSync].self, forKey: .playlists) ?? [:]
        played = try container.decodeIfPresent(ProfileHistorySync.self, forKey: .played) ?? ProfileHistorySync()
        recentAlbums = try container.decodeIfPresent(ProfileHistorySync.self, forKey: .recentAlbums) ?? ProfileHistorySync()
        searches = try container.decodeIfPresent(ProfileHistorySync.self, forKey: .searches) ?? ProfileHistorySync()
        downloadedAlbums = try container.decodeIfPresent(ProfileSequence.self, forKey: .downloadedAlbums) ?? ProfileSequence()
        downloadedPlaylists = try container.decodeIfPresent(ProfileSequence.self, forKey: .downloadedPlaylists) ?? ProfileSequence()
    }
}

/// Only the additive merge metadata is compressed. Existing v1.0 readers still see their familiar
/// JSON fields, and CloudKit still stores the existing `document` Data field (no new schema).
nonisolated enum ProfileStateSyncCodec {
    static let maximumDecodedBytes = 64 * 1_024 * 1_024

    static func permitsDecodedSize(_ count: Int) -> Bool { count > 0 && count <= maximumDecodedBytes }

    static func encode(_ metadata: ProfileStateSync) throws -> Data {
        try compress(canonical(metadata))
    }

    static func compress(_ raw: Data) throws -> Data {
        guard permitsDecodedSize(raw.count) else { throw CocoaError(.fileWriteOutOfSpace) }
        var output = [UInt8](repeating: 0, count: raw.count + 1_024)
        let written = raw.withUnsafeBytes { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_encode_buffer(destination.baseAddress!, destination.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written > 0 else { throw CocoaError(.fileWriteUnknown) }
        var result = Data([1]) // Metadata encoding version.
        let length = UInt32(raw.count)
        result.append(contentsOf: [UInt8((length >> 24) & 255), UInt8((length >> 16) & 255), UInt8((length >> 8) & 255), UInt8(length & 255)])
        result.append(contentsOf: output.prefix(written))
        return result
    }

    static func decode(_ data: Data) throws -> ProfileStateSync {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(ProfileStateSync.self, from: decompress(data))
    }

    static func decompress(_ data: Data) throws -> Data {
        guard data.count > 5, data[data.startIndex] == 1 else { throw CocoaError(.fileReadCorruptFile) }
        let size = data.dropFirst().prefix(4).reduce(0) { ($0 << 8) | Int($1) }
        guard permitsDecodedSize(size) else { throw CocoaError(.fileReadCorruptFile) }
        var output = [UInt8](repeating: 0, count: size)
        let written = data.dropFirst(5).withUnsafeBytes { source in
            output.withUnsafeMutableBufferPointer { destination in
                compression_decode_buffer(destination.baseAddress!, destination.count,
                                          source.bindMemory(to: UInt8.self).baseAddress!, source.count, nil, COMPRESSION_LZFSE)
            }
        }
        guard written == size else { throw CocoaError(.fileReadCorruptFile) }
        return Data(output)
    }
}

nonisolated struct ProfileStateSync: Codable, Sendable, Equatable {
    var clock: ProfileRevision
    var settings: [String: ProfileRegister<String>] = [:]
    var libraries: [String: ProfileLibrarySync] = [:]
    var recoveredLibraries: [String: ProfileRevision]? = nil

    mutating func update(from old: ProfileState, to new: ProfileState, revision: ProfileRevision, recordingHistory: (String, ProfileHistory)? = nil) {
        let previous = old.settings.syncValues
        for (key, value) in new.settings.syncValues where settings[key] == nil || previous[key] != value {
            settings[key] = .init(value: value, revision: revision)
        }
        for id in Set(old.libraries.keys).union(new.libraries.keys) {
            guard old.libraries[id] != new.libraries[id] || recordingHistory?.0 == id else { continue }
            var library = libraries[id] ?? ProfileLibrarySync()
            library.update(from: old.libraries[id] ?? LibraryState(), to: new.libraries[id] ?? LibraryState(), revision: revision,
                           recordingHistory: recordingHistory?.0 == id ? recordingHistory?.1 : nil)
            libraries[id] = library
        }
        clock = max(clock, revision)
    }

    func merged(with other: Self) -> Self {
        var result = self
        result.clock = max(clock, other.clock)
        for (key, incoming) in other.settings { result.settings[key] = result.settings[key].map { $0.merged(with: incoming) } ?? incoming }
        for (id, incoming) in other.libraries { result.libraries[id] = result.libraries[id].map { $0.merged(with: incoming) } ?? incoming }
        for (key, revision) in other.recoveredLibraries ?? [:] {
            result.recoveredLibraries = result.recoveredLibraries ?? [:]
            let previous = result.recoveredLibraries?[key] ?? revision
            result.recoveredLibraries?[key] = max(previous, revision)
        }
        return result
    }

    func materialized(updatedAt: Date) -> ProfileState {
        var result = ProfileState()
        result.sync = self
        result.updatedAt = updatedAt
        result.libraries = libraries.mapValues(\.library)
        result.settings.quality = settings["quality"]?.value ?? "Lossless"
        result.settings.gapless = settings["gapless"]?.value != "false"
        result.settings.appearance = settings["appearance"]?.value ?? "Auto"
        result.settings.hidesBracketedTitleParts = settings["hidesBracketedTitleParts"]?.value == "true"
        result.settings.repeatMode = settings["repeatMode"]?.value ?? "off"
        result.settings.shuffle = settings["shuffle"]?.value == "true"
        return result
    }
}

nonisolated extension ProfileStateSync {
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        clock = try container.decode(ProfileRevision.self, forKey: .clock)
        settings = try container.decodeIfPresent([String: ProfileRegister<String>].self, forKey: .settings) ?? [:]
        libraries = try container.decodeIfPresent([String: ProfileLibrarySync].self, forKey: .libraries) ?? [:]
        recoveredLibraries = try container.decodeIfPresent([String: ProfileRevision].self, forKey: .recoveredLibraries)
    }
}

extension ProfileSettings {
    fileprivate nonisolated var syncValues: [String: String] {
        ["quality": quality, "gapless": String(gapless), "appearance": appearance,
         "hidesBracketedTitleParts": String(hidesBracketedTitleParts), "repeatMode": repeatMode, "shuffle": String(shuffle)]
    }
}

extension ProfileState {
    private nonisolated static func recoveryKey(from source: String, to destination: String) -> String {
        canonical([source, destination]).base64EncodedString()
    }

    nonisolated func hasRecoveredLibrary(from source: String, to destination: String) -> Bool {
        sync?.recoveredLibraries?[Self.recoveryKey(from: source, to: destination)] != nil
    }

    /// Recovery imports only unknown items. Existing target revisions, including removals, always
    /// take precedence, even when the old source carries a newer whole-document timestamp.
    nonisolated func recoveringLibrary(from source: String, to destination: String) -> Self? {
        guard source != destination, let legacy = libraries[source], !hasRecoveredLibrary(from: source, to: destination),
              var metadata = normalizedForSync().sync else { return nil }
        let key = Self.recoveryKey(from: source, to: destination)
        let baseline = ProfileRevision(time: Date.distantPast.timeIntervalSince1970, operation: "recovery-" + key)
        var target = metadata.libraries[destination] ?? ProfileLibrarySync()
        target.favourites.importMissing(legacy.favourites, revision: baseline)
        let knownPlaylists = Set(target.playlists.keys)
        target.playlistOrder.importMissing(legacy.playlists.map(\.id), revision: baseline)
        for playlist in legacy.playlists {
            if !knownPlaylists.contains(playlist.id) {
                target.playlists[playlist.id] = ProfilePlaylistSync(name: .init(value: playlist.name, revision: baseline),
                                                                   created: .init(value: playlist.created, revision: baseline))
            }
            target.playlists[playlist.id]?.tracks.importMissing(playlist.trackIDs, revision: baseline)
        }
        // Histories are preferences about recency; preserve a destination history already used.
        if target.played.entries.isEmpty { target.played.importMissing(legacy.played, revision: baseline) }
        if target.recentAlbums.entries.isEmpty { target.recentAlbums.importMissing(legacy.recentAlbums, revision: baseline) }
        if target.searches.entries.isEmpty { target.searches.importMissing(legacy.searches, revision: baseline) }
        // Download membership: files may need re-fetch, but the list survives.
        target.downloadedAlbums.importMissing(legacy.downloadedAlbums, revision: baseline)
        target.downloadedPlaylists.importMissing(legacy.downloadedPlaylists, revision: baseline)
        metadata.libraries[destination] = target
        let receipt = ProfileRevision(time: max(Date.now.timeIntervalSince1970, metadata.clock.time.nextUp), operation: UUID().uuidString)
        metadata.recoveredLibraries = metadata.recoveredLibraries ?? [:]
        metadata.recoveredLibraries?[key] = receipt
        metadata.clock = receipt
        return metadata.materialized(updatedAt: Date(timeIntervalSince1970: receipt.time))
    }

    /// Old snapshots contain no evidence of deletions. Seed only their present values; subsequent
    /// edits retain tombstones indefinitely so an offline device cannot resurrect removed data.
    nonisolated func normalizedForSync() -> Self {
        if let sync { return sync.materialized(updatedAt: updatedAt) }
        let revision = ProfileRevision(time: updatedAt.timeIntervalSince1970, operation: "legacy")
        var metadata = ProfileStateSync(clock: revision)
        metadata.update(from: ProfileState(), to: self, revision: revision)
        return metadata.materialized(updatedAt: updatedAt)
    }

    nonisolated mutating func recordChanges(from previous: Self, at date: Date = .now, operationID: String = UUID().uuidString, recordingHistory: (String, ProfileHistory)? = nil) {
        let old = previous.normalizedForSync()
        guard var metadata = old.sync else { return }
        let revision = ProfileRevision(time: max(date.timeIntervalSince1970, metadata.clock.time.nextUp), operation: operationID)
        metadata.update(from: previous, to: self, revision: revision, recordingHistory: recordingHistory)
        self = metadata.materialized(updatedAt: Date(timeIntervalSince1970: revision.time))
    }

    nonisolated func merged(with other: Self) -> Self {
        let local = normalizedForSync(), incoming = other.normalizedForSync()
        guard let left = local.sync, let right = incoming.sync else { return local }
        return left.merged(with: right).materialized(updatedAt: max(updatedAt, other.updatedAt))
    }

    /// Compare merge content, not the document date (two independent edits can share that date).
    nonisolated var syncDigest: String {
        SHA256.hash(data: canonical(normalizedForSync().sync)).map { String(format: "%02x", $0) }.joined()
    }
}
