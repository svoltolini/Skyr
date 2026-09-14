import Foundation
import Testing
@testable import SkyrCore

@MainActor private final class ConnectionFixture {
    let suite = "SkyrConnectionTests.\(UUID().uuidString)"
    let defaults: UserDefaults
    let library = LibraryStore()
    var services = ConnectionServices()
    var loggedOut: [String] = []

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(3, forKey: "coverCacheVersion")
        services.password = { _ in "test password" }
        services.savePassword = { _, _ in }
        services.deletePassword = { _ in }
        services.loadCatalogue = { nil }
        services.deleteCatalogue = {}
        services.log = { _ in }
        services.info = { _ in nil }
        services.logout = { [weak self] in self?.loggedOut.append($0.sid) }
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
    func model(restore: Bool = false) -> AppModel {
        AppModel(library: library, defaults: defaults, services: services, restoresSession: restore)
    }
    func save(_ connection: ServerConnection) throws {
        defaults.set(try JSONEncoder().encode(connection), forKey: "connection")
    }
}

@MainActor private final class PendingLogin {
    var continuation: CheckedContinuation<DSMSession, Error>?
    func login(_ url: URL, _ account: String, _ password: String, _ otp: String?) async throws -> DSMSession {
        try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func finish(_ sid: String = "test-session") {
        continuation?.resume(returning: DSMSession(baseURL: URL(string: "https://nas.example:5001")!, sid: sid, apis: [:]))
        continuation = nil
    }
}

@MainActor private func waitUntil(_ condition: () -> Bool) async throws {
    for _ in 0..<200 {
        if condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(condition(), "The controlled asynchronous operation should have started")
}

@Test @MainActor func cancelledSignInDoesNotInstallItsSession() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let login = PendingLogin()
    fixture.services.login = login.login
    let model = fixture.model()
    #expect(model.enterAddress("https://nas.example:5001"))
    let task = Task { await model.signIn(account: "listener", password: "test", otpCode: "", remember: false) }
    try await waitUntil { login.continuation != nil }
    model.cancelSignIn()
    login.finish()
    await task.value
    #expect(model.connection == nil)
    #expect(!model.isConnected)
    #expect(model.pendingServer == nil)
    #expect(fixture.defaults.data(forKey: "connection") == nil)
    #expect(fixture.loggedOut == ["test-session"])
}

@Test @MainActor func supersededSignInLeavesTheNewSelectionIntact() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let login = PendingLogin()
    fixture.services.login = login.login
    let model = fixture.model()
    #expect(model.enterAddress("https://nas.example:5001"))
    let task = Task { await model.signIn(account: "listener", password: "test", otpCode: "", remember: false) }
    try await waitUntil { login.continuation != nil }
    #expect(model.enterAddress("https://other.example:5001"))
    login.finish()
    await task.value
    #expect(model.pendingServer?.host == "other.example")
    #expect(model.connection == nil)
    #expect(!model.isSigningIn)
}

@Test @MainActor func ordinarySignInOpensFolderSelection() async {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    fixture.services.login = { url, _, _, _ in DSMSession(baseURL: url, sid: "ordinary", apis: [:]) }
    let model = fixture.model()
    #expect(model.enterAddress("https://nas.example:5001"))
    await model.signIn(account: "listener", password: "test", otpCode: "", remember: false)
    #expect(model.isConnected)
    #expect(model.connection?.account == "listener")
    #expect(model.stage == .chooseFolder)
    #expect(model.pendingServer == nil)
    #expect(!model.isSigningIn)
    #expect(fixture.loggedOut.isEmpty)
}

@Test @MainActor func restoreRequestsOTPWithoutDiscardingMatchingOfflineLibrary() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.host
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    var suppliedCodes: [String?] = []
    fixture.services.login = { url, _, _, otp in
        suppliedCodes.append(otp)
        guard otp == "123456" else { throw SynologyError.twoFactorRequired }
        return DSMSession(baseURL: url, sid: "reauthenticated", apis: [:])
    }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    #expect(model.needsOTP)
    #expect(model.pendingServer?.host == saved.host)
    #expect(fixture.library.catalogue.trackCount == catalogue.trackCount)
    await model.signIn(account: saved.account, password: "test", otpCode: "123456", remember: false)
    #expect(model.stage == .ready)
    #expect(model.isConnected)
    #expect(!model.needsOTP)
    #expect(fixture.library.catalogue.trackCount == catalogue.trackCount)
    #expect(suppliedCodes.count == 2)
}

@Test @MainActor func cancelledRestoreDoesNotReplaceSampleLibrary() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    try fixture.save(ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music"))
    let login = PendingLogin()
    fixture.services.login = login.login
    let model = fixture.model(restore: true)
    try await waitUntil { login.continuation != nil }
    model.useSampleLibrary()
    model.openLibrary()
    login.finish()
    try await waitUntil { !fixture.loggedOut.isEmpty }
    #expect(model.isDemo)
    #expect(model.connection == nil)
    #expect(model.stage == .ready)
    #expect(!model.isConnected)
}

@Test func catalogueRequiresBothServerAndFolder() {
    let connection = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    var catalogue = Catalogue.empty
    catalogue.driveID = "nas.example"
    catalogue.rootPath = "/music"
    #expect(catalogue.belongs(to: connection))
    catalogue.rootPath = "/other"
    #expect(!catalogue.belongs(to: connection))
    catalogue.rootPath = "/music"
    catalogue.driveID = "other.example"
    #expect(!catalogue.belongs(to: connection))
}

@Test @MainActor func restoreWithoutCacheShowsReauthenticationOnEveryPlatform() async throws {
    for needsOTP in [false, true] {
        let fixture = ConnectionFixture()
        defer { fixture.cleanUp() }
        try fixture.save(ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music"))
        fixture.services.password = { _ in needsOTP ? "test" : nil }
        fixture.services.login = { _, _, _, _ in throw SynologyError.twoFactorRequired }
        let model = fixture.model(restore: true)
        try await waitUntil { !model.isRestoring }
        #expect(model.stage == .discovering)
        #expect(model.pendingServer?.host == "nas.example")
        #expect(model.needsOTP == needsOTP)
        #expect(fixture.library.isEmpty)
    }
}

@Test @MainActor func changingTheFolderInvalidatesAnOutstandingReconnect() async throws {
    let fixture = ConnectionFixture()
    defer { fixture.cleanUp() }
    let saved = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
    try fixture.save(saved)
    var catalogue = SampleLibrary.catalogue
    catalogue.driveID = saved.host
    catalogue.rootPath = "/music"
    fixture.services.loadCatalogue = { catalogue }
    let pending = PendingLogin()
    var calls = 0
    fixture.services.login = { url, account, password, otp in
        calls += 1
        if calls == 1 { return DSMSession(baseURL: url, sid: "restored", apis: [:]) }
        return try await pending.login(url, account, password, otp)
    }
    let model = fixture.model(restore: true)
    try await waitUntil { !model.isRestoring }
    let task = Task { await model.reconnect() }
    try await waitUntil { pending.continuation != nil }
    fixture.library.drive = FakeDrive(tree: [:])
    model.chooseMusicFolder(path: "/new-music", showsProgress: false)
    model.indexer.cancel()
    pending.finish("late-reconnect")
    await task.value
    #expect(model.musicPath == "/new-music")
    #expect(fixture.library.drive?.id == "fake")
    #expect(fixture.loggedOut == ["late-reconnect"])
    let data = try #require(fixture.defaults.data(forKey: "connection"))
    #expect(try JSONDecoder().decode(ServerConnection.self, from: data).musicPath == "/new-music")
}
