import CloudKit
import Foundation
import Testing
@testable import SkyrCore

@MainActor
private final class CloudFixture {
    let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-cloud-\(UUID().uuidString)")
    let suite = "skyr.cloud.tests.\(UUID().uuidString)"
    let defaults: UserDefaults
    var profiles: ProfileStore
    let persistence: CloudPersistence
    var account: String? = "A"
    var owners: [String] = []
    var pages: [CloudChangePage] = []
    var requests: [(CloudScope, Data?)] = []
    var modifications: [(CloudScope, [String], [String])] = []
    var subscriptions = 0
    var failZoneDiscovery = false
    var pageError: CKError?
    var deletionResults: [String: Result<Void, any Error>] = [:]
    var holdPage: CheckedContinuation<CloudChangePage, any Error>?
    var didRequestHeldPage: CheckedContinuation<Void, Never>?
    var shouldHoldPage = false
    var shouldHoldSave = false
    var heldSave: CheckedContinuation<CloudModifyResult, any Error>?
    var heldSaveResult: CloudModifyResult?
    var didRequestHeldSave: CheckedContinuation<Void, Never>?
    var sync: CloudSync!

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults)
        persistence = CloudPersistence(directory: directory.appending(path: "cloud"))
        sync = makeSync()
        sync.profiles = profiles
        profiles.sync = sync
    }

    func makeSync() -> CloudSync {
        CloudSync(services: CloudServices(
            identity: { self.account },
            sharedZones: {
                if self.failZoneDiscovery { throw CKError(.networkUnavailable) }
                return self.owners
            },
            createZone: { _ in },
            subscribe: { self.subscriptions += 1 },
            changes: { scope, token in
                self.requests.append((scope, token))
                if let error = self.pageError { throw error }
                if self.shouldHoldPage {
                    return try await withCheckedThrowingContinuation { continuation in
                        self.holdPage = continuation
                        self.didRequestHeldPage?.resume()
                        self.didRequestHeldPage = nil
                    }
                }
                return self.pages.isEmpty ? CloudChangePage(records: [], token: token) : self.pages.removeFirst()
            },
            modify: { scope, records, ids in
                self.modifications.append((scope, records.map(\.recordID.recordName), ids.map(\.recordName)))
                let result = CloudModifyResult(saved: Dictionary(uniqueKeysWithValues: records.map { ($0.recordID, .success($0)) }),
                                               deleted: Dictionary(uniqueKeysWithValues: ids.map { ($0, self.deletionResults[$0.recordName] ?? .success(())) }))
                if self.shouldHoldSave, !records.isEmpty {
                    return try await withCheckedThrowingContinuation { continuation in
                        self.heldSave = continuation
                        self.heldSaveResult = result
                        self.didRequestHeldSave?.resume()
                        self.didRequestHeldSave = nil
                    }
                }
                return result
            }
        ), persistence: persistence)
    }

    func relaunch(restoreProfiles: Bool = false) {
        if restoreProfiles {
            profiles.sync = nil
            profiles.lock()
            profiles = ProfileStore(directory: directory.appending(path: "profiles"), defaults: defaults)
        }
        sync = makeSync()
        sync.profiles = profiles
        profiles.sync = sync
    }

    func ownerAndMember() throws -> (Profile, Profile) {
        let owner = try #require(profiles.owner)
        #expect(profiles.activate(owner))
        let member = try #require(profiles.create(name: "Member", avatar: .random(), pin: nil))
        return (owner, member)
    }

    func profileRecord(_ id: String, name: String = "Remote", owner: String = CKCurrentUserDefaultName) -> CKRecord {
        let record = CKRecord(recordType: "Profile", recordID: .init(recordName: id, zoneID: .init(zoneName: "Family", ownerName: owner)))
        record["name"] = name
        record["createdAt"] = Date(timeIntervalSince1970: 10)
        record["updatedAt"] = Date(timeIntervalSince1970: 20)
        return record
    }

    func cleanUp() {
        profiles.sync = nil
        profiles.onDeactivate = nil
        profiles.lock()
        sync.accountChanged()
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}

