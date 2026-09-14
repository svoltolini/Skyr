import CryptoKit
import Foundation

public nonisolated enum ProfileHistory: String, Sendable { case played, recentAlbums, searches }

/// Local edits retain the bounded visible history plus observation clocks. Merge never prunes:
/// concurrent events remain associative until an actual local edit acknowledges them, including
/// events outside the display cap. Observation clocks replace an unbounded tombstone per old play.
nonisolated struct ProfileHistorySync: Codable, Sendable, Equatable {
    struct Event: Codable, Sendable, Equatable {
        var key: String
        var value: String
        var revision: ProfileRevision
        var order: Int
    }
    var entries: [String: Event] = [:]
    var observed: [String: Double] = [:]

    private var ordered: [(key: String, value: Event)] {
        entries.sorted {
            if $0.value.revision != $1.value.revision { return $1.value.revision < $0.value.revision }
            if $0.value.order != $1.value.order { return $0.value.order < $1.value.order }
            return $0.key < $1.key
        }
    }

    private static func keys(_ values: [String]) -> [String] {
        var count: [String: Int] = [:]
        return values.map { value in
            let occurrence = count[value, default: 0]
            count[value] = occurrence + 1
            return Data(value.utf8).base64EncodedString() + ":" + String(occurrence)
        }
    }

    var values: [String] {
        var seen: Set<String> = []
        return ordered.filter { seen.insert($0.value.key).inserted }.map(\.value.value)
    }

    mutating func update(from old: [String], to new: [String], revision: ProfileRevision, forceFirst: Bool = false) {
        var stamp = revision
        if stamp.operation == "legacy" {
            stamp.operation += ":" + SHA256.hash(data: Data(Self.keys(new).joined(separator: "|").utf8)).description
        }
        let oldKeys = Self.keys(old), newKeys = Self.keys(new)
        var changed = Set(newKeys.difference(from: oldKeys).compactMap { change -> String? in
            if case .insert(_, let key, _) = change { return key }; return nil
        })
        if forceFirst, let first = newKeys.first { changed.insert(first) }
        var winners: [String: (String, Event)] = [:]
        for pair in ordered where winners[pair.value.key] == nil { winners[pair.value.key] = (pair.key, pair.value) }
        var retained: [String: Event] = [:]
        for index in newKeys.indices {
            let key = newKeys[index]
            if !changed.contains(key), let (id, event) = winners[key] { retained[id] = event }
            else {
                let id = stamp.operation + ":" + String(stamp.time.bitPattern) + ":" + key
                retained[id] = Event(key: key, value: new[index], revision: stamp, order: index)
                observed[stamp.operation] = max(observed[stamp.operation] ?? stamp.time, stamp.time)
            }
        }
        entries = retained
    }

    func merged(with other: Self) -> Self {
        var result = Self()
        for (id, event) in entries where other.entries[id] != nil || (other.observed[event.revision.operation] ?? -.infinity) < event.revision.time {
            result.entries[id] = event
        }
        for (id, event) in other.entries where entries[id] != nil || (observed[event.revision.operation] ?? -.infinity) < event.revision.time {
            if let known = result.entries[id], known != event {
                // Only relevant to duplicate legacy snapshots; real operation IDs identify one event.
                result.entries[id] = known.order < event.order ? known : event
            } else { result.entries[id] = event }
        }
        result.observed = observed
        for (actor, time) in other.observed { result.observed[actor] = max(result.observed[actor] ?? time, time) }
        return result
    }

    mutating func importMissing(_ values: [String], revision: ProfileRevision) {
        guard observed.isEmpty else { return }
        update(from: [], to: values, revision: revision)
    }
}
