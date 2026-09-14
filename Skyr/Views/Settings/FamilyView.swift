import SkyrCore
import CloudKit
import SwiftUI

#if os(tvOS)
/// The family's plumbing: iCloud sync, the NAS account members connect with, and leaving. Who is
/// in the family, and inviting, live on the Profiles screen, since everyone who joins is a profile.
struct FamilyView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(ProfileStore.self) private var profiles
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model
    @State private var isWorkingOnAccess = false
    @State private var isEnteringAccount = false
    @State private var isConfirmingRemoveAccess = false
    @State private var isConfirmingStop = false
    @State private var isJoiningWithLink = false
    @State private var problem: String?

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                SettingsGroup(title: "iCloud", footer: footer) {
                    SettingsRow(symbol: "icloud.fill", tint: .blue, title: "Sync") {
                        SettingsValue(cloud.status.text)
                    }
                }

                if permissions.canManageFamily, model.connection?.isHomeOnly == true {
                    SettingsGroup(title: "Reaching the server", footer: "Members need a route to this NAS. Tailscale is an optional way to connect remotely. When you change the server address or owner account, verify family access again for that connection.") {
                        SettingsRow(symbol: "house.fill", tint: .orange, title: "Home network only") {
                            EmptyView()
                        }
                    }
                }

                if cloud.isActive, permissions.canManageFamily, !model.isDemo {
                    familyAccessGroup
                }

                #if !os(tvOS)
                if (cloud.isActive && cloud.isOwner && !cloud.isShared) || cloud.needsFamilyInvitation {
                    SettingsGroup(title: cloud.needsFamilyInvitation ? "Reconnect with your family" : "Joining someone else's family", footer: "Invitations are icloud.com/share links made in Skyr. Opening one on this device normally joins straight away; if it opened in a browser instead, paste it here. Any Apple Account can join, wherever it lives; Family Sharing is not needed.") {
                        SettingsButtonRow(symbol: "link", tint: .blue, title: "Join with an invitation link") {
                            isJoiningWithLink = true
                        }
                    }
                }
                #endif

                if cloud.isActive || (model.familyRevocationPending && cloud.currentUserRecordName != nil) {
                    if (cloud.isOwner && (cloud.isShared || model.familyRevocationPending) && permissions.canManageFamily) || (!cloud.isOwner && permissions.canLeave) {
                        SettingsGroup(footer: cloud.isOwner ? "Everyone you invited loses access to the family's profiles." : "Your profile stays on this device; the family's profiles go.") {
                            SettingsButtonRow(symbol: cloud.isOwner ? "xmark.circle" : "rectangle.portrait.and.arrow.right", tint: .red, title: model.familyRevocationPending ? "Finish stopping sharing" : (cloud.isOwner ? "Stop sharing" : "Leave family"), role: .destructive) {
                                isConfirmingStop = true
                            }
                        }
                        .disabled(isWorkingOnAccess)
                    }
                }

                if let problem {
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .skyrBackground(player.tint)
        .navigationTitle("Family")
        .inlineTitle()
        .pullToRefresh { await cloud.refresh(reason: "pull") }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await cloud.refresh(reason: "toolbar") } }
            }
            #endif
        }
        .confirmationDialog(cloud.isOwner ? "Stop sharing the family?" : "Leave the family?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button(cloud.isOwner ? "Stop sharing" : "Leave", role: .destructive) {
                Task {
                    isWorkingOnAccess = true
                    problem = await model.stopFamilySharing(using: cloud)
                    isWorkingOnAccess = false
                }
            }
        }
        .confirmationDialog("Remove family access?", isPresented: $isConfirmingRemoveAccess, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    isWorkingOnAccess = true
                    problem = await model.removeFamilyAccess()
                    isWorkingOnAccess = false
                }
            }
        } message: {
            Text("Skyr will ask the NAS to remove the family account. Access remains until the NAS confirms removal. Existing sessions and files already downloaded may remain available.")
        }
        .sheet(isPresented: $isEnteringAccount) {
            FamilyAccountSheet()
        }
        .sheet(isPresented: $isJoiningWithLink) {
            JoinWithLinkSheet()
        }
    }

    /// The read-only NAS account members connect with, made by the app or entered by hand.
    private var familyAccessGroup: some View {
        SettingsGroup(title: "Family access", footer: model.familyAccess == nil
            ? "Use a separate read-only NAS account for the family. Skyr can create one on a NAS that allows it, or you can enter an existing account. Its credentials are shared through iCloud with people who join using your invitation link."
            : "Everyone in the family connects with this one account, on every device, without signing in. Rotate the password if a device should stop working.") {
            if let access = model.familyAccess {
                SettingsRow(symbol: "key.fill", tint: .green, title: "Family access") {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .accessibilityLabel("Ready, account \(access.account)")
                }
                SettingsButtonRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: isWorkingOnAccess ? "Working…" : "Rotate password") {
                    Task {
                        isWorkingOnAccess = true
                        problem = await model.rotateFamilyAccess()
                        isWorkingOnAccess = false
                    }
                }
                .disabled(isWorkingOnAccess)
                SettingsButtonRow(symbol: "key.slash", tint: .red, title: "Remove family access", role: .destructive) {
                    isConfirmingRemoveAccess = true
                }
                .disabled(isWorkingOnAccess)
            } else {
                if model.familyAccessNeedsVerification {
                    Text("An earlier family account needs verification for this connection. Use its existing name and password below. Your previous setup is still kept.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .padding(16)
                }
                SettingsButtonRow(symbol: "key.fill", tint: .green, title: isWorkingOnAccess ? "Setting up…" : "Set up family access") {
                    Task {
                        isWorkingOnAccess = true
                        problem = await model.setUpFamilyAccess()
                        isWorkingOnAccess = false
                    }
                }
                .disabled(isWorkingOnAccess || model.familyRevocationPending)
                SettingsButtonRow(symbol: "person.text.rectangle", tint: .indigo, title: "Use an existing account") {
                    isEnteringAccount = true
                }
            }
        }
    }

    private var footer: String {
        switch cloud.status {
        case .noAccount: "Sign in to iCloud in the Settings app to sync profiles across your devices and share them with your family."
        case .failed: Hints.familyRetry
        default: "Profiles, favourites, playlists and settings follow you to every device signed in with your Apple Account."
        }
    }
}

