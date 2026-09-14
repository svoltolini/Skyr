import SkyrCore
import SwiftUI

/// "Who's listening?": the family's profiles in a row, Netflix style. Covers the app until one opens.
/// On the Mac it is a screen of its own with no window chrome; on the phone it lies over the tabs.
struct ProfilePickerView: View {
    @Environment(ProfileStore.self) private var profiles
    @State private var unlocking: Profile?
    @Environment(\.isWideLayout) private var isWide

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 20), count: 3)

    var body: some View {
        ZStack {
            TintedBackground(tint: Palette.neutralTint)
            VStack(spacing: 0) {
                Spacer()
                Text("Who's listening?")
                    .font(titleFont)
                    .kerning(-0.6)
                tiles
                    .padding(.horizontal, 32)
                    .padding(.top, 36)
                Spacer()
                Spacer()
            }
        }
        .bareWindow()
        .sheet(item: $unlocking) { profile in
            UnlockSheet(profile: profile)
        }
    }

    private var titleFont: Font {
        #if os(macOS)
        .system(size: 40, weight: .bold)
        #elseif os(tvOS)
        .system(size: 64, weight: .bold)
        #else
        isWide ? .system(size: 40, weight: .bold) : .largeTitle.weight(.bold)
        #endif
    }

    /// A single centred row wherever it fits; the phone wraps into a grid from four profiles on.
    @ViewBuilder
    private var tiles: some View {
        #if os(macOS)
        HStack(alignment: .top, spacing: 48) {
            ForEach(profiles.profiles) { profile in
                ProfileTile(profile: profile, avatarSize: 132, width: 168) { pick(profile) }
            }
        }
        #elseif os(tvOS)
        HStack(alignment: .top, spacing: 80) {
            ForEach(profiles.profiles) { profile in
                ProfileTile(profile: profile, avatarSize: 220, width: 280) { pick(profile) }
            }
        }
        #else
        if isWide {
            HStack(alignment: .top, spacing: 48) {
                ForEach(profiles.profiles) { profile in
                    ProfileTile(profile: profile, avatarSize: 132, width: 168) { pick(profile) }
                }
            }
        } else if profiles.profiles.count <= 3 {
            HStack(alignment: .top, spacing: 28) {
                ForEach(profiles.profiles) { profile in
                    ProfileTile(profile: profile, avatarSize: 92, width: 104) { pick(profile) }
                }
            }
        } else {
            LazyVGrid(columns: columns, spacing: 30) {
                ForEach(profiles.profiles) { profile in
                    ProfileTile(profile: profile, avatarSize: 92, width: nil) { pick(profile) }
                }
            }
        }
        #endif
    }

    private func pick(_ profile: Profile) {
        if profiles.activate(profile) { return }
        if profiles.biometricsEnabled(for: profile) {
            Task {
                if !(await profiles.unlockWithBiometrics(profile)) {
                    unlocking = profile
                }
            }
        } else {
            unlocking = profile
        }
    }
}

/// What the editor sheet opens for. Profiles are never added by hand: everyone who joins the
/// family brings their own, so the editor only ever opens an existing one.
enum ProfileEditorTarget: Identifiable {
    case existing(Profile)

    var id: String {
        switch self {
        case .existing(let profile): profile.id
        }
    }

    var profile: Profile? {
        if case .existing(let profile) = self { return profile }
        return nil
    }
}

private struct ProfileTile: View {
    let profile: Profile
    var avatarSize: CGFloat = 92
    /// A fixed width keeps a short row tight; nil lets a grid cell decide.
    var width: CGFloat?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ProfileAvatarView(profile: profile, size: avatarSize, isLocked: profile.isLocked)
                    .shadow(color: .black.opacity(isHovering ? 0.22 : 0.12), radius: isHovering ? 18 : 10, y: isHovering ? 10 : 6)
                    .scaleEffect(isHovering ? 1.06 : 1)
                Text(profile.name)
                    .font(nameFont)
                    .lineLimit(1)
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .onHover { hovering in
            withAnimation(.spring(duration: 0.28, bounce: 0.2)) { isHovering = hovering }
        }
        .accessibilityLabel(profile.isLocked ? "\(profile.name), locked" : profile.name)
    }

    private var nameFont: Font {
        #if os(macOS)
        .title3.weight(.semibold)
        #elseif os(tvOS)
        .title2.weight(.semibold)
        #else
        .headline
        #endif
    }
}
