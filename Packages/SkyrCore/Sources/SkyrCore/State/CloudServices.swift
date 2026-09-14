import CloudKit
import Foundation

struct CloudScope: Equatable {
    let account: String
    let owner: String
    let isMember: Bool

    var zoneID: CKRecordZone.ID { CKRecordZone.ID(zoneName: "Family", ownerName: owner) }
}

struct CloudChangePage {
    struct Deletion {
        let id: CKRecord.ID
        let type: String
    }
    var records: [Result<CKRecord, any Error>]
    var deletions: [Deletion] = []
    var token: Data?
    var moreComing = false
}

struct CloudModifyResult {
    var saved: [CKRecord.ID: Result<CKRecord, any Error>] = [:]
    var deleted: [CKRecord.ID: Result<Void, any Error>] = [:]
}

/// Tests supply ordinary in-memory pages; they never instantiate a CloudKit container or make requests.
struct CloudServices {
    var identity: () async throws -> String?
    var sharedZones: () async throws -> [String]
    var createZone: (CloudScope) async throws -> Void
    var subscribe: () async throws -> Void
    var changes: (CloudScope, Data?) async throws -> CloudChangePage
    var modify: (CloudScope, [CKRecord], [CKRecord.ID]) async throws -> CloudModifyResult
    var log: (String) -> Void = { _ in }

    static func live(container: CKContainer) -> CloudServices {
        func database(_ scope: CloudScope) -> CKDatabase {
            scope.isMember ? container.sharedCloudDatabase : container.privateCloudDatabase
        }
        return CloudServices(
            identity: {
                guard try await container.accountStatus() == .available else { return nil }
                return try await container.userRecordID().recordName
            },
            sharedZones: {
                try await container.sharedCloudDatabase.allRecordZones()
                    .filter { $0.zoneID.zoneName == "Family" }.map { $0.zoneID.ownerName }
            },
            createZone: { scope in _ = try await database(scope).save(CKRecordZone(zoneID: scope.zoneID)) },
            subscribe: {
                for (db, id) in [(container.privateCloudDatabase, "family-private"), (container.sharedCloudDatabase, "family-shared")] {
                    let subscription = CKDatabaseSubscription(subscriptionID: id)
                    let info = CKSubscription.NotificationInfo()
                    info.shouldSendContentAvailable = true
                    subscription.notificationInfo = info
                    _ = try await db.save(subscription)
                }
            },
            changes: { scope, data in
                let token = try data.map { try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0) }
                let page = try await database(scope).recordZoneChanges(inZoneWith: scope.zoneID, since: token ?? nil)
                return CloudChangePage(
                    records: page.modificationResultsByID.values.map { $0.map(\.record) },
                    deletions: page.deletions.map { .init(id: $0.recordID, type: $0.recordType) },
                    token: try NSKeyedArchiver.archivedData(withRootObject: page.changeToken, requiringSecureCoding: true),
                    moreComing: page.moreComing
                )
            },
            modify: { scope, records, deletions in
                let result = try await database(scope).modifyRecords(saving: records, deleting: deletions, savePolicy: .changedKeys, atomically: false)
                return CloudModifyResult(saved: result.saveResults, deleted: result.deleteResults)
            },
            log: { diagnostics($0) }
        )
    }
}
