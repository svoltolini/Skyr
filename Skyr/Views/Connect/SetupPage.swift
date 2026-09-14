import SkyrCore
import SwiftUI

/// The first-run steps in order; the story pane names the step and shows how far along it is.
enum SetupStep: Int, CaseIterable {
    case welcome, server, folder, indexing

    var headline: String {
        switch self {
        case .welcome: "Your library,\nfrom your NAS."
        case .server: "Find your\nserver."
        case .folder: "Choose your\nmusic folder."
        case .indexing: "Building your\nlibrary."
        }
    }

    var blurb: String {
        switch self {
        case .welcome: "Connect the server you already own. Nothing leaves your network."
        case .server: "Skyr looks for Synology servers on this network. Away from home, enter the address you set up in DSM."
        case .folder: "Point Skyr at the shared folder that holds your music. Everything inside it is indexed."
        case .indexing: "Tags, artwork and folder structure are read straight from the server. Listening starts as soon as the scan is done."
        }
    }
}

extension EnvironmentValues {
    /// True inside a setup page that shows the story pane, so a step can leave its headline to it.
    @Entry var hasSetupStory = false
}

/// A first-run screen. A phone shows the step's content on its own, as before. A wide iPad window
/// splits in two: the story pane on the left carries the brand mark, the step's headline and the
/// progress through the steps, and the step's content fills the right.
struct SetupPage<Content: View>: View {
    let step: SetupStep
    var showsBack = false
    /// A title for the content pane where the step's own title would otherwise be lost with the bar.
    var contentTitle: String? = nil
    @ViewBuilder let content: () -> Content
    @Environment(\.isWideLayout) private var isWide

    var body: some View {
        #if os(iOS)
        if isWide {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    SetupStory(step: step, showsBack: showsBack)
                        .frame(width: max(360, proxy.size.width * 0.42))
                    VStack(alignment: .leading, spacing: 0) {
                        if let contentTitle {
                            Text(contentTitle)
                                .font(.largeTitle.weight(.bold))
                                .kerning(-0.6)
                                .padding(.horizontal, 40)
                                .padding(.top, 28)
                        }
                        content()
                            .environment(\.hasSetupStory, true)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationBarBackButtonHidden(true)
        } else {
            content()
        }
        #else
        content()
        #endif
    }
}

#if os(iOS)
/// The left pane: brand mark, headline, blurb and the step dots, on a slightly deeper paper.
private struct SetupStory: View {
    let step: SetupStep
    let showsBack: Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                if showsBack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.body.weight(.semibold))
                            .frame(width: 40, height: 40)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("Back")
                }
                Spacer()
            }
            .frame(height: 44)
            Spacer()
            BrandMark()
            Text(step.headline)
                .font(.system(size: 46, weight: .semibold))
                .kerning(-1.2)
                .lineSpacing(-3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 32)
                .contentTransition(.opacity)
            Text(step.blurb)
                .font(.title3)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380, alignment: .leading)
                .padding(.top, 18)
            Spacer()
            StepDots(current: step)
        }
        .padding(.horizontal, 48)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background {
            ZStack {
                Palette.paper.mix(with: Palette.neutralTint, by: colorScheme == .dark ? 0.32 : 0.24)
                RadialGradient(
                    colors: [Palette.brand.opacity(colorScheme == .dark ? 0.26 : 0.2), .clear],
                    center: UnitPoint(x: 0.3, y: 0.45),
                    startRadius: 0,
                    endRadius: 440
                )
                .blur(radius: 30)
            }
            .ignoresSafeArea()
        }
    }
}

/// The app icon's note on a white tile.
private struct BrandMark: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.white)
            .frame(width: 72, height: 72)
            .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(Palette.brand)
            }
            .accessibilityHidden(true)
    }
}

/// Four capsules; the current step's is long and inked.
private struct StepDots: View {
    let current: SetupStep

    var body: some View {
        HStack(spacing: 6) {
            ForEach(SetupStep.allCases, id: \.self) { step in
                Capsule()
                    .fill(Palette.ink.opacity(step == current ? 1 : 0.18))
                    .frame(width: step == current ? 26 : 8, height: 6)
            }
        }
        .animation(.snappy(duration: 0.3), value: current)
        .accessibilityElement()
        .accessibilityLabel("Step \(current.rawValue + 1) of \(SetupStep.allCases.count)")
    }
}

