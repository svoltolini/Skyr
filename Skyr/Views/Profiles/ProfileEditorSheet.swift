#if canImport(PhotosUI) && !os(tvOS)
import PhotosUI
#endif
import CloudKit
import SkyrCore
import SwiftUI

/// Name, photo and lock of a profile; new ones are made here too.
struct ProfileEditorSheet: View {
    let profile: Profile?
    @Environment(ProfileStore.self) private var profiles
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var avatar: ProfileAvatar
    @State private var pinChange: PINChange = .keep
    @State private var photoChange: PhotoChange = .keep
    #if canImport(PhotosUI) && !os(tvOS)
    @State private var pickedItem: PhotosPickerItem?
    #endif
    @State private var preview: CGImage?
    @State private var biometrics: Bool
    @State private var isSettingPIN = false
    @State private var isConfirmingDelete = false
    @State private var problem: String?
    @State private var openingSession: UUID?

    private enum PINChange { case keep, set(String), remove }
    private enum PhotoChange {
        case keep, set(Data), remove

        var isRemove: Bool {
            if case .remove = self { return true }
            return false
        }
    }

    init(profile: Profile?) {
        self.profile = profile
        _name = State(initialValue: profile?.name ?? "")
        _avatar = State(initialValue: profile?.avatar ?? ProfileAvatar.random())
        _biometrics = State(initialValue: false)
    }

    /// What the avatar shows while editing: the picked picture, the saved one, or initials.
    private var draft: Profile {
        Profile(
            id: profile?.id ?? "new", name: name.isEmpty ? "?" : name,
            avatar: photoChange.isRemove ? ProfileAvatar(symbol: avatar.symbol, colorHex: avatar.colorHex) : avatar,
            pin: nil, role: .member, createdAt: .now, updatedAt: .now
        )
    }

    private var hasPhoto: Bool {
        switch photoChange {
        case .keep: avatar.hasPhoto
        case .set: true
        case .remove: false
        }
    }

    private var hasPIN: Bool {
        switch pinChange {
        case .keep: profile?.isLocked ?? false
        case .set: true
        case .remove: false
        }
    }

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && isCurrentDraft
    }

    private var isCurrentDraft: Bool {
        guard let openingSession, profiles.sessionID == openingSession else { return false }
        return profile.map { profiles.canEditDraft($0, session: openingSession) } ?? profiles.canManageProfiles
    }

    private func validateDraft() -> Bool {
        guard isCurrentDraft else {
            problem = "This profile or session changed. Close this editor and open it again."
            return false
        }
        return true
    }

    var body: some View {
        let photoLabel = hasPhoto ? "Change Photo" : "Choose Photo"
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    VStack(spacing: 14) {
                        ProfileAvatarView(profile: draft, size: 124, isLocked: hasPIN, preview: photoChange.isRemove ? nil : preview)
                            .animation(.snappy(duration: 0.25), value: preview.map(ObjectIdentifier.init))
                        #if canImport(PhotosUI) && !os(tvOS)
                        PhotosPicker(selection: $pickedItem, matching: .images, photoLibrary: .shared()) {
                            Label(photoLabel, systemImage: "photo")
                        }
                        .buttonStyle(.glass)
                        #else
                        Text("Change the photo from your iPhone or Mac.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        #endif
                    }
                    .padding(.top, 8)

                    SettingsGroup {
                        HStack(spacing: 14) {
                            SettingsIcon(symbol: "person.fill", tint: Color(hex: avatar.colorHex))
                            TextField("Name", text: $name)
                                .wordsAutocapitalization()
                                .submitLabel(.done)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }

                    SettingsGroup(title: "Lock", footer: hasPIN ? "The PIN is asked for before this profile opens on any device." : "Without a PIN anyone using this device can open the profile.") {
                        if hasPIN {
                            SettingsRow(symbol: "lock.fill", tint: .orange, title: "PIN") {
                                Text("••••")
                                    .foregroundStyle(.secondary)
                            }
                            SettingsButtonRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: "Change PIN") { isSettingPIN = true }
                            SettingsButtonRow(symbol: "lock.open", tint: .red, title: "Remove PIN", role: .destructive) {
                                pinChange = .remove
                                biometrics = false
                            }
                            if let biometry = profiles.biometryName {
                                SettingsRow(symbol: biometry == "Face ID" ? "faceid" : "touchid", tint: .green, title: "Open with \(biometry)") {
                                    Toggle("Open with \(biometry)", isOn: $biometrics)
                                        .labelsHidden()
                                }
                            }
                        } else {
                            SettingsButtonRow(symbol: "lock.fill", tint: .orange, title: "Set a PIN") { isSettingPIN = true }
                        }
                    }

                    if let profile, cloud.isActive, let user = cloud.currentUserRecordName {
                        SettingsGroup(title: "iCloud", footer: profile.userRecordName == user ? "Opens on its own on every device signed in with your Apple Account." : "Makes this the profile your own devices open first.") {
                            if profile.userRecordName == user {
                                SettingsRow(symbol: "icloud.fill", tint: .blue, title: "This is you") { EmptyView() }
                            } else {
                                SettingsButtonRow(symbol: "icloud.fill", tint: .blue, title: "Use on my Apple Account") {
                                    guard validateDraft() else { return }
                                    if profiles.bindToCurrentUser(profile) { dismiss() }
                                    else { problem = "Open your profile before making changes." }
                                }
                            }
                        }
                    }

                    if let profile, profiles.profiles.count > 1, Permissions(profiles: profiles, cloud: cloud).canManageProfiles {
                        SettingsGroup {
                            SettingsButtonRow(symbol: "trash", tint: .red, title: "Delete Profile", role: .destructive) { isConfirmingDelete = true }
                        }
                        .confirmationDialog("Delete “\(profile.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                            Button("Delete Profile", role: .destructive) {
                                guard validateDraft() else { return }
                                if profiles.delete(profile) { dismiss() }
                                else { problem = "Open the owner's profile to delete a profile." }
                            }
                        } message: {
                            Text("Its favourites, playlists and history on this device go with it.")
                        }
                    }
                    if let problem {
                        Text(problem)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
            .background(Palette.paper)
            .navigationTitle(profile == nil ? "New Profile" : "Edit Profile")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(!canSave)
                }
            }
            .onAppear {
                if openingSession == nil { openingSession = profiles.sessionID }
                if let profile { biometrics = profiles.biometricsEnabled(for: profile) }
            }
            #if canImport(PhotosUI) && !os(tvOS)
            .onChange(of: pickedItem) { _, item in
                guard let item else { return }
                Task {
                    guard let data = try? await item.loadTransferable(type: Data.self), let image = PlatformImages.cgImage(data: data) else { return }
                    photoChange = .set(data)
                    preview = image
                }
            }
            #endif
            .sheet(isPresented: $isSettingPIN) {
                PINSetupSheet { pin in pinChange = .set(pin) }
            }
        }
    }

    private func save() {
        guard validateDraft() else { return }
        guard canSave else {
            problem = "Open your profile before saving changes."
            return
        }
        let newPIN: String? = if case .set(let pin) = pinChange { pin } else { nil }
        var saved: Profile?
        if let profile {
            guard var updated = profiles.profiles.first(where: { $0.id == profile.id }) else {
                problem = "This profile is no longer available."
                return
            }
            updated.name = name
            updated.avatar = avatar
            switch pinChange {
            case .keep: break
            case .set(let pin): updated.pin = PINRecord.make(pin)
            case .remove: updated.pin = nil
            }
            guard profiles.update(updated) else {
                problem = "This profile changed. Open it again to save your changes."
                return
            }
            profiles.setBiometrics(biometrics && updated.isLocked, for: updated)
            saved = profiles.profiles.first { $0.id == profile.id }
        } else if let created = profiles.create(name: name, avatar: avatar, pin: newPIN) {
            profiles.setBiometrics(biometrics && created.isLocked, for: created)
            saved = created
        }
        guard let saved else {
            problem = "The profile could not be saved."
            return
        }
        switch photoChange {
        case .keep: break
        case .set(let data): profiles.setPhoto(data, for: saved)
        case .remove: profiles.setPhoto(nil, for: saved)
        }
        dismiss()
    }
}


