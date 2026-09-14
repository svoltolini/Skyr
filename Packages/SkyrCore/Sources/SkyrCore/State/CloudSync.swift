import CloudKit
import Foundation
import Observation

/// Mirrors the profiles and their documents into CloudKit. The owner's private database holds a
/// "Family" zone; invited members reach the same zone through their shared database. The files on
/// the device stay what the screens read; this keeps them in step with the cloud, and does nothing
/// at all when the device has no iCloud account.
@Observable
public final class CloudSync {
    public enum Status: Equatable {
        case off, noAccount, syncing, synced(Date), failed(String)

        public var text: String {
            switch self {
            case .off: "Off"
            case .noAccount: "Not signed in to iCloud"
            case .syncing: "Syncing…"
            case .synced(let date): "Up to date · \(date.formatted(date: .omitted, time: .shortened))"
            case .failed(let message): message
            }
        }
    }

    public enum Membership: String {
        case owner, member
    }

    public struct Participant: Identifiable, Equatable {
        public let id: String
        public let name: String
        public let isOwner: Bool
        public let accepted: Bool
        public let isMe: Bool
    }

    public static let containerID = "iCloud.com.samuelvoltolini.skyr"
    private static let zoneName = "Family"

    public private(set) var status: Status = .off
    public private(set) var membership: Membership
    public private(set) var currentUserRecordName: String?
    public private(set) var participants: [Participant] = []
    public private(set) var family: FamilyInfo?
    /// True once the zone is shared with at least one other person, or this device joined one.
    public private(set) var isShared = false
    /// Only a definitive missing/deleted shared zone exposes invitation recovery while sync is failed.
    public private(set) var needsFamilyInvitation = false

    @ObservationIgnored private lazy var container = CKContainer(identifier: CloudSync.containerID)
    private let services: CloudServices
    private let persistence: CloudPersistence
    private var accountState: CloudAccountState?
    private var generation = UUID()
    private var zoneOwnerName: String
    private var changeToken: Data?
    /// CloudKit's own metadata per record, so saves carry the right change tags.
    private var systemFields: [String: Data]
    /// `updatedAt` of every record as last seen in the cloud, so only newer local data is pushed.
    private var remoteStamps: [String: Date]
    private var uploads: [String: Task<Void, Never>] = [:]
    private var isStarted = false
    private var isRefreshing = false
    private var wantsAnotherRefresh = false
    private var accountObserver: (any NSObjectProtocol)?
    /// Retried on the next sync; remains visible while offline or when CloudKit refuses a deletion.
    public var pendingDeletionCount: Int { accountState?.zones[zoneOwnerName]?.deletions.values.filter { !$0.isEmpty }.count ?? 0 }

    public weak var profiles: ProfileStore?
    /// The owner's server details, written into the family record for members to connect with.
    public var familyInfoProvider: (() -> FamilyInfo?)?
    /// Called with the family record whenever it arrives or changes.
    public var onFamilyInfo: ((FamilyInfo) -> Void)?

