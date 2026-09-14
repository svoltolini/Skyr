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

    private let container = CKContainer(identifier: CloudSync.containerID)
    private var zoneOwnerName: String
    private var changeToken: CKServerChangeToken?
    /// CloudKit's own metadata per record, so saves carry the right change tags.
    private var systemFields: [String: Data]
    /// `updatedAt` of every record as last seen in the cloud, so only newer local data is pushed.
    private var remoteStamps: [String: Date]
    private var uploads: [String: Task<Void, Never>] = [:]
    private var isStarted = false
    private var isRefreshing = false
    private var wantsAnotherRefresh = false
    private var accountObserver: (any NSObjectProtocol)?

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

    public init() {
        let defaults = UserDefaults.standard
        membership = Membership(rawValue: defaults.string(forKey: "cloud.membership") ?? "") ?? .owner
        zoneOwnerName = defaults.string(forKey: "cloud.zoneOwner") ?? CKCurrentUserDefaultName
        if let data = defaults.data(forKey: "cloud.changeToken") {
            changeToken = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: data)
        }
        systemFields = Self.loadDictionary("cloud-system-fields.json") ?? [:]
        remoteStamps = Self.loadDictionary("cloud-remote-stamps.json") ?? [:]
    }

    // MARK: Lifecycle

    public func start() {
        guard !isStarted else { return }
        isStarted = true
        accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in await self?.refresh(reason: "iCloud account changed") }
        }
        Task { await refresh(reason: "launch") }
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
        let account = (try? await container.accountStatus()) ?? .couldNotDetermine
        guard account == .available else {
            status = .noAccount
            return
        }
        status = .syncing
        do {
            if currentUserRecordName == nil {
                currentUserRecordName = try await container.userRecordID().recordName
            }
            try await adoptSharedZoneIfPresent()
            if membership == .owner {
                _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
            }
            try await ensureSubscriptions()
            try await fetchChanges()
            discardStandIns()
            try await pushLocal()
            status = .synced(.now)
            if let profiles, profiles.isLocked {
                profiles.openAutomaticallyIfPossible(boundTo: currentUserRecordName)
            }
        } catch {
            status = .failed(Self.describe(error))
            diagnostics("iCloud sync (\(reason)) failed: \(Self.describe(error))")
        }
    }

    /// A share accepted on any of this person's devices shows up in their shared database; follow it.
    private func adoptSharedZoneIfPresent() async throws {
        guard membership != .member else { return }
        let zones = try await container.sharedCloudDatabase.allRecordZones()
        guard let zone = zones.first(where: { $0.zoneID.zoneName == Self.zoneName }) else { return }
        join(zoneOwnerName: zone.zoneID.ownerName)
        diagnostics("Following the family shared by \(zone.zoneID.ownerName)")
    }

    private func join(zoneOwnerName: String) {
        membership = .member
        self.zoneOwnerName = zoneOwnerName
        changeToken = nil
        remoteStamps = [:]
        systemFields = [:]
        isShared = true
        persistState()
        // In someone else's family this device's profiles are members, whatever they were before.
        profiles?.markAllAsMembers()
    }

    private func ensureSubscriptions() async throws {
        guard !UserDefaults.standard.bool(forKey: "cloud.subscribed") else { return }
        for (database, id) in [(container.privateCloudDatabase, "family-private"), (container.sharedCloudDatabase, "family-shared")] {
            let subscription = CKDatabaseSubscription(subscriptionID: id)
            let info = CKSubscription.NotificationInfo()
            info.shouldSendContentAvailable = true
            subscription.notificationInfo = info
            _ = try await database.save(subscription)
        }
        UserDefaults.standard.set(true, forKey: "cloud.subscribed")
    }

    // MARK: Pulling

    public func fetchChanges() async throws {
        let result: (modificationResultsByID: [CKRecord.ID: Result<CKDatabase.RecordZoneChange.Modification, any Error>], deletions: [CKDatabase.RecordZoneChange.Deletion], changeToken: CKServerChangeToken, moreComing: Bool)
        do {
            result = try await database.recordZoneChanges(inZoneWith: zoneID, since: changeToken)
        } catch let error as CKError where error.code == .zoneNotFound || error.code == .userDeletedZone || error.code == .changeTokenExpired {
            if error.code == .changeTokenExpired {
                changeToken = nil
                persistState()
                try await fetchChanges()
                return
            }
            if membership == .member {
                // The family is gone or we were removed from it; back to a family of our own.
                diagnostics("The shared family zone is no longer reachable; using this device's own iCloud again")
                membership = .owner
                zoneOwnerName = CKCurrentUserDefaultName
                changeToken = nil
                isShared = false
                persistState()
                _ = try await container.privateCloudDatabase.save(CKRecordZone(zoneID: zoneID))
                try await fetchChanges()
            }
            return
        }
        var changed = 0
        for (_, modification) in result.modificationResultsByID {
            if case .success(let change) = modification {
                apply(change.record)
                changed += 1
            }
        }
        for deletion in result.deletions {
            removed(deletion.recordID, type: deletion.recordType)
        }
        changeToken = result.changeToken
        persistState()
        if changed > 0 || !result.deletions.isEmpty {
            diagnostics("iCloud: \(changed) records updated, \(result.deletions.count) removed")
        }
        if result.moreComing { try await fetchChanges() }
    }

    private func apply(_ record: CKRecord) {
        remember(record)
        switch record.recordType {
        case "Profile":
            guard let profile = Self.profile(from: record) else { return }
            remoteStamps[record.recordID.recordName] = profile.updatedAt
            if let current = profiles?.profiles.first(where: { $0.id == profile.id }), current.updatedAt >= profile.updatedAt {
                return
            }
            if profile.avatar.hasPhoto {
                profiles?.storeRemotePhoto(at: (record["photo"] as? CKAsset)?.fileURL, for: profile.id)
            } else {
                profiles?.storeRemotePhoto(at: nil, for: profile.id)
            }
            profiles?.applyRemote(profile)
        case "ProfileState":
            guard let data = record["document"] as? Data, let state = try? Self.decoder.decode(ProfileState.self, from: data),
                  let profileID = record["profileID"] as? String else { return }
            remoteStamps[record.recordID.recordName] = state.updatedAt
            profiles?.applyRemote(state, id: profileID)
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
        default:
            break
        }
    }

    private func removed(_ recordID: CKRecord.ID, type: CKRecord.RecordType) {
        systemFields[recordID.recordName] = nil
        remoteStamps[recordID.recordName] = nil
        switch type {
        case "Profile": profiles?.removeRemote(id: recordID.recordName)
        case "cloudkit.share":
            participants = []
            isShared = false
        default: break
        }
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
                && abs(profile.updatedAt.timeIntervalSince(profile.createdAt)) < 2
                && profiles.storedState(id: profile.id).isPristine
        }
        for standIn in standIns where profiles.profiles.count > 1 {
            diagnostics("Removing the stand-in profile “\(standIn.name)”: this iCloud account already has a profile")
            profiles.delete(standIn)
        }
    }

    private func pushLocal() async throws {
        guard let profiles else { return }
        var toSave: [CKRecord] = []
        var newProfiles = 0
        let remoteProfileCount = remoteStamps.keys.filter { !$0.hasPrefix("state-") && $0 != "family" }.count
        for profile in profiles.profiles {
            let stamp = remoteStamps[profile.id]
            if stamp == nil {
                guard remoteProfileCount + newProfiles < Profile.limit else {
                    diagnostics("Not uploading “\(profile.name)”: the family already has \(Profile.limit) profiles")
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
        if membership == .owner, let info = familyInfoProvider?(), remoteStamps["family"] == nil || family.map({ !$0.describesSameServer(as: info) }) ?? true {
            var current = info
            current.updatedAt = .now
            toSave.append(record(for: current))
            family = current
        }
        if let user = currentUserRecordName, !profiles.profiles.contains(where: { $0.userRecordName == user }), let active = profiles.active {
            // The profile in use becomes this iCloud user's own, so their other devices open it directly.
            var bound = active
            bound.userRecordName = user
            profiles.update(bound, echo: false)
            if let stored = profiles.profiles.first(where: { $0.id == bound.id }) {
                toSave.removeAll { $0.recordID.recordName == stored.id }
                toSave.append(record(for: stored))
            }
        }
        guard !toSave.isEmpty else { return }
        try await save(toSave)
    }

    public func profileChanged(_ profile: Profile) {
        schedule(key: profile.id) { [weak self] in
            guard let self else { return }
            try await save([record(for: profile)])
        }
    }

    public func profileDeleted(id: String) {
        uploads[id]?.cancel()
        uploads["state-\(id)"]?.cancel()
        guard isActive else { return }
        Task {
            do {
                _ = try await database.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: id, zoneID: zoneID), CKRecord.ID(recordName: "state-\(id)", zoneID: zoneID)], savePolicy: .changedKeys, atomically: false)
                systemFields[id] = nil
                systemFields["state-\(id)"] = nil
                remoteStamps[id] = nil
                remoteStamps["state-\(id)"] = nil
                persistState()
            } catch {
                diagnostics("iCloud: could not delete a profile: \(Self.describe(error))")
            }
        }
    }

    public func stateChanged(_ state: ProfileState, id: String) {
        schedule(key: "state-\(id)") { [weak self] in
            guard let self, let record = record(for: state, profileID: id) else { return }
            try await save([record])
        }
    }

    private func schedule(key: String, _ work: @escaping () async throws -> Void) {
        guard isActive else { return }
        uploads[key]?.cancel()
        uploads[key] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            do {
                try await work()
            } catch {
                diagnostics("iCloud upload failed: \(Self.describe(error))")
            }
            self?.uploads[key] = nil
        }
    }

    /// Saves records, taking the server's copy when it moved on and ours is older. One bad record
    /// makes CloudKit report "Atomic failure" for the others in the batch; those are retried on their
    /// own so the real problem, not its side effect, is what gets logged and shown.
    private func save(_ records: [CKRecord]) async throws {
        let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .changedKeys, atomically: false)
        var retry: [CKRecord] = []
        var heldBack: [CKRecord] = []
        var problem: (any Error)?
        for (id, outcome) in result.saveResults {
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
                        apply(server)
                    }
                } else if ckError?.code == .batchRequestFailed, records.count > 1 {
                    heldBack.append(ours)
                } else {
                    diagnostics("iCloud: could not save \(ours.recordType) \(id.recordName): \(Self.detail(error))")
                    if problem == nil { problem = SaveFailure(record: ours, underlying: error) }
                }
            }
        }
        persistState()
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
        let existing = try? await database.record(for: shareRecordID) as? CKShare
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
        guard case .success(let saved) = result.saveResults[share.recordID], let savedShare = saved as? CKShare else {
            throw CKError(.internalError)
        }
        update(savedShare)
        diagnostics("\(existing == nil ? "Family share created" : "Family share updated"); link \(savedShare.url == nil ? "not ready yet" : "ready")")
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
        do {
            metadata = try await container.shareMetadata(for: url)
        } catch {
            let message = Self.describeInvitation(error)
            diagnostics("Could not read the invitation link: \(Self.detail(error))")
            return message
        }
        return await join(metadata)
    }

    private func join(_ metadata: CKShare.Metadata) async -> String? {
        do {
            _ = try await container.accept(metadata)
            join(zoneOwnerName: metadata.share.recordID.zoneID.ownerName)
            diagnostics("Joined the family shared by \(metadata.share.recordID.zoneID.ownerName)")
            await refresh(reason: "joined family")
            return nil
        } catch {
            let message = Self.describeInvitation(error)
            status = .failed(message)
            diagnostics("Could not join the family: \(Self.detail(error))")
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
        do {
            try await database.deleteRecord(withID: shareRecordID)
            participants = []
            isShared = false
            if membership == .member {
                membership = .owner
                zoneOwnerName = CKCurrentUserDefaultName
                changeToken = nil
                remoteStamps = [:]
                systemFields = [:]
                persistState()
                diagnostics("Left the family")
                await refresh(reason: "left family")
            } else {
                diagnostics("Stopped sharing the family")
            }
        } catch {
            diagnostics("Could not change the family share: \(Self.describe(error))")
        }
    }

    // MARK: Persistence

    private func persistState() {
        let defaults = UserDefaults.standard
        defaults.set(membership.rawValue, forKey: "cloud.membership")
        defaults.set(zoneOwnerName, forKey: "cloud.zoneOwner")
        if let changeToken, let data = try? NSKeyedArchiver.archivedData(withRootObject: changeToken, requiringSecureCoding: true) {
            defaults.set(data, forKey: "cloud.changeToken")
        } else {
            defaults.removeObject(forKey: "cloud.changeToken")
        }
        Self.saveDictionary(systemFields, "cloud-system-fields.json")
        Self.saveDictionary(remoteStamps, "cloud-remote-stamps.json")
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

    private static func loadDictionary<Value: Decodable>(_ file: String) -> [String: Value]? {
        guard let data = try? Data(contentsOf: directory.appending(path: file)) else { return nil }
        return try? decoder.decode([String: Value].self, from: data)
    }

    private static func saveDictionary<Value: Encodable>(_ dictionary: [String: Value], _ file: String) {
        if let data = try? encoder.encode(dictionary) {
            try? data.write(to: directory.appending(path: file), options: .atomic)
        }
    }

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

private extension ProfileState {
    /// Nothing favourited, played or made: the profile was never used.
    var isPristine: Bool {
        libraries.values.allSatisfy { $0.favourites.isEmpty && $0.playlists.isEmpty && $0.played.isEmpty }
    }
}