/// Settings page listing every profile on this device.
struct ManageProfilesView: View {
    @Environment(ProfileStore.self) private var profiles
    @Environment(PlayerModel.self) private var player
    @Environment(CloudSync.self) private var cloud
    @State private var editing: ProfileEditorTarget?
    @State private var share: ShareItem?
    @State private var isPreparingShare = false
    @State private var problem: String?

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                SettingsGroup(footer: footer) {
                    ForEach(profiles.profiles) { profile in
                        Button {
                            editing = .existing(profile)
                        } label: {
                            HStack(spacing: 14) {
                                ProfileAvatarView(profile: profile, size: 44, isLocked: profile.isLocked)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(profile.name)
                                        .font(.body.weight(.medium))
                                    Text(profile.role == .owner ? "Owner" : "Member")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if profile.id == profiles.activeID {
                                    Text("Now")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                }
                                if permissions.canEdit(profile, profiles: profiles) {
                                    DisclosureChevron()
                                }
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 12)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(RowPressStyle())
                        .disabled(!permissions.canEdit(profile, profiles: profiles))
                    }
                    // People who have an invitation but have not opened it yet.
                    ForEach(cloud.participants.filter { !$0.accepted }) { participant in
                        SettingsRow(symbol: "person.badge.clock", tint: .gray, title: participant.name, subtitle: "Invited, not joined yet") {
                            EmptyView()
                        }
                    }
                    if cloud.isActive, permissions.canManageFamily {
                        SettingsButtonRow(symbol: "person.badge.plus", tint: .blue, title: isPreparingShare ? "Preparing…" : "Invite someone") {
                            invite()
                        }
                        .disabled(isPreparingShare)
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
        .navigationTitle("Profiles")
        .inlineTitle()
        .sheet(item: $editing) { target in
            ProfileEditorSheet(profile: target.profile)
        }
        .sheet(item: $share, onDismiss: { Task { await cloud.refresh(reason: "invite sheet closed") } }) { item in
            InviteSheet(share: item.share)
        }
    }

    private var footer: String {
        guard permissions.canManageProfiles else { return "You can change your own profile. The family's owner manages the others." }
        let everyone = "Everyone who joins appears here with their own favourites, playlists, history, downloads and settings."
        return cloud.isActive ? "Up to five people can join. " + everyone : "Sign in to iCloud in the Settings app to invite your family. " + everyone
    }

    /// The owner's invitation link, through the system share sheet.
    private func invite() {
        isPreparingShare = true
        problem = nil
        Task {
            do {
                share = ShareItem(share: try await cloud.share())
            } catch {
                problem = error.localizedDescription
            }
            isPreparingShare = false
        }
    }
}