@Test @MainActor func cloudAccountSnapshotsSeparateOwnerMemberCursorsAndSubscriptionsAcrossRelaunch() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.sync.profiles = nil
    fixture.owners = ["family-A"]
    let family = CKRecord(recordType: "Family", recordID: .init(recordName: "family", zoneID: .init(zoneName: "Family", ownerName: "family-A")))
    family["name"] = "Family A"
    family["updatedAt"] = Date(timeIntervalSince1970: 20)
    fixture.pages = [.init(records: [.success(family)], token: Data("cursor-A".utf8))]
    await fixture.sync.refresh(reason: "A")
    #expect(fixture.sync.currentUserRecordName == "A")
    #expect(fixture.sync.membership == .member)
    #expect(fixture.subscriptions == 1)

    fixture.account = nil
    fixture.sync.accountChanged()
    await fixture.sync.refresh(reason: "signed out")
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.sync.status == .noAccount)

    fixture.account = "B"
    fixture.owners = []
    fixture.pages = [.init(records: [], token: Data("cursor-B".utf8))]
    await fixture.sync.refresh(reason: "B")
    #expect(fixture.sync.membership == .owner)
    #expect(fixture.subscriptions == 2)
    #expect(fixture.requests.last?.0.account == "B")
    #expect(fixture.requests.last?.1 == nil)
    let stateB = try fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName)
    #expect(stateB.zones[CKCurrentUserDefaultName]?.changeToken == Data("cursor-B".utf8))
    #expect(stateB.zones["family-A"] == nil)
    #expect(stateB.zones[CKCurrentUserDefaultName]?.systemFields.isEmpty == true)
    #expect(stateB.zones[CKCurrentUserDefaultName]?.remoteStamps.isEmpty == true)

    fixture.account = "A"
    fixture.relaunch()
    fixture.sync.profiles = nil
    await fixture.sync.refresh(reason: "A relaunched")
    #expect(fixture.sync.membership == .member)
    #expect(fixture.requests.last?.1 == Data("cursor-A".utf8))
    #expect(fixture.subscriptions == 2)
    let stateA = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(stateA.zones["family-A"]?.systemFields["family"] != nil)
    #expect(stateA.zones["family-A"]?.remoteStamps["family"] == Date(timeIntervalSince1970: 20))
}

@Test @MainActor func cloudDirectAccountChangeDoesNotUploadOrRebindAnotherAccountsProfiles() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    await fixture.sync.refresh(reason: "A")
    #expect(fixture.profiles.active?.userRecordName == "A")
    fixture.modifications = []
    fixture.account = "B" // Deliberately no notification: identity refresh must catch this too.
    await fixture.sync.refresh(reason: "B")
    #expect(fixture.sync.currentUserRecordName == "B")
    #expect(fixture.profiles.isLocked)
    #expect(fixture.modifications.allSatisfy { $0.1.isEmpty })
    #expect(fixture.profiles.profiles.first { $0.id == owner.id }?.userRecordName == "A")
    #expect(try fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.isEmpty)
}

@Test @MainActor func cloudAccountChangeDiscardsASuspendedPageBeforeAnyApplication() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.shouldHoldPage = true
    let started = Task { await fixture.sync.refresh(reason: "old account") }
    await withCheckedContinuation { continuation in
        if fixture.holdPage != nil { continuation.resume() }
        else { fixture.didRequestHeldPage = continuation }
    }
    let record = fixture.profileRecord("old-account-profile")
    fixture.sync.accountChanged()
    fixture.account = "B"
    fixture.shouldHoldPage = false
    fixture.holdPage?.resume(returning: .init(records: [.success(record)], token: Data("stale".utf8)))
    fixture.holdPage = nil
    await started.value
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != "old-account-profile" })
    #expect(fixture.sync.currentUserRecordName == nil)
    await fixture.sync.refresh(reason: "new account")
    #expect(fixture.sync.currentUserRecordName == "B")
    #expect(fixture.requests.last?.1 == nil)
}

