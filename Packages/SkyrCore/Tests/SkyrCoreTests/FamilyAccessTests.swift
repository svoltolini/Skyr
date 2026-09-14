import CloudKit
import Foundation
import Testing
@testable import SkyrCore

@MainActor private final class FamilyFixture {
    let suite = "SkyrFamilyTests.\(UUID().uuidString)"
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-family-\(UUID().uuidString)")
    let defaults: UserDefaults
    var passwords: [String: String] = [:]
    var rotations = 0
    var deletes = 0
    var failRotation = false
    var failRemoval = false
    var failShare = false
    var omitAcknowledgement = false
    var shareUnknown = false
    var identity: String? = "account-A"
    var heldLogin: CheckedContinuation<Void, Never>?
    var suspendFamilyLogin = false
    var events: [String] = []
    var suspendRotation = false
    var heldRotation: CheckedContinuation<Void, Never>?
    var model: AppModel!
    var cloud: CloudSync!

    init() {
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(3, forKey: "coverCacheVersion")
        makeModel()
        cloud = CloudSync(services: CloudServices(
            identity: { self.identity }, sharedZones: { [] }, createZone: { _ in }, subscribe: {},
            changes: { _, token in CloudChangePage(records: [], token: token) },
            modify: { _, records, ids in
                guard !ids.isEmpty else { return .init(saved: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .success($0)) })) }
                self.events.append("share")
                if self.failShare { throw CKError(.networkUnavailable) }
                if self.omitAcknowledgement { return .init() }
                return .init(deleted: Dictionary(uniqueKeysWithValues: ids.map { ($0, self.shareUnknown ? .failure(CKError(.unknownItem)) : .success(())) }))
            }
        ), persistence: CloudPersistence(directory: directory))
    }

    func makeModel() {
        var services = ConnectionServices()
        services.login = { url, account, _, _ in
            if self.suspendFamilyLogin, account == "family-reader" {
                await withCheckedContinuation { self.heldLogin = $0 }
            }
            return DSMSession(baseURL: url, sid: "fixture", apis: [:], account: account)
        }
        services.info = { _ in nil }
        services.logout = { _ in }
        services.password = { self.passwords[$0] }
        services.savePassword = { self.passwords[$1] = $0 }
        services.deletePassword = { self.passwords.removeValue(forKey: $0) }
        services.loadCatalogue = { nil }
        services.deleteCatalogue = {}
        services.log = { _ in }
        services.canManageUsers = { _ in true }
        services.confirmPassword = { _, _ in "confirmation" }
        services.setFamilyPassword = { _, _, _, _ in
            self.events.append("rotate")
            self.rotations += 1
            if self.suspendRotation { await withCheckedContinuation { self.heldRotation = $0 } }
            if self.failRotation { throw URLError(.notConnectedToInternet) }
        }
        services.deleteFamilyUser = { _, _, _ in
            self.deletes += 1
            if self.failRemoval { throw URLError(.notConnectedToInternet) }
        }
        services.createFamilyUser = { _, _, _, _, _ in }
        model = AppModel(library: LibraryStore(), defaults: defaults, services: services, restoresSession: false)
    }

    func connect(_ address: String = "https://nas.example:5001", account: String = "owner") async {
        #expect(model.enterAddress(address))
        await model.signIn(account: account, password: "owner-fixture", otpCode: "", remember: true)
        #expect(model.isConnected)
    }

    func configureFamily() async {
        #expect(await model.useFamilyAccess(account: "family-reader", password: "family-fixture") == nil)
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test func nasIdentitySeparatesPortsAndAccountsAndCanonicalizesOrigins() {
    let a = ServerConnection(name: "NAS", baseURL: URL(string: "https://NAS.example:443")!, account: "reader", musicPath: "/music")
    var b = a
    b.baseURL = URL(string: "https://nas.example")!
    #expect(a.sourceID == b.sourceID)
    b.baseURL = URL(string: "https://nas.example:5001")!
    #expect(a.sourceID != b.sourceID)
    b = a
    b.account = "another-reader"
    #expect(a.sourceID != b.sourceID)
    var legacy = Catalogue.empty
    legacy.driveID = a.host
    legacy.rootPath = "/music"
    #expect(!legacy.belongs(to: a))
    legacy.driveID = a.sourceID
    #expect(legacy.belongs(to: a))
    #expect(!legacy.belongs(to: b))
}

@Test @MainActor func familyCredentialsStayBoundToOriginAndProvisioningAccountAcrossRelaunch() async throws {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    let original = try #require(f.model.familyAccess)
    await f.connect("https://nas.example:6001")
    #expect(f.model.familyAccess == nil)
    await f.connect(account: "different-owner")
    #expect(f.model.familyAccess == nil)
    f.makeModel()
    await f.connect()
    #expect(f.model.familyAccess == original)
}

@Test @MainActor func unscopedLegacyFamilyCredentialsAreNotAdopted() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    f.defaults.set("family-reader", forKey: "family.account")
    f.passwords["family|family-reader"] = "legacy-fixture"
    f.makeModel()
    await f.connect()
    #expect(f.model.familyAccess == nil)
}

