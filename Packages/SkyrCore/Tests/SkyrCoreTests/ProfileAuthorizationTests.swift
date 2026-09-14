import Foundation
import Testing
@testable import SkyrCore

@MainActor
private final class ProfileFixture {
    let directory: URL
    let suiteName: String
    let defaults: UserDefaults
    let store: ProfileStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "skyr-profile-test-\(UUID().uuidString)")
        suiteName = "skyr.profile.tests.\(UUID().uuidString)"
        defaults = try #require(UserDefaults(suiteName: suiteName))
        store = ProfileStore(directory: directory, defaults: defaults)
    }

    func cleanUp() {
        store.onDeactivate = nil
        store.lock()
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: directory)
    }

    func owner(pin: String? = nil) throws -> Profile {
        let owner = try #require(store.owner)
        #expect(store.activate(owner))
        if let pin {
            var edited = owner
            edited.pin = PINRecord.make(pin)
            #expect(store.update(edited))
        }
        return try #require(store.owner)
    }

    func member(pin: String? = nil) throws -> Profile {
        try #require(store.create(name: "Member", avatar: .random(), pin: pin))
    }
}

@Test @MainActor func profilePINOpeningAndRemovalRequireAnActiveSession() throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    store.openAutomaticallyIfPossible()
    let firstSession = try #require(store.sessionID)
    var owner = try #require(store.active)
    owner.pin = PINRecord.make("2468")
    #expect(store.update(owner))
    #expect(store.sessionID == firstSession)
    owner = try #require(store.owner)
    store.lock()

    store.openAutomaticallyIfPossible()
    #expect(store.isLocked)
    #expect(!store.activate(owner))
    #expect(!store.activate(owner, pin: "1111"))
    #expect(store.sessionID == nil)
    #expect(store.activate(owner, pin: "2468"))
    #expect(store.sessionID != firstSession)

    var updated = try #require(store.active)
    updated.pin = nil
    #expect(store.update(updated))
    store.lock()
    store.openAutomaticallyIfPossible()
    #expect(!store.isLocked)
    #expect(store.active?.pin == nil)
}

@Test @MainActor func lockedProfileEditsAreDeniedWithoutChangingStoredData() throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let owner = try fixture.owner(pin: "2468")
    let member = try fixture.member()
    store.lock()
    let before = try Data(contentsOf: fixture.directory.appending(path: "profiles.json"))
    var edited = owner
    edited.pin = nil
    edited.name = "Updated owner"

    #expect(!store.canManageProfiles)
    #expect(!store.canEdit(owner))
    #expect(!store.update(edited))
    #expect(!store.delete(member))
    #expect(!store.setPhoto(nil, for: owner))
    #expect(!store.setBiometrics(true, for: owner))
    #expect(store.create(name: "Another", avatar: .random(), pin: nil) == nil)
    #expect(try Data(contentsOf: fixture.directory.appending(path: "profiles.json")) == before)
    #expect(!fixture.defaults.bool(forKey: "profiles.biometrics.\(owner.id)"))
}

@Test @MainActor func membersCanEditThemselvesAndOwnersCanManageMembers() throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let owner = try fixture.owner(pin: "2468")
    let member = try fixture.member()
    #expect(store.activate(member))
    #expect(!store.canManageProfiles)
    #expect(store.canEdit(member))
    #expect(!store.canEdit(owner))
    var selfEdit = member
    selfEdit.name = "My name"
    selfEdit.pin = PINRecord.make("1357")
    #expect(store.update(selfEdit))
    #expect(store.setBiometrics(true, for: member))
    #expect(!store.update(owner))
    #expect(!store.delete(member))

    var roleEdit = try #require(store.active)
    roleEdit.role = .owner
    #expect(!store.update(roleEdit))
    #expect(store.active?.role == .member)
    #expect(store.activate(owner, pin: "2468"))
    #expect(store.canManageProfiles)
    var managed = try #require(store.profiles.first { $0.id == member.id })
    managed.name = "Family member"
    managed.pin = nil
    #expect(store.update(managed))
    #expect(!store.biometricsEnabled(for: member))
    #expect(store.delete(managed))
    #expect(store.profiles.count == 1)
    #expect(!store.delete(owner))
}