@Test @MainActor func cloudOfflineDeletionIsDurableBeforeLocalRemovalAndRetriesBothRecordsAfterRelaunch() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline")
    #expect(!fixture.sync.isActive)
    #expect(fixture.profiles.delete(member))
    #expect(fixture.sync.pendingDeletionCount == 1)
    let snapshot = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(snapshot.zones[CKCurrentUserDefaultName]?.deletions[member.id] == [member.id, "state-\(member.id)"])
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })

    fixture.relaunch(restoreProfiles: true)
    fixture.failZoneDiscovery = false
    await fixture.sync.refresh(reason: "retry")
    #expect(fixture.modifications.contains { Set($0.2) == [member.id, "state-\(member.id)"] })
    #expect(fixture.sync.pendingDeletionCount == 0)
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[member.id] == [])
}

@Test @MainActor func cloudPartialDeletionKeepsOnlyUnacknowledgedWorkAndSuppressesReturnedRecords() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline")
    #expect(fixture.profiles.delete(member))
    fixture.failZoneDiscovery = false
    fixture.deletionResults["state-\(member.id)"] = .failure(CKError(.networkFailure))
    await fixture.sync.refresh(reason: "partial")
    #expect(fixture.sync.pendingDeletionCount == 1)
    var snapshot = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(snapshot.zones[CKCurrentUserDefaultName]?.deletions[member.id] == ["state-\(member.id)"])
    fixture.relaunch()
    fixture.deletionResults = [:]
    fixture.pages = [.init(records: [.success(fixture.profileRecord(member.id))], token: Data("replayed".utf8))]
    await fixture.sync.refresh(reason: "eventual retry")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    snapshot = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(snapshot.zones[CKCurrentUserDefaultName]?.deletions[member.id] == [])
    #expect(fixture.sync.pendingDeletionCount == 0)
}

@Test @MainActor func cloudDeletionIsRefusedWhenItsIntentCannotBeSaved() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline")
    let cloudDirectory = fixture.persistence.directory
    try FileManager.default.removeItem(at: cloudDirectory)
    try Data("storage unavailable".utf8).write(to: cloudDirectory)
    #expect(!fixture.profiles.delete(member))
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
    #expect(fixture.sync.pendingDeletionCount == 0)
}

@Test @MainActor func cloudMixedPageKeepsItsOldCursorAndRetriesWithoutANewServerMutation() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, removed) = try fixture.ownerAndMember()
    fixture.pages = [.init(records: [], token: Data("before".utf8))]
    await fixture.sync.refresh(reason: "baseline")
    let first = fixture.profileRecord("first")
    let second = fixture.profileRecord("second")
    let deletion = CloudChangePage.Deletion(id: .init(recordName: removed.id, zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)), type: "Profile")
    fixture.pages = [.init(records: [.success(first), .failure(CKError(.networkFailure))], deletions: [deletion], token: Data("after".utf8), moreComing: true)]
    let requestCount = fixture.requests.count
    await fixture.sync.refresh(reason: "mixed page")
    #expect(fixture.requests.count == requestCount + 1) // Does not request moreComing after a failed entry.
    #expect(fixture.profiles.profiles.contains { $0.id == "first" })
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != removed.id })
    #expect(!fixture.sync.isActive)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == Data("before".utf8))
    fixture.relaunch()
    fixture.pages = [
        .init(records: [.success(first), .success(second)], deletions: [deletion], token: Data("after".utf8), moreComing: true),
        .init(records: [], token: Data("end".utf8))
    ]
    await fixture.sync.refresh(reason: "same changes replayed")
    #expect(fixture.requests[fixture.requests.count - 2].1 == Data("before".utf8))
    #expect(fixture.profiles.profiles.filter { $0.id == "first" }.count == 1)
    #expect(fixture.profiles.profiles.contains { $0.id == "second" })
    #expect(fixture.sync.isActive)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == Data("end".utf8))
}

