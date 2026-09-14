import Foundation

/// The external effects of opening or restoring a connection, replaceable in isolated tests.
struct ConnectionServices {
    var login: (URL, String, String, String?) async throws -> DSMSession = {
        try await SynologyClient.login(baseURL: $0, account: $1, password: $2, otpCode: $3)
    }
    var info: (DSMSession) async -> SynologyDSMInfo? = { await SynologyClient.info($0) }
    var logout: (DSMSession) async -> Void = { await SynologyClient.logout($0) }
    var password: (String) -> String? = { KeychainStore.password(for: $0) }
    var savePassword: (String, String) -> Void = { KeychainStore.save(password: $0, for: $1) }
    var deletePassword: (String) -> Void = { KeychainStore.delete(account: $0) }
    var loadCatalogue: () -> Catalogue? = { LibraryStore.loadCachedCatalogue() }
    var deleteCatalogue: () -> Void = { LibraryStore.deleteCache() }
    var log: (String) -> Void = { DiagnosticsLog.shared.record($0) }
    var canManageUsers: (DSMSession) async -> Bool? = { await SynologyClient.canManageUsers($0) }
    var confirmPassword: (DSMSession, String) async -> String? = { await SynologyClient.confirmToken($0, password: $1) }
    var createFamilyUser: (DSMSession, String, String, String, String?) async throws -> Void = {
        try await SynologyClient.createFamilyUser($0, name: $1, password: $2, shareName: $3, confirm: $4)
    }
    var setFamilyPassword: (DSMSession, String, String, String?) async throws -> Void = {
        try await SynologyClient.setPassword($0, user: $1, password: $2, confirm: $3)
    }
    var deleteFamilyUser: (DSMSession, String, String?) async throws -> Void = {
        try await SynologyClient.deleteUser($0, name: $1, confirm: $2)
    }
}

extension Catalogue {
    /// A saved library is usable only for the same server and selected folder.
    func belongs(to connection: ServerConnection) -> Bool {
        guard let path = connection.musicPath else { return false }
        return driveID == connection.sourceID && rootPath == path
    }
}
