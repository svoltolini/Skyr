import SkyrCore
import SwiftUI

/// "Who's listening?": the family's profiles in a centred, wrapping grid until one opens.
/// On the Mac it is a screen of its own with no window chrome; on the phone it lies over the tabs.
struct ProfilePickerView: View {
    @Environment(ProfileStore.self) private var profiles
    @State private var unlocking: Profile?
    @Environment(\.isWideLayout) private var isWide
    @ScaledMetric(relativeTo: .headline) private var compactTileWidth: CGFloat = 104
    @ScaledMetric(relativeTo: .headline) private var wideTileWidth: CGFloat = 168
    @ScaledMetric(relativeTo: .largeTitle) private var wideTitleSize: CGFloat = 40

    var body: some View {
        ZStack {
            TintedBackground(tint: Palette.neutralTint)
            // The picker owns the full screen. Its viewport supplies both the wrapping width
            // and minimum content height; taller names or smaller windows remain scrollable.
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                        Text("Who's listening?")
                            .font(titleFont)
                            .kerning(-0.6)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityAddTraits(.isHeader)
                        tiles(availableWidth: max(0, geometry.size.width - horizontalPadding * 2))
                            .padding(.top, 36)
                        Spacer(minLength: 0)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, horizontalPadding)
                    .frame(minHeight: max(0, geometry.size.height - verticalPadding * 2))
                    .padding(.vertical, verticalPadding)
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        }
        .bareWindow()
        .sheet(item: $unlocking) { profile in
            UnlockSheet(profile: profile)
        }
    }

    private var titleFont: Font {
        #if os(macOS)
        .system(size: wideTitleSize, weight: .bold)
        #elseif os(tvOS)
        .system(size: wideTitleSize * 1.6, weight: .bold)
        #else
        isWide ? .system(size: wideTitleSize, weight: .bold) : .largeTitle.weight(.bold)
        #endif
    }

    /// Keep one collection of buttons across resizes so changing columns preserves identity.
    private func tiles(availableWidth: CGFloat) -> some View {
        let metrics = tileMetrics
        let count = max(1, profiles.profiles.count)
        let fittingColumns = max(1, Int((availableWidth + metrics.spacing) / (metrics.minimumWidth + metrics.spacing)))
        let maximumColumns = min(count, min(metrics.maximumColumns, fittingColumns))
        let rows = (count + maximumColumns - 1) / maximumColumns
        let columns = (count + rows - 1) / rows
        let width = min(metrics.width, max(1, (availableWidth - CGFloat(columns - 1) * metrics.spacing) / CGFloat(columns)))
        return LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(width), spacing: metrics.spacing, alignment: .top), count: columns),
            spacing: metrics.spacing
        ) {
            ForEach(profiles.profiles) { profile in
                ProfileTile(profile: profile, avatarSize: min(metrics.avatarSize, width), width: width) { pick(profile) }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var tileMetrics: (width: CGFloat, minimumWidth: CGFloat, avatarSize: CGFloat, spacing: CGFloat, maximumColumns: Int) {
        #if os(tvOS)
        (wideTileWidth * 5 / 3, wideTileWidth * 5 / 3, 220, 80, 6)
        #elseif os(macOS)
        (wideTileWidth, wideTileWidth, 132, 48, 6)
        #else
        isWide
            ? (wideTileWidth, wideTileWidth, 132, 48, 6)
            : (compactTileWidth, compactTileWidth * 92 / 104, 92, 20, 3)
        #endif
    }

    private var horizontalPadding: CGFloat {
        #if os(tvOS)
        48
        #else
        32
        #endif
    }

    private var verticalPadding: CGFloat {
        #if os(tvOS)
        60
        #else
        32
        #endif
    }

    private func pick(_ profile: Profile) {
        if profiles.activate(profile) { return }
        // Without a PIN, only an unreadable document keeps a profile closed; the keypad cannot
        // help with that, and the store's alert offers the way in.
        guard profile.isLocked else { return }
        if profiles.biometricsEnabled(for: profile) {
            Task {
                if !(await profiles.unlockWithBiometrics(profile)), !profiles.canOpenWithoutSavedData(profile) {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Button(action: action) {
            VStack(spacing: 14) {
                ProfileAvatarView(profile: profile, size: avatarSize, isLocked: profile.isLocked)
                    .shadow(color: .black.opacity(isHovering ? 0.22 : 0.12), radius: isHovering ? 18 : 10, y: isHovering ? 10 : 6)
                    .scaleEffect(isHovering && !reduceMotion ? 1.06 : 1)
                Text(profile.name)
                    .font(nameFont)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(width: width)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .contentShape(Rectangle())
        }
        .buttonStyle(TransportButtonStyle())
        .onHover { hovering in
            withAnimation(reduceMotion ? .easeOut(duration: 0.15) : .spring(duration: 0.28, bounce: 0.2)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isButton)
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