@Test @MainActor func cloudApplicationFailuresDoNotAcknowledgeAPage() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let invalid = CKRecord(recordType: "Profile", recordID: .init(recordName: "incomplete", zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)))
    fixture.pages = [.init(records: [.success(invalid)], token: Data("must-not-ack".utf8))]
    await fixture.sync.refresh(reason: "incomplete record")
    #expect(!fixture.sync.isActive)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == nil)
    let profileURL = fixture.directory.appending(path: "profiles/profiles.json")
    try FileManager.default.removeItem(at: profileURL)
    try FileManager.default.createDirectory(at: profileURL, withIntermediateDirectories: true)
    fixture.pages = [.init(records: [.success(fixture.profileRecord("valid"))], token: Data("also-not-ack".utf8))]
    await fixture.sync.refresh(reason: "local write failed")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != "valid" })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == nil)
    try FileManager.default.removeItem(at: profileURL)
    fixture.pages = [.init(records: [.success(fixture.profileRecord("valid"))], token: Data("saved".utf8))]
    await fixture.sync.refresh(reason: "storage recovered")
    #expect(fixture.profiles.profiles.contains { $0.id == "valid" })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.changeToken == Data("saved".utf8))
}

@Test @MainActor func cloudOfflineRelaunchCanQueueDeletionWithoutAssumingASignedInIdentity() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (owner, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "first verified account, offline sync")
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.profiles.activate(owner))
    #expect(fixture.profiles.delete(member))
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[member.id] == [member.id, "state-\(member.id)"])
    fixture.account = "B"
    fixture.failZoneDiscovery = false
    await fixture.sync.refresh(reason: "different account")
    #expect(fixture.modifications.allSatisfy { $0.2.isEmpty })
    fixture.account = "A"
    await fixture.sync.refresh(reason: "original account returns")
    #expect(fixture.modifications.contains { $0.0.account == "A" && Set($0.2) == [member.id, "state-\(member.id)"] })
}

@Test @MainActor func cloudUnverifiedDeletionRefusesAmbiguousAccountOwnership() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (owner, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "initial account")
    var other = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    other.account = "B"
    try fixture.persistence.save(other)
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.activate(owner))
    #expect(!fixture.profiles.delete(member))
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
}

@Test @MainActor func cloudUnassociatedLocalProfilesCanStillBeDeletedWithoutICloud() throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.profiles.delete(member))
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(!FileManager.default.fileExists(atPath: fixture.persistence.directory.path))
}

@Test @MainActor func cloudAccountChangeDiscardsASuspendedSaveAndItsSystemFields() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.shouldHoldSave = true
    let started = Task { await fixture.sync.refresh(reason: "A upload") }
    await withCheckedContinuation { continuation in
        if fixture.heldSave != nil { continuation.resume() }
        else { fixture.didRequestHeldSave = continuation }
    }
    fixture.sync.accountChanged()
    fixture.account = "B"
    fixture.shouldHoldSave = false
    fixture.heldSave?.resume(returning: try #require(fixture.heldSaveResult))
    fixture.heldSave = nil
    await started.value
    let old = try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName)
    #expect(old.zones[CKCurrentUserDefaultName]?.systemFields.isEmpty == true)
    #expect(old.zones[CKCurrentUserDefaultName]?.remoteStamps.isEmpty == true)
    await fixture.sync.refresh(reason: "B after old upload")
    let current = try fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName)
    #expect(current.zones[CKCurrentUserDefaultName]?.systemFields.isEmpty == true)
    #expect(current.zones[CKCurrentUserDefaultName]?.remoteStamps.isEmpty == true)
}

