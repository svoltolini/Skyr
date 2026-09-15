import SkyrCore
import SwiftUI

/// Paper background mixed with the current accent colour, with a soft glow near the top.
struct TintedBackground: View {
    var tint: Color
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Palette.paper.mix(with: tint, by: colorScheme == .dark ? 0.22 : 0.14)
            RadialGradient(
                colors: [tint.opacity(0.38), .clear],
                center: UnitPoint(x: 0.5, y: 0.08),
                startRadius: 0,
                endRadius: 460
            )
            .blur(radius: 40)
        }
        .ignoresSafeArea()
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.8), value: tint)
    }
}

/// The tinted paper behind a screen, with the navigation bar pinned to the same light or dark look.
/// Left adaptive, the bar's glass flips its title to white whenever a dark cover scrolls under it,
/// which reads as white text on a pale page.
private struct SkyrBackground: ViewModifier {
    let tint: Color
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        #if os(iOS)
        content
            .background(TintedBackground(tint: tint))
            .toolbarColorScheme(colorScheme, for: .navigationBar)
        #elseif os(macOS)
        content.background(Color(nsColor: .windowBackgroundColor))
        #else
        content
            .background(TintedBackground(tint: tint))
        #endif
    }
}

extension View {
    /// Applies the tinted paper background behind any screen.
    func skyrBackground(_ tint: Color) -> some View {
        modifier(SkyrBackground(tint: tint))
    }
}
