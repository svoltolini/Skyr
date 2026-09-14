import SkyrCore
import SwiftUI

/// A profile's photo, or its initials on its colour, at any size.
struct ProfileAvatarView: View {
    let profile: Profile
    var size: CGFloat = 56
    var isLocked = false
    /// A picture not saved yet, shown while editing.
    var preview: CGImage? = nil

    var body: some View {
        let color = Color(hex: profile.avatar.colorHex)
        ZStack {
            if let image = preview ?? ProfilePhotoCache.shared.image(for: profile) {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(colors: [color.mix(with: .white, by: 0.12), color.mix(with: .black, by: 0.28)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Circle()
                    .fill(EllipticalGradient(colors: [.white.opacity(0.26), .clear], center: UnitPoint(x: 0.3, y: 0.25), startRadiusFraction: 0, endRadiusFraction: 0.6))
                Text(ProfileAvatar.initials(for: profile.name))
                    .font(.system(size: size * 0.4, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.2), radius: size * 0.03, y: size * 0.015)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(alignment: .bottomTrailing) {
            if isLocked {
                Image(systemName: "lock.fill")
                    .font(.system(size: max(9, size * 0.17), weight: .bold))
                    .foregroundStyle(Palette.onInk)
                    .frame(width: size * 0.32, height: size * 0.32)
                    .background(Palette.ink, in: Circle())
                    .overlay(Circle().strokeBorder(Palette.paper, lineWidth: 2))
                    .offset(x: size * 0.02, y: size * 0.02)
            }
        }
        .accessibilityHidden(true)
    }
}

/// Decoded profile photos, keyed by profile and photo version so a new picture replaces the old one.
final class ProfilePhotoCache {
    static let shared = ProfilePhotoCache()
    private let cache = NSCache<NSString, CGImage>()

    func image(for profile: Profile) -> CGImage? {
        guard let version = profile.avatar.photoVersion else { return nil }
        let key = "\(profile.id)|\(version)" as NSString
        if let hit = cache.object(forKey: key) { return hit }
        guard let url = ProfileStore.photoURL(for: profile.id), let image = PlatformImages.cgImage(contentsOf: url) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}