@Test @MainActor func cloudRemoteLastProfileDeletionCreatesADifferentUsableProfileOnlyAfterAPullCompletes() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let old = try #require(fixture.profiles.owner)
    let deletion = CloudChangePage.Deletion(id: .init(recordName: old.id, zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)), type: "Profile")
    fixture.pages = [.init(records: [], deletions: [deletion], token: Data("deleted".utf8))]
    await fixture.sync.refresh(reason: "removed elsewhere")
    #expect(fixture.profiles.profiles.count == 1)
    #expect(fixture.profiles.active?.id != old.id)
    #expect(!fixture.profiles.isLocked)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[old.id] == [])
}

@Test @MainActor func cloudProfileCreatedAfterOfflineRelaunchRetainsItsAccountAndUploadsThenDeletes() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    await fixture.sync.refresh(reason: "verified account")
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.activate(owner))
    let created = try #require(fixture.profiles.create(name: "Offline member", avatar: .random(), pin: nil))
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(created.id))
    fixture.relaunch(restoreProfiles: true)
    fixture.modifications = []
    await fixture.sync.refresh(reason: "reconnected")
    #expect(fixture.modifications.contains { $0.0.account == "A" && $0.1.contains(created.id) })
    #expect(fixture.profiles.profiles.contains { $0.id == created.id }) // Survives stand-in cleanup.
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "offline again")
    #expect(fixture.profiles.activate(owner))
    #expect(fixture.profiles.delete(created))
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).zones[CKCurrentUserDefaultName]?.deletions[created.id] == [created.id, "state-\(created.id)"])
}

@Test @MainActor func cloudLocalFirstLaunchProfilesAreAdoptedAndIntentionalMembersSurviveCleanup() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    #expect(!FileManager.default.fileExists(atPath: fixture.persistence.directory.path))
    await fixture.sync.refresh(reason: "first account")
    await fixture.sync.refresh(reason: "subsequent cleanup")
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(member.id))
    #expect(fixture.modifications.contains { $0.1.contains(member.id) })
}

@Test @MainActor func cloudOfflineCreationRefusesAnUnwritableAssociationBeforeAddingAProfile() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "known account")
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.activate(owner))
    try FileManager.default.removeItem(at: fixture.persistence.directory)
    try Data("unavailable".utf8).write(to: fixture.persistence.directory)
    #expect(fixture.profiles.create(name: "Cannot save", avatar: .random(), pin: nil) == nil)
    #expect(fixture.profiles.profiles.count == 1)
}

@Test @MainActor func cloudJoiningAnotherAccountsFamilyDoesNotChangeTheFirstAccountsRolesOrRevisions() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let owner = try #require(fixture.profiles.owner)
    #expect(fixture.profiles.activate(owner))
    await fixture.sync.refresh(reason: "A owner")
    let original = try #require(fixture.profiles.profiles.first { $0.id == owner.id })
    fixture.account = "B"
    fixture.owners = ["B-shared-family"]
    await fixture.sync.refresh(reason: "B joins shared family")
    #expect(fixture.sync.membership == .member)
    #expect(fixture.profiles.profiles.first { $0.id == original.id } == original)
    fixture.account = "A"
    fixture.owners = []
    await fixture.sync.refresh(reason: "A returns")
    #expect(fixture.sync.membership == .owner)
    #expect(fixture.profiles.profiles.first { $0.id == original.id } == original)
}

