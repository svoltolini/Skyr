import Foundation
import Network

/// A recovery choice identifies both the saved library and the authenticated context shown to the
/// person. It never carries passwords, cached audio, or permission to connect to a different NAS.
public nonisolated struct LegacyLibraryRecovery: Identifiable, Hashable, Sendable {
    public let legacySourceID: String
    public let sourceID: String
    public let profileID: String
    public let profileSessionID: UUID
    public let address: String
    public let account: String
    public let favouritesCount: Int
    public let playlistsCount: Int
    public let historyCount: Int

    public var id: String { "\(profileID)|\(legacySourceID)|\(sourceID)" }

    /// Older SynologyDrive versions used URL.host(), without a scheme, port, or account.
    static func isLegacySourceID(_ id: String) -> Bool {
        guard !id.isEmpty,
              id.range(of: #"^nas-v2-[0-9a-f]{64}$"#, options: .regularExpression) == nil else { return false }
        let unbracketed = id.hasPrefix("[") && id.hasSuffix("]") ? String(id.dropFirst().dropLast()) : id
        if IPv6Address(unbracketed) != nil { return true }
        guard let parsed = SynologyClient.baseURL(from: id), let host = parsed.host() else { return false }
        return host.caseInsensitiveCompare(id) == .orderedSame
    }
}

public extension AppModel {
    /// Listing an older library makes no changes. The current network session and catalogue must
    /// already agree on the new source before the person can copy their saved listening data.
    var legacyLibraryRecoveries: [LegacyLibraryRecovery] {
        guard stage == .ready, !isScanning, !isSigningIn, !isReconnecting, !isRestoring, !isJoiningFamily,
              pendingServer == nil, isConnected, !isDemo, let connection,
              library.catalogue.driveID == connection.sourceID, library.drive?.id == connection.sourceID,
              let profiles, !profiles.isLocked, let profileID = profiles.activeID,
              let profileSessionID = profiles.sessionID, let origin = NASOrigin(url: connection.baseURL) else { return [] }
        return profiles.state.libraries.keys.sorted().compactMap { oldID in
            guard LegacyLibraryRecovery.isLegacySourceID(oldID),
                  !profiles.hasRecoveredLibrary(from: oldID, to: connection.sourceID),
                  let saved = profiles.state.libraries[oldID], saved != LibraryState() else { return nil }
            return LegacyLibraryRecovery(
                legacySourceID: oldID, sourceID: connection.sourceID, profileID: profileID,
                profileSessionID: profileSessionID, address: origin.identifier, account: connection.account,
                favouritesCount: saved.favourites.count, playlistsCount: saved.playlists.count,
                historyCount: saved.played.count + saved.recentAlbums.count
            )
        }
    }

    /// Called only after confirming the old server and this destination in the recovery UI.
    /// The store merges into current values and writes the receipt with them before reporting success.
    func recoverLegacyLibrary(_ choice: LegacyLibraryRecovery) -> String? {
        guard let profiles, profiles.activeID == choice.profileID, profiles.sessionID == choice.profileSessionID,
              legacyLibraryRecoveries.contains(where: { $0.id == choice.id && $0.profileSessionID == choice.profileSessionID }) else {
            return "The profile, server or library changed. Finish any scan and review the saved library again before recovering it."
        }
        guard profiles.recoverLibrary(from: choice.legacySourceID, to: choice.sourceID) else {
            return "The saved library could not be recovered. Your original data is still kept; try again."
        }
        library.loadProfileState()
        return nil
    }
}
