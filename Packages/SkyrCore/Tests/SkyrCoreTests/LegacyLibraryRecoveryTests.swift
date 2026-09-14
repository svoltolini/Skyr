import Foundation
import Testing
@testable import SkyrCore

@MainActor
private final class LegacyRecoveryFixture {
    let suite = "SkyrLegacyRecovery.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appending(path: "SkyrLegacyRecovery-\(UUID().uuidString)")
    let defaults: UserDefaults
    let profiles: ProfileStore
    let library = LibraryStore()
    var model: AppModel!
    var passwords: [String: String] = [:]
    var loginCalls = 0

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(3, forKey: "coverCacheVersion")
        profiles = ProfileStore(directory: directory, defaults: defaults)
        let profile = try #require(profiles.owner)
        #expect(profiles.activate(profile))
        library.profiles = profiles
        makeModel()
    }

    func makeModel(restore: Bool = false) {
        var services = ConnectionServices()
        services.login = { url, account, _, _ in
            self.loginCalls += 1
            return DSMSession(baseURL: url, sid: "ordinary-test-session", apis: [:], account: account)
        }
        services.info = { _ in nil }
        services.logout = { _ in }
        services.password = { self.passwords[$0] }
        services.savePassword = { self.passwords[$1] = $0 }
        services.deletePassword = { self.passwords[$0] = nil }
        services.loadCatalogue = { nil }
        services.deleteCatalogue = {}
        services.log = { _ in }
        model = AppModel(library: library, defaults: defaults, services: services, restoresSession: restore)
        model.profiles = profiles
    }

    func connect(_ address: String = "https://nas.example:5001", account: String = "listener") async throws {
        #expect(model.enterAddress(address))
        await model.signIn(account: account, password: "ordinary-test-password", otpCode: "", remember: false)
        let connection = try #require(model.connection)
        let session = DSMSession(baseURL: connection.baseURL, sid: "ordinary-test-session", apis: [:], account: account)
        let catalogue = Catalogue(serverName: "NAS", albums: [], indexedAt: .now, rootPath: "/music", driveID: connection.sourceID)
        library.replace(with: catalogue, drive: SynologyDrive(session: session, displayName: "NAS"))
        model.stage = .ready
    }

    func cleanUp() {
        profiles.lock()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Suite("Legacy library recovery") @MainActor
struct LegacyLibraryRecoveryTests {
    @Test func legacySourceDetectionExcludesSamplesAndNewSourceIDs() {
        for host in ["nas.example", "DiskStation.local", "192.168.1.40", "fd00::1", "[fd00::1]"] {
            #expect(LegacyLibraryRecovery.isLegacySourceID(host))
        }
        for value in ["", "https://nas.example", "nas.example:5001", "192.168.1.40:5000", "nas.example/music", NASSource.identifier(baseURL: URL(string: "https://nas.example:5001")!, account: "listener")] {
            #expect(!LegacyLibraryRecovery.isLegacySourceID(value))
        }
    }

    @Test func verifiedConnectionOffersRecoveryWithoutAutomaticallyAdoptingAnotherSource() async throws {
        let fixture = try LegacyRecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.profiles.updateLibrary("old-nas.local") { $0.favourites = ["old-song"] }
        #expect(fixture.model.legacyLibraryRecoveries.isEmpty)
        try await fixture.connect()
        let source = try #require(fixture.model.connection?.sourceID)
        fixture.profiles.updateLibrary(source) { $0.favourites = ["new-song"] }
        let choice = try #require(fixture.model.legacyLibraryRecoveries.first)
        #expect(choice.legacySourceID == "old-nas.local")
        #expect(choice.address == "https://nas.example:5001")
        #expect(choice.account == "listener")
        #expect(fixture.profiles.libraryState(for: source).favourites == ["new-song"])
        #expect(fixture.library.catalogue.driveID == source)

        #expect(fixture.model.recoverLegacyLibrary(choice) == nil)
        #expect(Set(fixture.profiles.libraryState(for: source).favourites) == ["new-song", "old-song"])
        #expect(fixture.profiles.libraryState(for: "old-nas.local").favourites == ["old-song"])
        #expect(fixture.model.legacyLibraryRecoveries.isEmpty)
        #expect(fixture.library.catalogue.driveID == source)
        #expect(fixture.passwords.isEmpty)
    }

    @Test func recoveryConfirmationCannotFollowAProfileOrPortChange() async throws {
        let fixture = try LegacyRecoveryFixture()
        defer { fixture.cleanUp() }
        fixture.profiles.updateLibrary("nas.example") { $0.favourites = ["old-song"] }
        try await fixture.connect()
        let oldChoice = try #require(fixture.model.legacyLibraryRecoveries.first)
        try await fixture.connect("https://nas.example:8443")
        #expect(fixture.model.recoverLegacyLibrary(oldChoice) != nil)
        let source = try #require(fixture.model.connection?.sourceID)
        #expect(fixture.profiles.libraryState(for: source).favourites.isEmpty)
        let newChoice = try #require(fixture.model.legacyLibraryRecoveries.first)
        let profile = try #require(fixture.profiles.active)
        fixture.profiles.lock()
        #expect(fixture.profiles.activate(profile))
        #expect(fixture.model.recoverLegacyLibrary(newChoice) != nil)
        #expect(fixture.profiles.libraryState(for: source).favourites.isEmpty)
        #expect(fixture.profiles.libraryState(for: "nas.example").favourites == ["old-song"])
    }

    @Test func hostnameOnlyPasswordRequiresFreshSignInAndIsNeverSentOrPromoted() throws {
        let fixture = try LegacyRecoveryFixture()
        defer { fixture.cleanUp() }
        let connection = ServerConnection(name: "NAS", baseURL: URL(string: "https://nas.example:5001")!, account: "listener", musicPath: "/music")
        fixture.passwords["nas.example|listener"] = "old-unscoped-value"
        fixture.defaults.set(try JSONEncoder().encode(connection), forKey: "connection")
        fixture.makeModel(restore: true)
        #expect(fixture.loginCalls == 0)
        #expect(!fixture.model.isConnected)
        #expect(fixture.model.pendingServer?.baseURL == connection.baseURL)
        #expect(fixture.model.signInError?.contains("Confirm your password once") == true)
        #expect(fixture.passwords[connection.keychainAccount] == nil)
        #expect(fixture.passwords["nas.example|listener"] == "old-unscoped-value")
    }
}
