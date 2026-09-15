import SkyrCore
import SwiftUI

/// One screen of the introduction.
struct OnboardingPage: Identifiable {
    let id: Int
    let title: String
    let text: String
    /// The paper's tint while this page shows; it drifts from one page to the next.
    let tint: Color

    /// What Skyr does with a person's music and sign-in, told before anything is asked of them.
    /// NAS playback, iCloud sharing and source artwork are explained separately.
    static var privacy: [OnboardingPage] {
        [
            OnboardingPage(
                id: 0,
                title: "Your music stays\nwhere it is.",
                text: "Skyr plays straight from the Synology you already own. Music stays on your NAS or downloads to your devices. Skyr does not upload your music files to a Skyr service.",
                tint: Palette.neutralTint
            ),
            OnboardingPage(
                id: 1,
                title: "Your sign-in\nis yours.",
                text: "Your NAS password is saved in the Keychain on this \(Device.noun). There is no Skyr account to create. Skyr shares the NAS credentials you choose for Family Access. Use a separate read-only NAS account.",
                tint: Color(hex: "#9a8fd0")
            ),
            OnboardingPage(
                id: 2,
                title: "Family through\nyour iCloud, not ours.",
                text: "Profiles, playlists and listening history sync through Apple’s iCloud. People with your family invitation link can join and receive profiles and connection details. Skyr has no ads or third-party analytics SDK.",
                tint: Color(hex: "#7fb3a8")
            ),
            OnboardingPage(
                id: 3,
                title: "Covers from\nyour own library.",
                text: PrivacyDetailsView.artworkDisclosure,
                tint: Palette.neutralTint
            ),
        ]
    }
}

/// The introduction shown once, from the welcome screen: four pages on privacy, then "Find servers".
/// Words only, centred on the paper: a headline, a line of secondary text, the page capsules, one ink
/// button and a quiet text link. Pages crossfade; the paper's tint drifts with them. The same
/// composition on every platform, the type a size larger on wide screens and larger again on television.
struct OnboardingView: View {
    let finish: () -> Void
    @State private var index: Int
    @Environment(\.isWideLayout) private var isWide
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let pages = OnboardingPage.privacy

    init(initialIndex: Int = 0, finish: @escaping () -> Void) {
        self.finish = finish
        _index = State(initialValue: min(max(0, initialIndex), OnboardingPage.privacy.count - 1))
    }

    private var page: OnboardingPage { pages[index] }
    private var isLast: Bool { index == pages.count - 1 }

    /// 38 pt on a phone like the welcome headline, 44 on iPad and Mac, 68 on television.
    private var titleSize: CGFloat {
        guard isWide else { return 38 }
        return Metrics.scale > 1 ? 68 : 44
    }

    private var body_: Font { isWide ? .title3 : .body }
    private var columnWidth: CGFloat { isWide ? 520 * Metrics.scale : 340 }
    private var buttonWidth: CGFloat? { isWide ? 320 * Metrics.scale : nil }

    var body: some View {
        ZStack {
            TintedBackground(tint: page.tint)
            VStack(spacing: 0) {
                ScrollView {
                    VStack(spacing: 16 * Metrics.scale) {
                        Text(page.title)
                            .font(.system(size: titleSize, weight: .semibold))
                            .kerning(-titleSize * 0.03)
                            .lineSpacing(-2)
                        Text(page.text)
                            .font(body_)
                            .foregroundStyle(.secondary)
                            #if os(tvOS)
                            .focusable()
                            #endif
                        if page.id == 3 {
                            PrivacyDetailsButton()
                                .padding(.top, 8)
                        }
                    }
                    .padding(.vertical, 20)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: columnWidth)
                    .id(page.id)
                    .transition(.opacity)
                }
                .defaultScrollAnchor(.center, for: .alignment)
                .scrollIndicators(.hidden)
                PageDots(count: pages.count, current: index)
                    .padding(.bottom, 22 * Metrics.scale)
                continueButton
                    .frame(maxWidth: buttonWidth)
                skipLink
                    .padding(.top, 18 * Metrics.scale)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: index)
        #if !os(tvOS)
        .simultaneousGesture(
            DragGesture(minimumDistance: 30).onEnded { value in
                guard abs(value.translation.width) > abs(value.translation.height) else { return }
                if value.translation.width < -50 {
                    next()
                } else if value.translation.width > 50 {
                    back()
                }
            }
        )
        #endif
    }

    private var continueButton: some View {
        Button {
            if isLast {
                finish()
            } else {
                next()
            }
        } label: {
            Text(isLast ? "Find servers" : "Continue")
                .font(.headline)
                .foregroundStyle(Palette.onInk)
                .frame(maxWidth: .infinity)
                .contentTransition(.opacity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .tint(Palette.ink)
    }

    /// The quiet way out, like "Enter an address" under the welcome button.
    private var skipLink: some View {
        Button("Skip", action: finish)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .buttonStyle(.borderless)
            .accessibilityLabel("Skip the introduction")
    }

    private func next() {
        guard !isLast else { return }
        withAnimation(reduceMotion ? nil : .default) { index += 1 }
    }

    private func back() {
        guard index > 0 else { return }
        withAnimation(reduceMotion ? nil : .default) { index -= 1 }
    }
}

/// Page capsules: the current one long and inked.
struct PageDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6 * Metrics.scale) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(Palette.ink.opacity(i == current ? 1 : 0.18))
                    .frame(width: (i == current ? 26 : 8) * Metrics.scale, height: 6 * Metrics.scale)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
