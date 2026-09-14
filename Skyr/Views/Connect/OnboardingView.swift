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
    /// Every line here is checked against the code: passwords go to the Keychain, the only hosts the
    /// app talks to are the person's own NAS and their iCloud, and there is no analytics of any kind.
    static var privacy: [OnboardingPage] {
        [
            OnboardingPage(
                id: 0,
                title: "Your music stays\nwhere it is.",
                text: "Skyr plays straight from the Synology you already own. Your library, playlists and listening history live on your devices and your server. There is no Skyr cloud in between.",
                tint: Palette.neutralTint
            ),
            OnboardingPage(
                id: 1,
                title: "Your sign-in\nis yours.",
                text: "Your DSM account is kept in the Keychain on this \(Device.noun) and sent only to your NAS. There is no Skyr account to create, and nobody at Skyr can see your credentials.",
                tint: Color(hex: "#9a8fd0")
            ),
            OnboardingPage(
                id: 2,
                title: "Family through\nyour iCloud, not ours.",
                text: "Profiles and shared playlists sync through your own iCloud account. No tracking, no ads, no analytics: Skyr never phones home.",
                tint: Color(hex: "#7fb3a8")
            ),
        ]
    }
}

/// The introduction shown once, from the welcome screen: three pages on privacy, then "Find servers".
/// Words only, centred on the paper: a headline, a line of secondary text, the page capsules, one ink
/// button and a quiet text link. Pages crossfade; the paper's tint drifts with them. The same
/// composition on every platform, the type a size larger on wide screens and larger again on television.
struct OnboardingView: View {
    let finish: () -> Void
    @State private var index: Int
    @Environment(\.isWideLayout) private var isWide

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
                Spacer()
                ZStack {
                    VStack(spacing: 16 * Metrics.scale) {
                        Text(page.title)
                            .font(.system(size: titleSize, weight: .semibold))
                            .kerning(-titleSize * 0.03)
                            .lineSpacing(-2)
                        Text(page.text)
                            .font(body_)
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: columnWidth)
                    .id(page.id)
                    .transition(.opacity)
                }
                Spacer()
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
        .animation(.easeInOut(duration: 0.35), value: index)
        #if !os(tvOS)
        .gesture(
            DragGesture(minimumDistance: 30).onEnded { value in
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
        withAnimation { index += 1 }
    }

    private func back() {
        guard index > 0 else { return }
        withAnimation { index -= 1 }
    }
}

/// Page capsules: the current one long and inked.
struct PageDots: View {
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
        .animation(.snappy(duration: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Page \(current + 1) of \(count)")
    }
}