#endif

private extension Edge {
    var point: UnitPoint {
        switch self {
        case .top: .top
        case .bottom: .bottom
        case .leading: .leading
        case .trailing: .trailing
        }
    }

    var opposite: UnitPoint {
        switch self {
        case .top: .bottom
        case .bottom: .top
        case .leading: .trailing
        case .trailing: .leading
        }
    }
}

/// A tilted wall of cover-like tiles. Framed, it fades out towards its edges inside a pane; bleeding,
/// it runs off every edge of its area and fades only at the bottom, into the page below it.
struct CoverWall: View {
    enum Style {
        case framed
        /// Runs off every edge; only the named edge dissolves, into whatever sits beside it.
        case bleed(fadeEdge: Edge)
    }

    var style: Style = .framed

    private var bleeds: Bool {
        if case .bleed = style { return true }
        return false
    }

    private var fadeEdge: Edge {
        if case .bleed(let edge) = style { return edge }
        return .bottom
    }

    private static let pairs: [(String, String)] = [
        ("#7c5cff", "#2a1a80"), ("#f472b6", "#4c0519"), ("#38bdf8", "#0c4a6e"), ("#fb923c", "#7c2d12"),
        ("#34d399", "#064e3b"), ("#facc15", "#713f12"), ("#a78bfa", "#312e81"), ("#f87171", "#7f1d1d"),
        ("#2dd4bf", "#134e4a"), ("#4a5568", "#141821"), ("#e879f9", "#701a75"), ("#fbbf24", "#78350f"),
        ("#60a5fa", "#1e3a8a"), ("#fb7185", "#881337"), ("#a3e635", "#365314"), ("#c084fc", "#3b0764"),
    ]

    var body: some View {
        GeometryReader { proxy in
            // Framed: four columns sized to fit the pane. Bleeding: album-sized tiles by the shorter
            // side, with enough rows to run past the bottom however tall the area is.
            // The television's pane is huge, so its tiles are cut a little finer to keep a wall's rhythm.
            let bleedDivisor: CGFloat = Metrics.scale > 1 ? 4.2 : 3.2
            let side = bleeds ? min(proxy.size.width, proxy.size.height) / bleedDivisor : min(proxy.size.width / 3.6, proxy.size.height / 3.6)
            let spacing = side * 0.12
            let columnCount = bleeds ? Int(proxy.size.width / (side + spacing)) + 3 : 4
            let count = bleeds ? columnCount * (Int(proxy.size.height / (side + spacing)) + 3) : 16
            let columns = Array(repeating: GridItem(.fixed(side), spacing: spacing), count: columnCount)
            LazyVGrid(columns: columns, spacing: spacing) {
                ForEach(0..<count, id: \.self) { i in
                    let pair = Self.pairs[i % Self.pairs.count]
                    GradientTile(primary: Color(hex: pair.0), secondary: Color(hex: pair.1), cornerRadius: side * 0.12)
                        .frame(width: side, height: side)
                        .shadow(color: .black.opacity(0.18), radius: side * 0.12, y: side * 0.08)
                }
            }
            .fixedSize()
            .rotationEffect(.degrees(bleeds ? -10 : -8))
            .scaleEffect(bleeds ? 1.15 : 1.12)
            .frame(width: proxy.size.width, height: proxy.size.height)
            .mask {
                if bleeds {
                    // Solid to the other edges; only the fade edge dissolves into what lies beyond it.
                    LinearGradient(
                        stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7), .init(color: .clear, location: 1)],
                        startPoint: fadeEdge.opposite,
                        endPoint: fadeEdge.point
                    )
                } else {
                    // Elliptical, so the fade follows the pane's shape and no tile ends in a hard edge.
                    EllipticalGradient(
                        colors: [.black, .black.opacity(0.85), .clear],
                        center: .center,
                        startRadiusFraction: 0.15,
                        endRadiusFraction: 0.5
                    )
                }
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}