#else
/// Native preferences for iCloud, the shared NAS account, and membership.
struct FamilyView: View {
    @Environment(CloudSync.self) private var cloud
    @Environment(ProfileStore.self) private var profiles
    @Environment(AppModel.self) private var model
    @State private var isWorkingOnAccess = false
    @State private var isEnteringAccount = false
    @State private var isConfirmingRemoveAccess = false
    @State private var isConfirmingStop = false
    @State private var isJoiningWithLink = false
    @State private var problem: String?

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        Form {
            Section {
                LabeledContent("Sync", value: cloud.status.text)
            } header: {
                Text("iCloud")
            } footer: {
                Text(footer)
            }
            if permissions.canManageFamily, model.connection?.isHomeOnly == true {
                Section {
                    Label("Home network only", systemImage: "house")
                } header: {
                    Text("Reaching the server")
                } footer: {
                    Text("Members need a route to this NAS. Tailscale is an optional way to connect remotely. When you change the server address or owner account, verify family access again for that connection.")
                }
            }
            if cloud.isActive, permissions.canManageFamily, !model.isDemo { familyAccessSection }
            if (cloud.isActive && cloud.isOwner && !cloud.isShared) || cloud.needsFamilyInvitation {
                Section {
                    Button("Join with an invitation link", systemImage: "link") { isJoiningWithLink = true }
                } header: {
                    Text(cloud.needsFamilyInvitation ? "Reconnect with your family" : "Joining someone else's family")
                } footer: {
                    Text("Invitations are icloud.com/share links made in Skyr. Opening one on this device normally joins straight away; if it opened in a browser instead, paste it here. Any Apple Account can join, wherever it lives; Family Sharing is not needed.")
                }
            }
            if cloud.isActive || (model.familyRevocationPending && cloud.currentUserRecordName != nil) {
                if (cloud.isOwner && (cloud.isShared || model.familyRevocationPending) && permissions.canManageFamily) || (!cloud.isOwner && permissions.canLeave) {
                    Section {
                        Button(model.familyRevocationPending ? "Finish stopping sharing" : (cloud.isOwner ? "Stop sharing" : "Leave family"), role: .destructive) { isConfirmingStop = true }
                            .disabled(isWorkingOnAccess)
                    } footer: {
                        Text(cloud.isOwner ? "Everyone who joined loses access to the family's profiles." : "Your profile stays on this device; the family's profiles go.")
                    }
                }
            }
            if let problem {
                Section { Text(problem).font(.callout).foregroundStyle(.red) }
            }
        }
        .groupedForm()
        .navigationTitle("Family")
        .inlineTitle()
        .pullToRefresh { await cloud.refresh(reason: "pull") }
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await cloud.refresh(reason: "toolbar") } }
            }
            #endif
        }
        .confirmationDialog(cloud.isOwner ? "Stop sharing the family?" : "Leave the family?", isPresented: $isConfirmingStop, titleVisibility: .visible) {
            Button(cloud.isOwner ? "Stop sharing" : "Leave", role: .destructive) {
                Task {
                    isWorkingOnAccess = true
                    problem = await model.stopFamilySharing(using: cloud)
                    isWorkingOnAccess = false
                }
            }
        }
        .confirmationDialog("Remove family access?", isPresented: $isConfirmingRemoveAccess, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    isWorkingOnAccess = true
                    problem = await model.removeFamilyAccess()
                    isWorkingOnAccess = false
                }
            }
        } message: {
            Text("Skyr will ask the NAS to remove the family account. Access remains until the NAS confirms removal. Existing sessions and files already downloaded may remain available.")
        }
        .sheet(isPresented: $isEnteringAccount) { FamilyAccountSheet() }
        .sheet(isPresented: $isJoiningWithLink) { JoinWithLinkSheet() }
    }

    private var familyAccessSection: some View {
        Section {
            if let access = model.familyAccess {
                LabeledContent("Account", value: access.account)
                LabeledContent("Status", value: "Ready")
                Button(isWorkingOnAccess ? "Working…" : "Rotate password", systemImage: "arrow.triangle.2.circlepath") {
                    Task {
                        isWorkingOnAccess = true
                        problem = await model.rotateFamilyAccess()
                        isWorkingOnAccess = false
                    }
                }
                .disabled(isWorkingOnAccess)
                Button("Remove family access", role: .destructive) { isConfirmingRemoveAccess = true }
                    .disabled(isWorkingOnAccess)
            } else {
                if model.familyAccessNeedsVerification {
                    Text("An earlier family account needs verification for this connection. Use its existing name and password below. Your previous setup is still kept.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Button(isWorkingOnAccess ? "Setting up…" : "Set up family access", systemImage: "key") {
                    Task {
                        isWorkingOnAccess = true
                        problem = await model.setUpFamilyAccess()
                        isWorkingOnAccess = false
                    }
                }
                .disabled(isWorkingOnAccess || model.familyRevocationPending)
                Button("Use an existing account", systemImage: "person.text.rectangle") { isEnteringAccount = true }
            }
        } header: {
            Text("Family access")
        } footer: {
            Text(model.familyAccess == nil
                 ? "Use a separate read-only NAS account for the family. Skyr can create one on a NAS that allows it, or you can enter an existing account. Its credentials are shared through iCloud with people who join using your invitation link."
                 : "Everyone in the family connects with this one account, on every device, without signing in. Rotate the password if a device should stop working.")
        }
    }

    private var footer: String {
        switch cloud.status {
        case .noAccount:
            #if os(macOS)
            "Sign in to iCloud in System Settings to sync profiles across your devices and share them with your family."
            #else
            "Sign in to iCloud in the Settings app to sync profiles across your devices and share them with your family."
            #endif
        case .failed: Hints.familyRetry
        default: "Profiles, favourites, playlists and settings follow you to every device signed in with your Apple Account."
        }
    }
}

