import CryptoKit
import Foundation

/// One atomic snapshot per verified Apple Account. Family zones never share a cursor or record tag.
struct CloudAccountState: Codable {
    struct Zone: Codable {
        var changeToken: Data?
        var systemFields: [String: Data] = [:]
        var remoteStamps: [String: Date] = [:]
        /// Kept after acknowledgement too: delayed pages must never resurrect a deleted profile.
        var deletions: [String: Set<String>] = [:]
    }

    var account: String
    var membership = "owner"
    var zoneOwner: String
    var subscribed = false
    /// Local profiles known to belong to this account; a different account cannot upload them.
    var profileIDs: Set<String> = []
    var zones: [String: Zone] = [:]
}

struct CloudPersistence {
    let directory: URL

    func hasSnapshot(account: String) -> Bool { FileManager.default.fileExists(atPath: file(account: account).path) }

    /// Offline deletion can target a previously verified scope without treating it as the signed-in
    /// account. Ambiguous ownership waits for verification instead of choosing an account silently.
    func deletionContext(profileID: String) throws -> CloudAccountState? {
        let matches = try accountSnapshots().filter { $0.profileIDs.contains(profileID) }
        return matches.count == 1 ? matches.first : nil
    }

    func hasCloudAssociation(profileID: String) throws -> Bool {
        if try accountSnapshots().contains(where: { $0.profileIDs.contains(profileID) }) { return true }
        // Before migration, old global record metadata is evidence that local profiles may exist remotely.
        guard !FileManager.default.fileExists(atPath: directory.appending(path: "legacy-profile-account.json").path) else { return false }
        return ["cloud-system-fields.json", "cloud-remote-stamps.json"].contains {
            FileManager.default.fileExists(atPath: directory.appending(path: $0).path)
        }
    }

    private func accountSnapshots() throws -> [CloudAccountState] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var snapshots: [CloudAccountState] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            where url.lastPathComponent.hasPrefix("account-") && url.pathExtension == "json" {
            let state = try JSONDecoder().decode(CloudAccountState.self, from: Data(contentsOf: url))
            guard file(account: state.account).lastPathComponent == url.lastPathComponent else { throw CocoaError(.fileReadCorruptFile) }
            snapshots.append(state)
        }
        return snapshots
    }

    /// Old profile files have no account provenance. Only the first verified account may adopt them.
    func claimsLegacyProfiles(account: String) throws -> Bool {
        let url = directory.appending(path: "legacy-profile-account.json")
        if FileManager.default.fileExists(atPath: url.path) {
            return try JSONDecoder().decode(String.self, from: Data(contentsOf: url)) == account
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(account).write(to: url, options: .atomic)
        return true
    }

    func load(account: String, defaultOwner: String) throws -> CloudAccountState {
        let url = file(account: account)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CloudAccountState(account: account, zoneOwner: defaultOwner)
        }
        let state = try JSONDecoder().decode(CloudAccountState.self, from: Data(contentsOf: url))
        guard state.account == account else { throw CocoaError(.fileReadCorruptFile) }
        return state
    }

    func save(_ state: CloudAccountState) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(state).write(to: file(account: state.account), options: .atomic)
    }

    private func file(account: String) -> URL {
        let key = SHA256.hash(data: Data(account.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appending(path: "account-\(key).json")
    }
}