@Test @MainActor func deactivationPublishesRevocationBeforeItsCallbackAndPreservesSavedState() throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let owner = try fixture.owner()
    let firstSession = try #require(store.sessionID)
    store.updateLibrary("test-drive") { $0.favourites = ["saved-song"] }
    var didDeactivate = false
    store.onDeactivate = {
        didDeactivate = true
        #expect(store.isLocked)
        #expect(store.activeID == nil)
        #expect(store.sessionID == nil)
        #expect(store.state.libraries.isEmpty)
    }
    store.lock()
    #expect(didDeactivate)
    #expect(store.storedState(id: owner.id).libraries["test-drive"]?.favourites == ["saved-song"])
    #expect(store.activate(owner))
    #expect(store.sessionID != firstSession)
    #expect(store.libraryState(for: "test-drive").favourites == ["saved-song"])
}

@Test @MainActor func aRemotePINChangeRequiresANewOpeningAndResetsBiometricEnrollment() throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let owner = try fixture.owner(pin: "2468")
    #expect(store.setBiometrics(true, for: owner))
    #expect(store.biometricsEnabled(for: owner))
    var remote = owner
    remote.pin = PINRecord.make("1357")
    remote.updatedAt = owner.updatedAt.addingTimeInterval(60)
    store.applyRemote(remote)

    #expect(store.isLocked)
    #expect(!store.biometricsEnabled(for: remote))
    #expect(!store.verify(pin: "2468", for: owner))
    #expect(!store.activate(owner, pin: "2468"))
    #expect(store.activate(remote, pin: "1357"))
    #expect(store.active?.pin == remote.pin)
}

@Test @MainActor func olderDraftsAreRejectedAndCurrentEditsKeepTheStoredPIN() throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let original = try fixture.owner()
    let editorSession = try #require(store.sessionID)
    #expect(store.canEditDraft(original, session: editorSession))
    var current = original
    current.pin = PINRecord.make("2468")
    #expect(store.update(current))

    #expect(!store.canEditDraft(original, session: editorSession))

    var olderDraft = original
    olderDraft.name = "New name"
    #expect(!store.update(olderDraft))
    current = try #require(store.active)
    current.name = "New name"
    #expect(store.update(current))
    #expect(store.active?.name == "New name")
    #expect(store.active?.pin?.matches("2468") == true)
    let latest = try #require(store.active)
    #expect(store.canEditDraft(latest, session: editorSession))
    store.lock()
    #expect(store.activate(latest, pin: "2468"))
    #expect(!store.canEditDraft(latest, session: editorSession))
}

@Test @MainActor func trustedSyncMaintenanceWorksWhileInteractiveManagementIsLocked() throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let standIn = try fixture.owner()
    let member = try fixture.member()
    store.bindActiveProfile(to: "current-user")
    #expect(store.active?.userRecordName == "current-user")
    store.lock()
    store.bindActiveProfile(to: "another-user")
    #expect(store.owner?.userRecordName == "current-user")
    #expect(!store.discardStandIn(standIn))
    #expect(!store.delete(member))
    #expect(store.discardStandIn(member))
    #expect(store.profiles.count == 1)
    #expect(store.owner?.id == standIn.id)
}

@Test @MainActor func biometricOpeningWithoutEnrollmentIsDeniedBeforePrompting() async throws {
    let fixture = try ProfileFixture()
    defer { fixture.cleanUp() }
    let store = fixture.store
    let owner = try fixture.owner(pin: "2468")
    store.lock()
    #expect(!(await store.unlockWithBiometrics(owner)))
    #expect(store.isLocked)
}
