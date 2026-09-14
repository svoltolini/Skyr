import SkyrCore
import CloudKit
import SwiftUI

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
                    SettingsGroup(title: "Reaching the server", footer: "You are connected to a local address, which members can only use on your home network. To let them listen from anywhere, give the NAS a DDNS name and connect to that instead; the family follows automatically.") {
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

                if cloud.isActive {
                    if (cloud.isOwner && cloud.isShared && permissions.canManageFamily) || (!cloud.isOwner && permissions.canLeave) {
                        SettingsGroup(footer: cloud.isOwner ? "Everyone you invited loses access to the family's profiles." : "Your profile stays on this device; the family's profiles go.") {
                            SettingsButtonRow(symbol: cloud.isOwner ? "xmark.circle" : "rectangle.portrait.and.arrow.right", tint: .red, title: cloud.isOwner ? "Stop sharing" : "Leave family", role: .destructive) {
                                isConfirmingStop = true
                            }
                        }
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
                    await cloud.stopSharing()
                    // Devices that had the family account should not keep working.
                    if cloud.isOwner, model.familyAccess != nil { _ = await model.rotateFamilyAccess() }
                }
            }
        }
        .confirmationDialog("Remove family access?", isPresented: $isConfirmingRemoveAccess, titleVisibility: .visible) {
            Button("Remove", role: .destructive) {
                Task {
                    isWorkingOnAccess = true
                    await model.removeFamilyAccess()
                    isWorkingOnAccess = false
                }
            }
        } message: {
            Text("Members lose their connection to the server until you set it up again.")
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
            ? "One read-only account on the NAS is shared by everyone in the family, however many people join. Nobody sees your password, and nobody types anything. The app can make it for you on a NAS that allows it; otherwise add it yourself in a minute."
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
                SettingsButtonRow(symbol: "key.fill", tint: .green, title: isWorkingOnAccess ? "Setting up…" : "Set up family access") {
                    Task {
                        isWorkingOnAccess = true
                        problem = await model.setUpFamilyAccess()
                        isWorkingOnAccess = false
                    }
                }
                .disabled(isWorkingOnAccess)
                SettingsButtonRow(symbol: "person.text.rectangle", tint: .indigo, title: "Add an account yourself") {
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
                    SettingsGroup(title: "In DSM", footer: "One account covers the whole family, so you only do this once. Open DSM in a browser on your Mac or PC, follow these steps, then enter it below.") {
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