@Test @MainActor func cloudDurableTombstonesReconcileLocalFailuresAndAlreadyAcknowledgedDeletionAfterRelaunch() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "known account")
    let url = fixture.directory.appending(path: "profiles/profiles.json")
    let before = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    #expect(!fixture.profiles.delete(member))
    #expect(fixture.sync.pendingDeletionCount == 1)
    #expect(fixture.profiles.profiles.contains { $0.id == member.id })
    try FileManager.default.removeItem(at: url)
    try before.write(to: url, options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    fixture.failZoneDiscovery = false
    fixture.deletionResults[member.id] = .failure(CKError(.unknownItem))
    fixture.deletionResults["state-\(member.id)"] = .failure(CKError(.unknownItem))
    await fixture.sync.refresh(reason: "resume intent")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(fixture.sync.pendingDeletionCount == 0)
    // A saved local list from before the deletion must converge even after both remote acknowledgements.
    try before.write(to: url, options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    fixture.modifications = []
    await fixture.sync.refresh(reason: "acknowledged deletion, stale local list")
    #expect(fixture.profiles.profiles.allSatisfy { $0.id != member.id })
    #expect(fixture.modifications.allSatisfy { $0.2.isEmpty })
}

@Test @MainActor func cloudLastProfileRecoverySurvivesAnIncompletePageAndRelaunchWithoutLegacyData() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let old = try #require(fixture.profiles.owner)
    fixture.defaults.set(["old-legacy-song"], forKey: "favourites.legacy-drive")
    let deletion = CloudChangePage.Deletion(id: .init(recordName: old.id, zoneID: .init(zoneName: "Family", ownerName: CKCurrentUserDefaultName)), type: "Profile")
    fixture.pages = [.init(records: [.failure(CKError(.networkFailure))], deletions: [deletion], token: Data("not-acknowledged".utf8), moreComing: true)]
    await fixture.sync.refresh(reason: "incomplete deletion page")
    let replacement = try #require(fixture.profiles.owner)
    #expect(replacement.id != old.id)
    #expect(replacement.localOrigin == .recovery(account: "A"))
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.owner?.id == replacement.id)
    #expect(fixture.profiles.storedState(id: replacement.id).libraries.isEmpty)
    fixture.failZoneDiscovery = true
    await fixture.sync.refresh(reason: "identity verified, still offline")
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    fixture.account = "B"
    fixture.failZoneDiscovery = false
    await fixture.sync.refresh(reason: "another account")
    #expect(try !fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
}

@Test @MainActor func cloudInitializedEmptyProfileFileDoesNotRunLegacyMigrationAgain() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.defaults.set(["old-legacy-song"], forKey: "favourites.legacy-drive")
    try Data("[]".utf8).write(to: fixture.directory.appending(path: "profiles/profiles.json"), options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    #expect(replacement.localOrigin == .recovery(account: nil))
    #expect(fixture.profiles.storedState(id: replacement.id).libraries.isEmpty)
    await fixture.sync.refresh(reason: "verify recovery account")
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
}

@Test @MainActor func cloudMissingSharedZoneExposesInvitationRecoveryWithoutChangingMembership() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    fixture.owners = ["shared-family"]
    fixture.pageError = CKError(.zoneNotFound)
    await fixture.sync.refresh(reason: "missing family")
    #expect(fixture.sync.needsFamilyInvitation)
    #expect(!fixture.sync.isActive)
    #expect(fixture.sync.membership == .member)
    fixture.pageError = nil
    await fixture.sync.refresh(reason: "family restored")
    #expect(!fixture.sync.needsFamilyInvitation)
    #expect(fixture.sync.membership == .member)
}

@Test @MainActor func cloudMemberLastProfileRecoveryRetainsTheMemberRole() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let old = try #require(fixture.profiles.owner)
    fixture.owners = ["shared-family"]
    let deletion = CloudChangePage.Deletion(id: .init(recordName: old.id, zoneID: .init(zoneName: "Family", ownerName: "shared-family")), type: "Profile")
    fixture.pages = [.init(records: [], deletions: [deletion], token: Data("member-deleted".utf8))]
    await fixture.sync.refresh(reason: "member recovery")
    let replacement = try #require(fixture.profiles.profiles.first)
    #expect(replacement.id != old.id)
    #expect(replacement.role == .member)
    #expect(!fixture.profiles.canManageProfiles)
}