@Test @MainActor func supersededFamilyVerificationCannotAttachToAnotherNAS() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    f.suspendFamilyLogin = true
    let task = Task { await f.model.useFamilyAccess(account: "family-reader", password: "family-fixture") }
    for _ in 0..<100 where f.heldLogin == nil { await Task.yield() }
    #expect(f.heldLogin != nil)
    await f.connect("https://other.example:5001")
    f.heldLogin?.resume()
    let result = await task.value
    #expect(result != nil)
    #expect(f.model.familyAccess == nil)
    f.suspendFamilyLogin = false
    await f.connect()
    #expect(f.model.familyAccess == nil)
}

@Test @MainActor func failedFamilyRemovalRetainsRecoveryDetails() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    f.failRemoval = true
    #expect(await f.model.removeFamilyAccess() != nil)
    #expect(f.model.familyAccess?.password == "family-fixture")
    f.failRemoval = false
    #expect(await f.model.removeFamilyAccess() == nil)
    #expect(f.model.familyAccess == nil)
    #expect(f.deletes == 2)
}

@Test @MainActor func failedOrUnacknowledgedShareRemovalNeverRotatesNASPassword() async {
    for omit in [false, true] {
        let f = FamilyFixture()
        defer { f.cleanUp() }
        await f.connect()
        await f.configureFamily()
        await f.cloud.refresh(reason: "fixture")
        f.failShare = !omit
        f.omitAcknowledgement = omit
        #expect(await f.model.stopFamilySharing(using: f.cloud) != nil)
        #expect(f.rotations == 0)
        #expect(f.model.familyAccess?.password == "family-fixture")
        #expect(f.model.familyRevocationPending)
    }
}

@Test @MainActor func partialRevocationSurvivesRelaunchAndRetriesAfterShareAlreadyRemoved() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    await f.cloud.refresh(reason: "fixture")
    f.failRotation = true
    #expect(await f.model.stopFamilySharing(using: f.cloud)?.contains("NAS access has not been revoked") == true)
    #expect(f.events == ["share", "rotate"])
    #expect(f.model.familyRevocationPending)
    f.makeModel()
    await f.connect()
    #expect(f.model.familyRevocationPending)
    f.failRotation = false
    f.shareUnknown = true
    #expect(await f.model.stopFamilySharing(using: f.cloud) == nil)
    #expect(!f.model.familyRevocationPending)
    #expect(f.model.familyAccess?.password != "family-fixture")
    #expect(f.events == ["share", "rotate", "share", "rotate"])
}

@Test @MainActor func revocationRetryDoesNotSwitchAppleAccountOrNAS() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    await f.cloud.refresh(reason: "fixture")
    f.failShare = true
    #expect(await f.model.stopFamilySharing(using: f.cloud) != nil)
    f.events = []
    f.failShare = false
    f.identity = "account-B"
    f.cloud.accountChanged()
    await f.cloud.refresh(reason: "new account")
    #expect(await f.model.stopFamilySharing(using: f.cloud) != nil)
    #expect(f.events.isEmpty)
    #expect(f.rotations == 0)
}