#endif

struct ShareItem: Identifiable {
    let id = UUID()
    let share: CKShare
}

/// One step of a DSM walkthrough.
struct InstructionRow: View {
    let number: Int
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text("\(number)")
                .font(.footnote.weight(.bold))
                .foregroundStyle(Palette.onInk)
                .frame(width: 24, height: 24)
                .background(Palette.ink, in: Circle())
            Text(text)
                .font(.subheadline)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

#if os(tvOS)
/// An account the owner made in DSM by hand, checked with a sign-in before it is kept.
private struct FamilyAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var isChecking = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    SettingsGroup(title: "In DSM", footer: "If you already have a family account, verify its read-only permissions and enter it below. To create one, open DSM on your Mac or PC and follow these steps.") {
                        InstructionRow(number: 1, text: "Go to Control Panel, then User & Group, and select Create.")
                        InstructionRow(number: 2, text: "Name it skyr-family and give it a password you won't need to remember. This one account is for everyone, not one per person.")
                        InstructionRow(number: 3, text: "On the permissions step, give it Read only on your music folder and no access to everything else.")
                        InstructionRow(number: 4, text: "On the applications step, allow File Station and deny the rest.")
                        InstructionRow(number: 5, text: "Finish, then type the name and password here.")
                    }
                    SettingsGroup(footer: "Skyr checks the account by signing in once, then shares it with your family through iCloud, encrypted, so nobody has to type it.") {
                        HStack(spacing: 14) {
                            SettingsIcon(symbol: "person.fill", tint: .indigo)
                            TextField("Account", text: $account)
                                .noAutocapitalization()
                                .autocorrectionDisabled()
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        HStack(spacing: 14) {
                            SettingsIcon(symbol: "key.fill", tint: .green)
                            SecureField("Password", text: $password)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                    if let problem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.horizontal, 12)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
            }
            .background(Palette.paper)
            .navigationTitle("Family Account")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChecking ? "Checking…" : "Use") {
                        Task {
                            isChecking = true
                            problem = await model.useFamilyAccess(account: account.trimmingCharacters(in: .whitespaces), password: password)
                            isChecking = false
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isChecking)
                }
            }
        }
    }
}