@Test @MainActor func cloudProfileRoundTripPreservesLocalOriginAndProtectsImportedRealProfiles() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let (_, member) = try fixture.ownerAndMember()
    await fixture.sync.refresh(reason: "initial upload")
    fixture.relaunch(restoreProfiles: true)
    let returned = fixture.profileRecord(member.id, name: member.name)
    returned["createdAt"] = member.createdAt
    returned["updatedAt"] = member.updatedAt.addingTimeInterval(0.1)
    let imported = fixture.profileRecord("real-member-from-another-device")
    imported["createdAt"] = Date(timeIntervalSince1970: 20)
    fixture.pages = [.init(records: [.success(returned), .success(imported)], token: Data("round-trip".utf8))]
    await fixture.sync.refresh(reason: "ordinary newer server copies")
    #expect(fixture.profiles.profiles.first { $0.id == member.id }?.localOrigin == .created)
    #expect(fixture.profiles.profiles.first { $0.id == imported.recordID.recordName }?.localOrigin == .created)
    #expect(fixture.sync.pendingDeletionCount == 0)
}

@Test @MainActor func cloudInitiallyUnassignedRecoveryBindsOnceAndCannotUploadAnotherAccountsEdits() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    try Data("[]".utf8).write(to: fixture.directory.appending(path: "profiles/profiles.json"), options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    #expect(replacement.localOrigin == .recovery(account: nil))
    await fixture.sync.refresh(reason: "A adopts the fresh recovery")
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
    #expect(fixture.profiles.activate(replacement))
    fixture.profiles.updateLibrary("A-library") { $0.favourites = ["A-song"] }
    fixture.profiles.flushSave()
    fixture.sync.accountChanged() // End the old process's queued work before the relaunch fixture.
    fixture.relaunch(restoreProfiles: true)
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
    fixture.account = "B"
    fixture.modifications = []
    await fixture.sync.refresh(reason: "B must not adopt A's recovery")
    #expect(try !fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    #expect(fixture.modifications.allSatisfy { !$0.1.contains(replacement.id) && !$0.1.contains("state-\(replacement.id)") })
    #expect(fixture.profiles.storedState(id: replacement.id).libraries["A-library"]?.favourites == ["A-song"])
}

@Test @MainActor func cloudRecoveryAssociationWaitsForItsLocalAccountBindingToPersist() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    let url = fixture.directory.appending(path: "profiles/profiles.json")
    try Data("[]".utf8).write(to: url, options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    let before = try Data(contentsOf: url)
    try FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    await fixture.sync.refresh(reason: "local recovery binding cannot persist")
    #expect(fixture.sync.currentUserRecordName == nil)
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: nil))
    #expect(try !fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    #expect(fixture.modifications.isEmpty)
    try FileManager.default.removeItem(at: url)
    try before.write(to: url, options: .atomic)
    await fixture.sync.refresh(reason: "binding storage recovered")
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
    #expect(try fixture.persistence.load(account: "A", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
}

@Test @MainActor func cloudExistingRecoveryAssociationPreventsAdoptionByAnotherAccountWhileStillUnbound() async throws {
    let fixture = try CloudFixture()
    defer { fixture.cleanUp() }
    try Data("[]".utf8).write(to: fixture.directory.appending(path: "profiles/profiles.json"), options: .atomic)
    fixture.relaunch(restoreProfiles: true)
    let replacement = try #require(fixture.profiles.owner)
    var prior = CloudAccountState(account: "A", zoneOwner: CKCurrentUserDefaultName)
    prior.profileIDs.insert(replacement.id)
    try fixture.persistence.save(prior)
    fixture.account = "B"
    await fixture.sync.refresh(reason: "existing association belongs to A")
    #expect(try !fixture.persistence.load(account: "B", defaultOwner: CKCurrentUserDefaultName).profileIDs.contains(replacement.id))
    #expect(fixture.modifications.isEmpty)
    fixture.account = "A"
    await fixture.sync.refresh(reason: "A completes the durable local binding")
    #expect(fixture.profiles.owner?.localOrigin == .recovery(account: "A"))
}