@Test @MainActor func missedAppleAccountChangeDoesNotDeleteTheNewAccountsShare() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    await f.cloud.refresh(reason: "A")
    f.identity = "account-B"
    #expect(await f.model.stopFamilySharing(using: f.cloud) != nil)
    #expect(f.events.isEmpty)
    #expect(f.rotations == 0)
    #expect(f.model.familyRevocationPending)
}

@Test @MainActor func accountChangeDuringNASRotationRetainsOriginalRecoveryAndDoesNotPublish() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    await f.cloud.refresh(reason: "A")
    var publications = 0
    f.model.onFamilyAccessChanged = { publications += 1 }
    f.suspendRotation = true
    let task = Task { await f.model.stopFamilySharing(using: f.cloud) }
    for _ in 0..<200 where f.heldRotation == nil { await Task.yield() }
    #expect(f.heldRotation != nil)
    f.identity = "account-B"
    f.cloud.accountChanged()
    await f.cloud.refresh(reason: "B")
    f.heldRotation?.resume()
    #expect(await task.value != nil)
    #expect(publications == 0)
    #expect(f.model.familyRevocationPending)
    #expect(f.model.familyAccess?.password == "family-fixture")
}

@Test @MainActor func missingOrLegacyFamilySecretNeverReportsNASRevocationComplete() async {
    for legacy in [false, true] {
        let f = FamilyFixture()
        defer { f.cleanUp() }
        await f.connect()
        if legacy { f.defaults.set("old-reader", forKey: "family.account") }
        else {
            await f.configureFamily()
            for key in Array(f.passwords.keys) where key.hasPrefix("family-v2|") { f.passwords.removeValue(forKey: key) }
        }
        await f.cloud.refresh(reason: "A")
        #expect(await f.model.stopFamilySharing(using: f.cloud) != nil)
        #expect(f.rotations == 0)
    }
}

@Test @MainActor func profileLockDuringFamilyVerificationCannotPublishCredentials() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    let profiles = ProfileStore(directory: f.directory.appending(path: "profiles"), defaults: f.defaults)
    profiles.openAutomaticallyIfPossible()
    #expect(profiles.sessionID != nil)
    f.model.profiles = profiles
    await f.connect()
    f.suspendFamilyLogin = true
    let task = Task { await f.model.useFamilyAccess(account: "family-reader", password: "family-fixture") }
    for _ in 0..<200 where f.heldLogin == nil { await Task.yield() }
    #expect(f.heldLogin != nil)
    profiles.lock()
    f.heldLogin?.resume()
    #expect(await task.value != nil)
    #expect(f.model.familyAccess == nil)
}

@Test @MainActor func pendingRevocationKeepsItsOriginalNASAccountUntilCompleted() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    await f.cloud.refresh(reason: "fixture")
    f.failShare = true
    #expect(await f.model.stopFamilySharing(using: f.cloud) != nil)
    #expect(await f.model.setUpFamilyAccess() != nil)
    #expect(await f.model.removeFamilyAccess() != nil)
    #expect(await f.model.useFamilyAccess(account: "replacement-reader", password: "fixture") != nil)
    #expect(f.model.familyAccess?.account == "family-reader")
    #expect(f.deletes == 0)
    #expect(await f.model.useFamilyAccess(account: "family-reader", password: "reverified-fixture") == nil)
    #expect(f.model.familyAccess?.password == "reverified-fixture")
    #expect(f.model.familyRevocationPending)
}

@Test @MainActor func overlappingFamilyChangesCannotReplaceTheRevocationTarget() async {
    let f = FamilyFixture()
    defer { f.cleanUp() }
    await f.connect()
    await f.configureFamily()
    await f.cloud.refresh(reason: "fixture")
    f.suspendFamilyLogin = true
    let task = Task { await f.model.useFamilyAccess(account: "family-reader", password: "verified-fixture") }
    for _ in 0..<200 where f.heldLogin == nil { await Task.yield() }
    #expect(f.heldLogin != nil)
    #expect(await f.model.stopFamilySharing(using: f.cloud) != nil)
    #expect(await f.model.rotateFamilyAccess() != nil)
    #expect(f.events.isEmpty)
    f.heldLogin?.resume()
    #expect(await task.value == nil)
    #expect(!f.model.isChangingFamilyAccess)
    #expect(f.model.familyAccess?.password == "verified-fixture")
}
