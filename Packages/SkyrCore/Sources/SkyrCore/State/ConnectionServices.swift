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
}

extension Catalogue {
    /// A saved library is usable only for the same server and selected folder.
    func belongs(to connection: ServerConnection) -> Bool {
        guard let path = connection.musicPath else { return false }
        return driveID == connection.host && rootPath == path
    }
}