    private var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: Self.zoneName, ownerName: zoneOwnerName) }
    private var database: CKDatabase { membership == .member ? container.sharedCloudDatabase : container.privateCloudDatabase }
    private var shareRecordID: CKRecord.ID { CKRecord.ID(recordName: CKRecordNameZoneWideShare, zoneID: zoneID) }

    public var isOwner: Bool { membership == .owner }
    public var isActive: Bool {
        switch status {
        case .syncing, .synced: true
        default: false
        }
    }

    public convenience init() {
        self.init(services: .live(container: CKContainer(identifier: Self.containerID)), persistence: CloudPersistence(directory: Self.directory))
    }

    init(services: CloudServices, persistence: CloudPersistence) {
        self.services = services
        self.persistence = persistence
        // Legacy global metadata has no verifiable account owner. Refetch instead of adopting it.
        membership = .owner
        zoneOwnerName = CKCurrentUserDefaultName
        systemFields = [:]
        remoteStamps = [:]
    }

    // MARK: Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                self?.accountChanged()
                await self?.refresh(reason: "iCloud account changed")
            }
        }
        Task { await refresh(reason: "launch") }
    }

    /// Revocation happens before any new account request, including while an old request is suspended.
    func accountChanged() {
        generation = UUID()
        for task in uploads.values { task.cancel() }
        uploads = [:]
        currentUserRecordName = nil
        accountState = nil
        membership = .owner
        zoneOwnerName = CKCurrentUserDefaultName
        changeToken = nil
        systemFields = [:]
        remoteStamps = [:]
        family = nil
        participants = []
        isShared = false
        needsFamilyInvitation = false
        status = .off
        profiles?.lock()
    }

    private func check(_ expected: UUID) throws {
        guard generation == expected, !Task.isCancelled else { throw CancellationError() }
    }

    private func scope(_ expected: UUID) throws -> CloudScope {
        try check(expected)
        guard let account = currentUserRecordName, accountState?.account == account else { throw CKError(.notAuthenticated) }
        return CloudScope(account: account, owner: zoneOwnerName, isMember: membership == .member)
    }

    private func verifyIdentity(_ expected: UUID) async throws {
        let identity = try await services.identity()
        try check(expected)
        guard let identity else {
            accountChanged()
            status = .noAccount
            throw CancellationError()
        }
        guard currentUserRecordName != identity else { return }
        if currentUserRecordName != nil {
            // A missed notification must still invalidate every previously queued operation.
            accountChanged()
        }
        let snapshot: CloudAccountState
        do {
            let isNew = !persistence.hasSnapshot(account: identity)
            var loaded = try persistence.load(account: identity, defaultOwner: CKCurrentUserDefaultName)
            if isNew, try persistence.claimsLegacyProfiles(account: identity) {
                loaded.profileIDs = Set(profiles?.profiles.map(\.id) ?? [])
            }
            for profile in profiles?.profiles ?? [] {
                if case .recovery(_)? = profile.localOrigin {
                    if try recoveryProfileBelongs(profile, to: identity) { loaded.profileIDs.insert(profile.id) }
                    else { loaded.profileIDs.remove(profile.id) }
                }
            }
            try persistence.save(loaded)
            snapshot = loaded
        } catch {
            status = .failed("The iCloud account's sync state could not be read or saved on this device.")
            throw error
        }
        currentUserRecordName = identity
        accountState = snapshot
        membership = Membership(rawValue: snapshot.membership) ?? .owner
        zoneOwnerName = snapshot.zoneOwner
        loadZoneState()
    }

    private func loadZoneState() {
        let zone = accountState?.zones[zoneOwnerName] ?? .init()
        changeToken = zone.changeToken
        systemFields = zone.systemFields
        remoteStamps = zone.remoteStamps
        family = nil
        participants = []
        isShared = membership == .member
        needsFamilyInvitation = false
    }

    /// Pulls what changed, then pushes anything newer on this device. Overlapping calls fold into one more pass.
    public func refresh(reason: String) async {
        if isRefreshing {
            wantsAnotherRefresh = true
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            if wantsAnotherRefresh {
                wantsAnotherRefresh = false
                Task { await refresh(reason: "queued") }
            }
        }
        var expected = generation
        do {
            try await verifyIdentity(expected)
            // Identity discovery itself may have invalidated a missed account change.
            expected = generation
            status = .syncing
            try await adoptSharedZoneIfPresent(expected)
            expected = generation
            if membership == .owner {
                try await services.createZone(scope(expected))
                try check(expected)
            }
            try await ensureSubscriptions(expected)
            try await retryDeletions(expected)
            try await fetchChanges()
            try check(expected)
            try registerRecoveryProfiles()
            if let replacement = profiles?.ensureProfileAfterSync(isOwner: isOwner) {
                accountState?.profileIDs.insert(replacement.id)
                try persistState()
            }
            if profiles?.profiles.isEmpty == true { throw SyncFailure.message("A new local profile could not be saved after iCloud removed the last profile.") }
            discardStandIns()
            try await retryDeletions(expected)
            try await pushLocal()
            try check(expected)
            status = .synced(.now)
            if let profiles, profiles.isLocked {
                let eligible = profiles.profiles.filter { accountState?.profileIDs.contains($0.id) == true }
                if eligible.contains(where: { $0.userRecordName == currentUserRecordName }) || (profiles.profiles.count == 1 && eligible.count == 1) {
                    profiles.openAutomaticallyIfPossible(boundTo: currentUserRecordName)
                }
            }
        } catch is CancellationError {
            return
        } catch {
            guard generation == expected else { return }
            status = .failed(Self.describe(error))
            services.log("iCloud sync (\(reason)) failed: \(Self.describe(error))")
        }
    }

    /// A share accepted on any of this person's devices shows up in their shared database; follow it.
    private func adoptSharedZoneIfPresent(_ expected: UUID) async throws {
        guard membership != .member else { return }
        let owners = try await services.sharedZones()
        try check(expected)
        guard let owner = owners.first else { return }
        try join(zoneOwnerName: owner)
        services.log("Following the shared family")
    }

    private func join(zoneOwnerName: String) throws {
        try persistState()
        guard var snapshot = accountState else { throw CKError(.notAuthenticated) }
        snapshot.membership = Membership.member.rawValue
        snapshot.zoneOwner = zoneOwnerName
        guard profiles?.markAllAsMembers(in: snapshot.profileIDs) != false else {
            throw SyncFailure.message("The family membership could not be saved to the profiles on this device.")
        }
        try persistence.save(snapshot)
        generation = UUID()
        for task in uploads.values { task.cancel() }
        uploads = [:]
        membership = .member
        self.zoneOwnerName = zoneOwnerName
        accountState = snapshot
        loadZoneState()
        // In someone else's family this device's profiles are members, whatever they were before.
    }

    private func ensureSubscriptions(_ expected: UUID) async throws {
        guard accountState?.subscribed != true else { return }
        try await services.subscribe()
        try check(expected)
        accountState?.subscribed = true
        try persistState()
    }

    // MARK: Pulling

    public func fetchChanges() async throws {
        let expected = generation
        let activeScope = try scope(expected)
        let page: CloudChangePage
        do {
            page = try await services.changes(activeScope, changeToken)
            try check(expected)
            needsFamilyInvitation = false
        } catch let error as CKError where error.code == .changeTokenExpired {
            try check(expected)
            // A reset is durable before another page is requested. Never acknowledge a bad page.
            changeToken = nil
            try persistState()
            try await fetchChanges()
            return
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone {
            try check(expected)
            // A missing shared zone must not silently move its profiles/deletion intents into a new family.
            needsFamilyInvitation = membership == .member
            throw SyncFailure.message(membership == .member
                ? "The shared family is no longer available. Ask its owner for a new invitation and join again in Family settings."
                : "The iCloud family is unavailable. Try syncing again.")
        }
        var failures = 0
        for result in page.records {
            do {
                let record = try result.get()
                guard record.recordID.zoneID == activeScope.zoneID else { throw SyncFailure.message("An iCloud record arrived for a different family.") }
                try apply(record)
            } catch {
                failures += 1
                services.log("iCloud: a changed record could not be applied: \(Self.describe(error))")
            }
        }
        for deletion in page.deletions {
            do {
                guard deletion.id.zoneID == activeScope.zoneID else { throw SyncFailure.message("An iCloud deletion arrived for a different family.") }
                try removed(deletion.id, type: deletion.type)
            } catch { failures += 1 }
        }
        // Persist successful entries for idempotent retry, keeping the previous cursor on any failure.
        try persistState()
        guard failures == 0 else {
            let problem = SyncFailure.message("iCloud sync is incomplete: \(failures) change(s) will be retried.")
            status = .failed(problem.localizedDescription)
            throw problem
        }
        let previous = changeToken
        changeToken = page.token
        do { try persistState() }
        catch {
            changeToken = previous
            throw error
        }
        if page.moreComing { try await fetchChanges() }
    }

    private enum SyncFailure: LocalizedError {
        case message(String)
        var errorDescription: String? { switch self { case .message(let message): message } }
    }

    private func isTombstoned(_ id: String) -> Bool {
        accountState?.zones[zoneOwnerName]?.deletions[id] != nil
    }

    private func retainDeletionForReturnedRecord(_ id: String) throws {
        // Another device (or an already submitted upload) may return a live record after an ack.
        // Keep suppressing it locally and send both deletions again during this refresh.
        accountState?.zones[zoneOwnerName]?.deletions[id] = [id, "state-\(id)"]
        try persistState()
    }

    private func apply(_ record: CKRecord) throws {
        switch record.recordType {
        case "Profile":
            guard let profile = Self.profile(from: record) else { throw SyncFailure.message("A profile from iCloud is incomplete.") }
            if isTombstoned(profile.id) { try retainDeletionForReturnedRecord(profile.id); return }
            guard let profiles else { throw SyncFailure.message("Profiles are not ready to receive iCloud changes.") }
            if profile.avatar.hasPhoto, (record["photo"] as? CKAsset)?.fileURL == nil {
                throw SyncFailure.message("A profile photo from iCloud is incomplete.")
            }
            if profiles.profiles.first(where: { $0.id == profile.id }).map({ $0.updatedAt >= profile.updatedAt }) != true {
                guard profiles.storeRemotePhoto(at: profile.avatar.hasPhoto ? (record["photo"] as? CKAsset)?.fileURL : nil, for: profile.id),
                      profiles.applyRemote(profile) else { throw SyncFailure.message("A profile from iCloud could not be saved on this device.") }
            }
            remoteStamps[record.recordID.recordName] = profile.updatedAt
            accountState?.profileIDs.insert(profile.id)
        case "ProfileState":
            guard let data = record["document"] as? Data, let state = try? Self.decoder.decode(ProfileState.self, from: data),
                  let profileID = record["profileID"] as? String,
                  record.recordID.recordName == "state-\(profileID)" else { throw SyncFailure.message("A profile's iCloud document is incomplete.") }
            if isTombstoned(profileID) { try retainDeletionForReturnedRecord(profileID); return }
            guard let profiles, profiles.applyRemote(state, id: profileID) else { throw SyncFailure.message("A profile's iCloud document could not be saved on this device.") }
            remoteStamps[record.recordID.recordName] = state.updatedAt
        case "Family":
            let info = FamilyInfo(
                name: record["name"] as? String ?? "Family",
                serverName: record["serverName"] as? String ?? "",
                serverAccount: record["serverAccount"] as? String ?? "",
                musicPath: record["musicPath"] as? String,
                updatedAt: record["updatedAt"] as? Date ?? .distantPast,
                familyAccount: record["familyAccount"] as? String,
                familyPassword: record.encryptedValues["familyPassword"] as? String,
                address: record["address"] as? String
            )
            remoteStamps[record.recordID.recordName] = info.updatedAt
            family = info
            onFamilyInfo?(info)
        case "cloudkit.share":
            if let share = record as? CKShare { update(share) }
        default: break
        }
        remember(record)
    }

    private func removed(_ recordID: CKRecord.ID, type: CKRecord.RecordType) throws {
        switch type {
        case "Profile":
            guard let profiles, profiles.removeRemote(id: recordID.recordName, replacementAccount: currentUserRecordName, replacementIsOwner: isOwner) else {
                throw SyncFailure.message("A deleted iCloud profile could not be removed from this device.")
            }
            if accountState?.zones[zoneOwnerName] == nil { accountState?.zones[zoneOwnerName] = .init() }
            if accountState?.zones[zoneOwnerName]?.deletions[recordID.recordName] == nil {
                accountState?.zones[zoneOwnerName]?.deletions[recordID.recordName] = []
            }
        case "cloudkit.share":
            participants = []
            isShared = false
        default: break
        }
        systemFields[recordID.recordName] = nil
        remoteStamps[recordID.recordName] = nil
    }

    private func update(_ share: CKShare) {
        participants = share.participants.map { participant in
            let name = participant.userIdentity.nameComponents.map { PersonNameComponentsFormatter.localizedString(from: $0, style: .default) } ?? ""
            let recordName = participant.userIdentity.userRecordID?.recordName ?? UUID().uuidString
            return Participant(
                id: recordName,
                name: name.isEmpty ? (participant.role == .owner ? "Owner" : "Invited") : name,
                isOwner: participant.role == .owner,
                accepted: participant.acceptanceStatus == .accepted,
                isMe: recordName == currentUserRecordName
            )
        }
        isShared = share.participants.count > 1 || membership == .member
    }

    // MARK: Pushing

    /// Uploads local profiles and documents the cloud has not seen, or has older copies of.
    /// A fresh install makes a stand-in profile before iCloud has answered, and an older build
    /// uploaded it. Once the family's profiles are here and one of them is already this person's,
    /// any untouched stand-in goes, here and in the cloud, so every device converges on one profile.
    private func discardStandIns() {
        guard let profiles, let user = currentUserRecordName,
              profiles.profiles.contains(where: { $0.userRecordName == user }) else { return }
        let standIns = profiles.profiles.filter { profile in
            profile.userRecordName == nil && profile.pin == nil && profile.avatar.photoVersion == nil
                && profile.localOrigin != .created
                && abs(profile.updatedAt.timeIntervalSince(profile.createdAt)) < 2
                && profiles.storedState(id: profile.id).isPristine
        }
        for standIn in standIns where profiles.profiles.count > 1 {
            services.log("Removing the stand-in profile “\(standIn.name)”: this iCloud account already has a profile")
            profiles.discardStandIn(standIn)
        }
    }

    private func pushLocal() async throws {
        guard let profiles else { return }
        var toSave: [CKRecord] = []
        var newProfiles = 0
        let remoteProfileCount = remoteStamps.keys.filter { !$0.hasPrefix("state-") && $0 != "family" }.count
        for profile in profiles.profiles {
            guard accountState?.profileIDs.contains(profile.id) == true, !isTombstoned(profile.id) else { continue }
            let stamp = remoteStamps[profile.id]
            if stamp == nil {
                guard remoteProfileCount + newProfiles < Profile.limit else {
                    services.log("Not uploading “\(profile.name)”: the family already has \(Profile.limit) profiles")
                    continue
                }
                newProfiles += 1
            }
            if stamp == nil || profile.updatedAt > stamp! {
                toSave.append(record(for: profile))
            }
            let state = profiles.storedState(id: profile.id)
            let stateStamp = remoteStamps["state-\(profile.id)"]
            if state.updatedAt > .distantPast, stateStamp == nil || state.updatedAt > stateStamp! {
                if let record = record(for: state, profileID: profile.id) { toSave.append(record) }
            }
        }
        if membership == .owner, let active = profiles.active, accountState?.profileIDs.contains(active.id) == true,
           let info = familyInfoProvider?(), remoteStamps["family"] == nil || family.map({ !$0.describesSameServer(as: info) }) ?? true {
            var current = info
            current.updatedAt = .now
            toSave.append(record(for: current))
            family = current
        }
        if let user = currentUserRecordName, !profiles.profiles.contains(where: { $0.userRecordName == user }), let active = profiles.active,
           accountState?.profileIDs.contains(active.id) == true, active.userRecordName == nil {
            // The profile in use becomes this iCloud user's own, so their other devices open it directly.
            profiles.bindActiveProfile(to: user)
            if let stored = profiles.profiles.first(where: { $0.id == active.id }) {
                toSave.removeAll { $0.recordID.recordName == stored.id }
                toSave.append(record(for: stored))
            }
        }
        guard !toSave.isEmpty else { return }
        try await save(toSave)
    }

    public func profileChanged(_ profile: Profile) {
        guard accountState?.profileIDs.contains(profile.id) == true, !isTombstoned(profile.id) else { return }
        schedule(key: profile.id) { [weak self] in
            guard let self else { return }
            try await save([record(for: profile)])
        }
    }

    func containsProfileInCurrentAccount(_ id: String) -> Bool {
        accountState?.profileIDs.contains(id) == true && !isTombstoned(id)
    }

    /// A new profile inherits the active profile's verified account scope, including after an
    /// offline relaunch. Persist that association before the profile is exposed locally.
    func prepareProfileCreation(_ profile: Profile) -> Bool {
        guard let active = profiles?.active else { return false }
        let isVerified = currentUserRecordName != nil && accountState?.account == currentUserRecordName
        do {
            guard var snapshot = isVerified ? accountState : try persistence.deletionContext(profileID: active.id) else {
                if active.userRecordName == nil, try !persistence.hasCloudAssociation(profileID: active.id) {
                    return true // Local first-launch profiles are adopted on their first verified sync.
                }
                status = .failed("Connect to iCloud to confirm which family the new profile belongs to.")
                return false
            }
            guard snapshot.profileIDs.contains(active.id), snapshot.zones[snapshot.zoneOwner]?.deletions[active.id] == nil else {
                status = .failed("Open a profile in this Apple Account before creating another profile.")
                return false
            }
            snapshot.profileIDs.insert(profile.id)
            try persistence.save(snapshot)
            if isVerified { accountState = snapshot }
            return true
        } catch {
            status = .failed("The new profile could not be created because its iCloud membership could not be saved on this device.")
            return false
        }
    }

    /// Must succeed before local removal; an offline deletion survives relaunch in this account/family.
    func prepareProfileDeletion(id: String) -> Bool {
        var snapshot: CloudAccountState
        let isVerified = currentUserRecordName != nil && accountState?.account == currentUserRecordName
        do {
            guard let context = isVerified ? accountState : try persistence.deletionContext(profileID: id) else {
                if profiles?.profiles.first(where: { $0.id == id })?.userRecordName == nil,
                   try !persistence.hasCloudAssociation(profileID: id) {
                    return true // A purely local profile has no remote deletion to retry.
                }
                status = .failed("Connect to iCloud to confirm which family's profile to delete.")
                return false
            }
            snapshot = context
        } catch {
            status = .failed("The profile's pending iCloud deletion could not be saved on this device.")
            return false
        }
        guard snapshot.profileIDs.contains(id) else {
            status = .failed("This profile belongs to another Apple Account. Switch back to that account before deleting it.")
            return false
        }
        let owner = snapshot.zoneOwner
        if snapshot.zones[owner]?.deletions[id] != nil { return true }
        var zone = snapshot.zones[owner] ?? .init()
        if isVerified {
            zone.changeToken = changeToken
            zone.systemFields = systemFields
            zone.remoteStamps = remoteStamps
        }
        zone.deletions[id] = [id, "state-\(id)"]
        snapshot.zones[owner] = zone
        do {
            try persistence.save(snapshot)
            if isVerified { accountState = snapshot }
            else { status = .failed("The profile deletion is saved and will sync when its Apple Account reconnects.") }
        } catch {
            status = .failed("The profile could not be deleted because its pending iCloud change could not be saved on this device.")
            return false
        }
        uploads[id]?.cancel()
        uploads["state-\(id)"]?.cancel()
        return true
    }

    public func profileDeleted(id: String) {
        guard isTombstoned(id), isActive else { return }
        Task { await refresh(reason: "profile deleted") }
    }

    private func retryDeletions(_ expected: UUID) async throws {
        guard let deletions = accountState?.zones[zoneOwnerName]?.deletions else { return }
        // Reconcile first, including already-acknowledged tombstones: a crash or disk failure may
        // have happened after the durable intent but before the local profile list was replaced.
        for id in deletions.keys {
            guard let profiles, profiles.removeRemote(id: id, replacementAccount: currentUserRecordName, replacementIsOwner: isOwner) else {
                throw SyncFailure.message("A pending profile deletion could not be applied on this device. It will be retried.")
            }
        }
        try registerRecoveryProfiles()
        let names = Set(deletions.values.flatMap { $0 })
        guard !names.isEmpty else { return }
        let activeScope = try scope(expected)
        let ids = names.map { CKRecord.ID(recordName: $0, zoneID: activeScope.zoneID) }
        let result = try await services.modify(activeScope, [], ids)
        try check(expected)
        var firstFailure: (any Error)?
        for id in ids {
            let outcome = result.deleted[id] ?? .failure(SyncFailure.message("iCloud did not acknowledge a profile deletion."))
            let succeeded: Bool
            switch outcome {
            case .success: succeeded = true
            case .failure(let error):
                succeeded = (error as? CKError)?.code == .unknownItem
                if !succeeded, firstFailure == nil { firstFailure = error }
            }
            if succeeded {
                for profileID in deletions.keys { accountState?.zones[zoneOwnerName]?.deletions[profileID]?.remove(id.recordName) }
                systemFields[id.recordName] = nil
                remoteStamps[id.recordName] = nil
            }
        }
        try persistState()
        if let firstFailure { throw SyncFailure.message("A profile deletion is pending: \(Self.describe(firstFailure))") }
    }

    private func registerRecoveryProfiles() throws {
        guard let account = currentUserRecordName else { return }
        var changed = false
        for profile in profiles?.profiles ?? [] {
            if case .recovery(_)? = profile.localOrigin {
                let belongs = try recoveryProfileBelongs(profile, to: account)
                if belongs != (accountState?.profileIDs.contains(profile.id) == true) {
                    if belongs { accountState?.profileIDs.insert(profile.id) }
                    else { accountState?.profileIDs.remove(profile.id) }
                    changed = true
                }
            }
        }
        if changed { try persistState() }
    }

    private func recoveryProfileBelongs(_ profile: Profile, to account: String) throws -> Bool {
        guard case .recovery(let origin)? = profile.localOrigin else { return false }
        if let origin { return origin == account }
        if let previous = try persistence.deletionContext(profileID: profile.id) {
            guard previous.account == account else { return false }
        } else if try persistence.hasCloudAssociation(profileID: profile.id) {
            return false // Multiple known account owners require resolution instead of guessing.
        }
        guard profiles?.bindUnassignedRecoveryProfile(id: profile.id, to: account) == true else {
            throw SyncFailure.message("The recovery profile's Apple Account could not be saved on this device.")
        }
        return true
    }

    public func stateChanged(_ state: ProfileState, id: String) {
        guard accountState?.profileIDs.contains(id) == true, !isTombstoned(id) else { return }
        schedule(key: "state-\(id)") { [weak self] in
            guard let self, let record = record(for: state, profileID: id) else { return }
            try await save([record])
        }
    }

    private func schedule(key: String, _ work: @escaping () async throws -> Void) {
        guard isActive else { return }
        let expected = generation
        uploads[key]?.cancel()
        uploads[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, generation == expected, !Task.isCancelled else { return }
            do {
                try await work()
            } catch is CancellationError {
                return
            } catch {
                guard generation == expected else { return }
                status = .failed(Self.describe(error))
                services.log("iCloud upload failed: \(Self.describe(error))")
            }
            if generation == expected { uploads[key] = nil }
        }
    }

    /// Saves records, taking the server's copy when it moved on and ours is older. One bad record
    /// makes CloudKit report "Atomic failure" for the others in the batch; those are retried on their
    /// own so the real problem, not its side effect, is what gets logged and shown.
    private func save(_ records: [CKRecord]) async throws {
        let expected = generation
        let activeScope = try scope(expected)
        guard records.allSatisfy({ $0.recordID.zoneID == activeScope.zoneID }) else { throw CancellationError() }
        let result = try await services.modify(activeScope, records, [])
        guard generation == expected else { throw CancellationError() }
        var returnedDeletedRecord = false
        for record in records {
            let profileID = record.recordType == "Profile" ? record.recordID.recordName : record["profileID"] as? String
            if let profileID, isTombstoned(profileID) {
                try retainDeletionForReturnedRecord(profileID)
                returnedDeletedRecord = true
            }
        }
        if returnedDeletedRecord {
            Task { await refresh(reason: "completed upload for a deleted profile") }
            throw CancellationError()
        }
        try check(expected)
        var retry: [CKRecord] = []
        var heldBack: [CKRecord] = []
        var problem: (any Error)?
        for record in records {
            let id = record.recordID
            let outcome = result.saved[id] ?? .failure(SyncFailure.message("iCloud did not acknowledge a saved record."))
            switch outcome {
            case .success(let saved):
                remember(saved)
                if let stamp = saved["updatedAt"] as? Date { remoteStamps[id.recordName] = stamp }
            case .failure(let error):
                guard let ours = records.first(where: { $0.recordID == id }) else { throw error }
                let ckError = error as? CKError
                if ckError?.code == .serverRecordChanged, let server = ckError?.serverRecord {
                    remember(server)
                    let serverStamp = server["updatedAt"] as? Date ?? .distantPast
                    let ourStamp = ours["updatedAt"] as? Date ?? .distantPast
                    if ourStamp > serverStamp {
                        for key in ours.allKeys() { server[key] = ours[key] }
                        retry.append(server)
                    } else {
                        try apply(server)
                    }
                } else if ckError?.code == .batchRequestFailed, records.count > 1 {
                    heldBack.append(ours)
                } else {
                    services.log("iCloud: could not save \(ours.recordType) \(id.recordName): \(Self.detail(error))")
                    if problem == nil { problem = SaveFailure(record: ours, underlying: error) }
                }
            }
        }
        try persistState()
        if !retry.isEmpty { try await save(retry) }
        if let problem { throw problem }
        // Only side effects came back: the record that caused them is found by saving each alone.
        for record in heldBack { try await save([record]) }
    }

    /// A record CloudKit would not take, named so the message says what was lost.
    private struct SaveFailure: LocalizedError {
        let record: CKRecord
        let underlying: any Error

        var errorDescription: String? {
            let what: String
            switch record.recordType {
            case "Profile": what = "the profile “\(record["name"] as? String ?? "")”"
            case "ProfileState": what = "a profile's favourites and playlists"
            case "Family": what = "the family's server details"
            default: what = "a record"
            }
            return "Couldn't save \(what) to iCloud: \(CloudSync.describe(underlying))"
        }
    }

    // MARK: Records

    private func baseRecord(named name: String, type: String) -> CKRecord {
        if let data = systemFields[name], let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) {
            unarchiver.requiresSecureCoding = true
            if let record = CKRecord(coder: unarchiver) { return record }
        }
        return CKRecord(recordType: type, recordID: CKRecord.ID(recordName: name, zoneID: zoneID))
    }

    private func record(for profile: Profile) -> CKRecord {
        let record = baseRecord(named: profile.id, type: "Profile")
        record["name"] = profile.name
        record["symbol"] = profile.avatar.symbol
        record["colorHex"] = profile.avatar.colorHex
        record["pinSalt"] = profile.pin?.salt
        record["pinHash"] = profile.pin?.hash
        record["role"] = profile.role.rawValue
        record["createdAt"] = profile.createdAt
        record["updatedAt"] = profile.updatedAt
        record["userRecordName"] = profile.userRecordName
        record["photoVersion"] = profile.avatar.photoVersion
        if let url = ProfileStore.photoURL(for: profile.id), profile.avatar.hasPhoto {
            record["photo"] = CKAsset(fileURL: url)
        } else {
            record["photo"] = nil
        }
        return record
    }

    private func record(for state: ProfileState, profileID: String) -> CKRecord? {
        guard let data = try? Self.encoder.encode(state) else { return nil }
        let record = baseRecord(named: "state-\(profileID)", type: "ProfileState")
        record["document"] = data
        record["profileID"] = profileID
        record["updatedAt"] = state.updatedAt
        return record
    }

    private func record(for info: FamilyInfo) -> CKRecord {
        let record = baseRecord(named: "family", type: "Family")
        record["name"] = info.name
        record["address"] = info.address
        record["serverName"] = info.serverName
        record["serverAccount"] = info.serverAccount
        record["musicPath"] = info.musicPath
        record["updatedAt"] = info.updatedAt
        record["familyAccount"] = info.familyAccount
        // End-to-end encrypted; the key is shared only with the family's participants.
        record.encryptedValues["familyPassword"] = info.familyPassword
        return record
    }

    private static func profile(from record: CKRecord) -> Profile? {
        guard let name = record["name"] as? String else { return nil }
        var pin: PINRecord?
        if let salt = record["pinSalt"] as? String, let hash = record["pinHash"] as? String { pin = PINRecord(salt: salt, hash: hash) }
        return Profile(
            id: record.recordID.recordName,
            name: name,
            avatar: ProfileAvatar(symbol: record["symbol"] as? String ?? "music.note", colorHex: record["colorHex"] as? String ?? "#4a2fd6", photoVersion: record["photoVersion"] as? Int),
            pin: pin,
            role: Profile.Role(rawValue: record["role"] as? String ?? "") ?? .member,
            createdAt: record["createdAt"] as? Date ?? .now,
            updatedAt: record["updatedAt"] as? Date ?? .distantPast,
            userRecordName: record["userRecordName"] as? String
        )
    }

    private func remember(_ record: CKRecord) {
        let archiver = NSKeyedArchiver(requiringSecureCoding: true)
        record.encodeSystemFields(with: archiver)
        archiver.finishEncoding()
        systemFields[record.recordID.recordName] = archiver.encodedData
    }

    // MARK: Sharing

    /// The share for the family zone, made on first use. Only the owner can call this.
    public func share() async throws -> CKShare {
        try await verifyIdentity(generation)
        let expected = generation
        _ = try scope(expected)
        guard membership == .owner else { throw CKError(.permissionFailure) }
        let database = database
        let recordID = shareRecordID
        let existing = try? await database.record(for: recordID) as? CKShare
        try check(expected)
        let share = existing ?? CKShare(recordZoneID: zoneID)
        let title = familyTitle
        if existing != nil, share.publicPermission == .readWrite, share.url != nil, share[CKShare.SystemFieldKey.title] as? String == title {
            update(share)
            return share
        }
        share[CKShare.SystemFieldKey.title] = title as CKRecordValue
        if let photo = ownerPhotoData() {
            share[CKShare.SystemFieldKey.thumbnailImageData] = photo as CKRecordValue
        }
        // The app hands the link out itself, so anyone who opens it may join and write their own profile.
        share.publicPermission = .readWrite
        let result = try await database.modifyRecords(saving: [share], deleting: [], savePolicy: .changedKeys, atomically: true)
        try check(expected)
        guard case .success(let saved) = result.saveResults[share.recordID], let savedShare = saved as? CKShare else {
            throw CKError(.internalError)
        }
        update(savedShare)
        services.log("\(existing == nil ? "Family share created" : "Family share updated"); link \(savedShare.url == nil ? "not ready yet" : "ready")")
        return savedShare
    }

    /// "Samuel's family", or a neutral name while the owner is still called "Me".
    public var familyTitle: String {
        let name = profiles?.owner?.name.trimmingCharacters(in: .whitespaces) ?? ""
        guard !name.isEmpty, name.caseInsensitiveCompare("Me") != .orderedSame else { return "Skyr family" }
        return "\(name)'s family"
    }

    private func ownerPhotoData() -> Data? {
        guard let owner = profiles?.owner, let url = ProfileStore.photoURL(for: owner.id) else { return nil }
        return try? Data(contentsOf: url)
    }

    /// An invitation link tapped on this device.
    public func accept(_ metadata: CKShare.Metadata) async {
        _ = await join(metadata)
    }

    /// An invitation link pasted into the app, for when the system opened it somewhere else. Any
    /// Apple Account can join this way; Family Sharing plays no part. Returns what went wrong, if anything.
    public func accept(url: URL) async -> String? {
        guard Self.isInvitation(url) else { return "That isn't a Skyr invitation link. It starts with icloud.com/share." }
        let metadata: CKShare.Metadata
        var expected = generation
        do {
            try await verifyIdentity(expected)
            expected = generation
            metadata = try await container.shareMetadata(for: url)
            try check(expected)
        } catch {
            guard generation == expected, !(error is CancellationError) else { return "The Apple Account changed. Try the invitation again." }
            let message = Self.describeInvitation(error)
            services.log("Could not read the invitation link: \(Self.detail(error))")
            return message
        }
        return await join(metadata)
    }

    private func join(_ metadata: CKShare.Metadata) async -> String? {
        var expected = generation
        do {
            try await verifyIdentity(expected)
            expected = generation
            _ = try await container.accept(metadata)
            try check(expected)
            try join(zoneOwnerName: metadata.share.recordID.zoneID.ownerName)
            services.log("Joined the family shared by \(metadata.share.recordID.zoneID.ownerName)")
            await refresh(reason: "joined family")
            return nil
        } catch {
            guard generation == expected, !(error is CancellationError) else { return "The Apple Account changed. Try the invitation again." }
            let message = Self.describeInvitation(error)
            status = .failed(message)
            services.log("Could not join the family: \(Self.detail(error))")
            return message
        }
    }

    /// Whether a URL is a CloudKit share link (the only kind of invitation Skyr sends).
    public nonisolated static func isInvitation(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return (host == "www.icloud.com" || host == "icloud.com") && url.path().hasPrefix("/share/")
    }

    private nonisolated static func describeInvitation(_ error: any Error) -> String {
        if let ckError = error as? CKError {
            switch ckError.code {
            case .unknownItem, .badContainer, .participantMayNeedVerification:
                return "This invitation isn't valid any more. Ask for a new link, and make sure both of you use the same version of Skyr."
            case .alreadyShared, .tooManyParticipants:
                return "The family is full: up to five people can join."
            case .notAuthenticated:
                return "Sign in to iCloud in the Settings app first. Any Apple Account works; you don't need Family Sharing."
            default: break
            }
        }
        return describe(error)
    }

    /// Owner: nobody else can reach the family zone any more. Member: this person steps out of it.
    public func stopSharing() async {
        var expected = generation
        do {
            try await verifyIdentity(expected)
            expected = generation
            _ = try scope(expected)
            try await database.deleteRecord(withID: shareRecordID)
            try check(expected)
            participants = []
            isShared = false
            if membership == .member {
                try persistState()
                guard var snapshot = accountState else { throw CKError(.notAuthenticated) }
                snapshot.membership = Membership.owner.rawValue
                snapshot.zoneOwner = CKCurrentUserDefaultName
                try persistence.save(snapshot)
                generation = UUID()
                for task in uploads.values { task.cancel() }
                uploads = [:]
                membership = .owner
                zoneOwnerName = CKCurrentUserDefaultName
                accountState = snapshot
                loadZoneState()
                services.log("Left the family")
                await refresh(reason: "left family")
            } else {
                services.log("Stopped sharing the family")
            }
        } catch {
            guard generation == expected, !(error is CancellationError) else { return }
            services.log("Could not change the family share: \(Self.describe(error))")
        }
    }

    // MARK: Persistence

    private func persistState() throws {
        guard var snapshot = accountState, snapshot.account == currentUserRecordName else { throw CKError(.notAuthenticated) }
        snapshot.membership = membership.rawValue
        snapshot.zoneOwner = zoneOwnerName
        var zone = snapshot.zones[zoneOwnerName] ?? .init()
        zone.changeToken = changeToken
        zone.systemFields = systemFields
        zone.remoteStamps = remoteStamps
        snapshot.zones[zoneOwnerName] = zone
        try persistence.save(snapshot)
        accountState = snapshot
    }

    private static let directory: URL = {
        let base = AppDirectories.support
            .appending(path: "Skyr/cloud", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private nonisolated static func describe(_ error: any Error) -> String {
        if let failure = error as? SaveFailure { return failure.errorDescription ?? "" }
        if let ckError = error as? CKError {
            switch ckError.code {
            case .networkUnavailable, .networkFailure: return "No internet connection."
            case .notAuthenticated: return "Not signed in to iCloud."
            case .quotaExceeded: return "iCloud storage is full."
            case .permissionFailure: return "iCloud refused the change."
            case .batchRequestFailed: return "iCloud turned down a related change."
            case .zoneBusy, .requestRateLimited, .serviceUnavailable: return "iCloud is busy. It will try again."
            case .serverRejectedRequest, .invalidArguments: return "iCloud rejected the record. \(ckError.localizedDescription)"
            default: break
            }
        }
        return error.localizedDescription
    }

    /// Everything the log needs to name the cause: the code, the message and what the server said.
    private nonisolated static func detail(_ error: any Error) -> String {
        guard let ckError = error as? CKError else { return "\(error)" }
        var parts = ["code \(ckError.code.rawValue) (\(ckError.code))", ckError.localizedDescription]
        if let underlying = ckError.userInfo[NSUnderlyingErrorKey] as? NSError { parts.append("underlying: \(underlying.domain) \(underlying.code) \(underlying.localizedDescription)") }
        if let server = ckError.userInfo["ServerErrorDescription"] as? String { parts.append("server: \(server)") }
        if let retry = ckError.retryAfterSeconds { parts.append("retry after \(retry)s") }
        return parts.joined(separator: " · ")
    }
}

extension ProfileState {
    /// Nothing favourited, played or made: the profile was never used.
    var isPristine: Bool {
        libraries.values.allSatisfy { $0.favourites.isEmpty && $0.playlists.isEmpty && $0.played.isEmpty }
    }
}