#else
/// A separate NAS account, verified before Skyr stores or shares its credentials.
private struct FamilyAccountSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var isChecking = false
    @State private var problem: String?

    private let instructions = [
        "Go to Control Panel, then User & Group, and select Create.",
        "Name it skyr-family and give it a password. This one account is for everyone, not one per person.",
        "On the permissions step, give it Read only on your music folder and no access to everything else.",
        "On the applications step, allow File Station and deny the rest.",
        "Finish, then enter the name and password below."
    ]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(Array(instructions.enumerated()), id: \.offset) { index, instruction in
                        HStack(alignment: .top) {
                            Text("\(index + 1).")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                            Text(instruction).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                } header: {
                    Text("In DSM")
                } footer: {
                    Text("If you already have a family account, verify its read-only permissions and enter it below. To create one, open DSM on your Mac or PC and follow these steps.")
                }
                Section {
                    TextField("Account", text: $account)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                    SecureField("Password", text: $password)
                } header: {
                    Text("NAS account")
                } footer: {
                    Text("Skyr checks the account by signing in once, then shares the chosen credentials with your family through iCloud. The password is stored in an encrypted CloudKit field.")
                }
                if let problem {
                    Section { Text(problem).font(.callout).foregroundStyle(.red) }
                }
            }
            .groupedForm()
            .navigationTitle("Family Account")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isChecking ? "Checking…" : "Use") {
                        Task {
                            isChecking = true
                            problem = await model.useFamilyAccess(account: account.trimmingCharacters(in: .whitespaces), password: password)
                            isChecking = false
                            if problem == nil { dismiss() }
                        }
                    }
                    .disabled(account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isChecking)
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 480, idealHeight: 580)
        #endif
    }
}
#endif
