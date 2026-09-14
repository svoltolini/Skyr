import SkyrCore
import SwiftUI

/// Who may do what. The host is the owner profile on a device signed in with the family's Apple
/// Account; everyone else, including a child's profile opened on the host's own iPad, is a member.
struct Permissions {
    /// The device belongs to the family's owner and the owner profile is open.
    let isHost: Bool
    /// The open profile is the one bound to this device's Apple Account.
    let isSelf: Bool

    init(profiles: ProfileStore, cloud: CloudSync) {
        let active = profiles.active
        isHost = cloud.isOwner && active?.role == .owner
        isSelf = active?.userRecordName != nil && active?.userRecordName == cloud.currentUserRecordName
    }

    /// Music folder, reconnect, sign out.
    var canManageServer: Bool { isHost }
    /// Invite people, stop sharing.
    var canManageFamily: Bool { isHost }
    /// Delete profiles and change other people's names, photos and PINs.
    var canManageProfiles: Bool { isHost }
    /// Leave the family or sign out of the server from one's own device.
    var canLeave: Bool { isHost || isSelf }

    func canEdit(_ profile: Profile, profiles: ProfileStore) -> Bool {
        canManageProfiles || profile.id == profiles.activeID
    }
}
