import SkyrCore
import SwiftUI

/// Section title used above carousels, with an optional trailing action.
struct SectionHeader: View {
    let title: String
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let actionTitle {
                Button(actionTitle) { action?() }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 24)
    }
}

/// The one way the app says "nothing here": a symbol, a title and one line of help, centred on the screen.
/// Pass `centered: false` when it sits under other content, such as a playlist's header.
struct EmptyStateView: View {
    let title: String
    let systemImage: String
    let message: String
    var centered = true

    var body: some View {
        let content = ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(message)
        }
        if centered {
            content.containerRelativeFrame([.horizontal, .vertical])
        } else {
            content.containerRelativeFrame(.vertical) { length, _ in length * 0.45 }
        }
    }
}

/// Small uppercase caption used to label groups inside scroll views.
struct Eyebrow: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .kerning(0.5)
            .padding(.horizontal, 24)
    }
}

/// Rounded card that stacks rows with inset separators, matching inset grouped lists.
struct CardList<Data: RandomAccessCollection, Row: View>: View where Data.Element: Identifiable {
    let data: Data
    var separatorInset: CGFloat = 16
    @ViewBuilder let row: (Data.Element) -> Row

    var body: some View {
        // Lazy: the artists facet can hold hundreds of rows, and only the visible ones need to exist.
        LazyVStack(spacing: 0) {
            ForEach(Array(data.enumerated()), id: \.element.id) { index, element in
                row(element)
                if index < data.count - 1 {
                    Divider().padding(.leading, separatorInset)
                }
            }
        }
        .background(Color.groupedCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// Single line of text that fades out at the trailing edge instead of truncating with an ellipsis.
/// Short text is left untouched; the fade appears only when the text is wider than its container.
struct FadingText: View {
    let text: String
    var fadeWidth: CGFloat = 56
    /// Where short text sits; long text always starts at the leading edge so the fade stays on the right.
    var alignment: Alignment = .leading
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0

    init(_ text: String, fadeWidth: CGFloat = 56, alignment: Alignment = .leading) {
        self.text = text
        self.fadeWidth = fadeWidth
        self.alignment = alignment
    }

    private var overflows: Bool { textWidth > containerWidth + 0.5 }

    var body: some View {
        // The mask is an offscreen pass for the renderer; text that fits, which is most of it, gets none.
        Group {
            if overflows {
                measured
                    .clipped()
                    .mask(alignment: .leading) {
                        HStack(spacing: 0) {
                            Rectangle()
                            LinearGradient(
                                stops: [.init(color: .black, location: 0), .init(color: .black.opacity(0.55), location: 0.45), .init(color: .clear, location: 1)],
                                startPoint: .leading, endPoint: .trailing
                            )
                            .frame(width: fadeWidth)
                        }
                    }
            } else {
                measured
            }
        }
        .accessibilityLabel(text)
    }

    private var measured: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { textWidth = $0 }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: overflows ? .leading : alignment)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
    }
}

/// Trailing disclosure chevron for card rows.
struct DisclosureChevron: View {
    var body: some View {
        Image(systemName: "chevron.right")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.tertiary)
    }
}

/// Three ascending bars, like the cellular signal indicator, lit up to the album's quality tier.
struct QualityBars: View {
    let quality: AudioQuality
    var barWidth: CGFloat = 3
    var maxHeight: CGFloat = 11
    var spacing: CGFloat = 2.5

    /// Three bars of equal height: one lit for standard, two for high, three for lossless.
    var body: some View {
        HStack(alignment: .center, spacing: spacing) {
            ForEach(1...3, id: \.self) { level in
                RoundedRectangle(cornerRadius: barWidth / 2, style: .continuous)
                    .fill(level <= quality.rawValue ? AnyShapeStyle(.primary) : AnyShapeStyle(.quaternary))
                    .frame(width: barWidth, height: maxHeight)
            }
        }
        .frame(height: maxHeight)
        .accessibilityElement()
        .accessibilityLabel("Quality: \(quality.label)")
    }
}

/// A card with two faces that turns over around its vertical axis; the back is shown once the turn passes halfway.
struct FlipView<Front: View, Back: View>: View, Animatable {
    var angle: Double
    let front: Front
    let back: Back

    init(angle: Double, @ViewBuilder front: () -> Front, @ViewBuilder back: () -> Back) {
        self.angle = angle
        self.front = front()
        self.back = back()
    }

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        ZStack {
            if angle < 90 {
                front
            } else {
                // Mirrored in advance so it reads correctly once the card has turned.
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.45)
    }
}

/// Press feedback for full-width rows: a faint highlight while the finger is down.
struct RowPressStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.primary.opacity(isFocused ? 0.14 : 0))
            )
            .scaleEffect(isFocused ? 1.02 : 1)
            .animation(.easeOut(duration: 0.18), value: isFocused)
        #else
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.07 : 0))
            )
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
        #endif
    }
}

/// Press feedback for transport controls: a quick shrink and dim while the finger is down.
struct TransportButtonStyle: ButtonStyle {
    #if os(tvOS)
    @Environment(\.isFocused) private var isFocused
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(tvOS)
        configuration.label
            .scaleEffect(isFocused ? 1.15 : 1)
            .shadow(color: .black.opacity(isFocused ? 0.35 : 0), radius: 20, y: 12)
            .animation(.spring(duration: 0.28, bounce: 0.25), value: isFocused)
        #else
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .opacity(configuration.isPressed ? 0.55 : 1)
            .animation(.spring(duration: 0.28, bounce: 0.3), value: configuration.isPressed)
        #endif
    }
}

/// Play / pause glyph that morphs between states.
struct PlayPauseGlyph: View {
    let isPlaying: Bool
    var size: CGFloat = 16

    var body: some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: size, weight: .semibold))
            .contentTransition(.symbolEffect(.replace))
            .animation(.snappy(duration: 0.25), value: isPlaying)
    }
}

/// Namespace shared by artwork zoom transitions within one navigation stack.
private struct ArtworkNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var artworkNamespace: Namespace.ID? {
        get { self[ArtworkNamespaceKey.self] }
        set { self[ArtworkNamespaceKey.self] = newValue }
    }
}

/// An album to push, remembering which artwork it was opened from so the zoom can return there.
nonisolated struct AlbumDestination: Hashable {
    let album: Album
    let sourceID: String

    init(_ album: Album, source: String) {
        self.album = album
        sourceID = source + "|" + album.id
    }
}

/// How a zoom source is clipped while it morphs; without it the snapshot is a plain square.
nonisolated enum ZoomShape: Equatable {
    case rounded(CGFloat)
    /// A circle of this diameter; only rounded rectangles are accepted, so it becomes half the size as radius.
    case circle(CGFloat)

    var cornerRadius: CGFloat {
        switch self {
        case .rounded(let radius): radius
        case .circle(let diameter): diameter / 2
        }
    }
}

/// The shadow the flying snapshot carries, matching the one on the view at rest.
nonisolated struct ZoomShadow: Equatable {
    var opacity: Double
    var radius: CGFloat
    var y: CGFloat

    static let card = ZoomShadow(opacity: 0.3, radius: 14, y: 10)
    static let tile = ZoomShadow(opacity: 0.25, radius: 12, y: 8)
}

private struct ArtworkSourceModifier: ViewModifier {
    let sourceID: String
    var shape: ZoomShape = .rounded(12)
    var shadow: ZoomShadow?
    @Environment(\.artworkNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            if let shadow {
                content.matchedTransitionSource(id: sourceID, in: namespace) { source in
                    source
                        .clipShape(.rect(cornerRadius: shape.cornerRadius, style: .continuous))
                        .shadow(color: .black.opacity(shadow.opacity), radius: shadow.radius, y: shadow.y)
                }
            } else {
                content.matchedTransitionSource(id: sourceID, in: namespace) { source in
                    source.clipShape(.rect(cornerRadius: shape.cornerRadius, style: .continuous))
                }
            }
        } else {
            content
        }
    }
}

private struct ArtworkZoomModifier: ViewModifier {
    let sourceID: String
    @Environment(\.artworkNamespace) private var namespace

    func body(content: Content) -> some View {
        #if os(macOS)
        // The Mac pushes pages without a zoom; the matched source still marks the origin for later.
        content
        #else
        if let namespace {
            content.navigationTransition(.zoom(sourceID: sourceID, in: namespace))
        } else {
            content
        }
        #endif
    }
}

extension View {
    /// Marks artwork as the origin of a zoom into the album page.
    func artworkSource(_ destination: AlbumDestination, cornerRadius: CGFloat = 12, shadow: ZoomShadow? = nil) -> some View {
        modifier(ArtworkSourceModifier(sourceID: destination.sourceID, shape: .rounded(cornerRadius), shadow: shadow))
    }

    /// Zooms a pushed album page out of the artwork it was opened from.
    func artworkZoom(from destination: AlbumDestination) -> some View {
        modifier(ArtworkZoomModifier(sourceID: destination.sourceID))
    }

    /// Marks any view as the origin of a zoom into a page or sheet.
    func zoomSource(id: String, shape: ZoomShape = .rounded(12), shadow: ZoomShadow? = nil) -> some View {
        modifier(ArtworkSourceModifier(sourceID: id, shape: shape, shadow: shadow))
    }

    /// Zooms a pushed page or presented sheet out of the view marked with the same id.
    func zoomDestination(id: String) -> some View {
        modifier(ArtworkZoomModifier(sourceID: id))
    }
}

/// An artist page opened from a portrait, so it can zoom out of it.
nonisolated struct ArtistDestination: Hashable {
    let artist: Artist
    let sourceID: String

    init(_ artist: Artist, source: String) {
        self.artist = artist
        sourceID = source + "|artist|" + artist.id
    }
}

/// A playlist page opened from its tile.
nonisolated struct PlaylistDestination: Hashable {
    let playlist: Playlist
    let sourceID: String

    init(_ playlist: Playlist, source: String) {
        self.playlist = playlist
        sourceID = source + "|playlist|" + playlist.id
    }
}

/// A list of albums opened from a genre card or decade tile.
nonisolated struct CollectionDestination: Hashable {
    let collection: AlbumCollection
    let sourceID: String

    init(_ collection: AlbumCollection, source: String) {
        self.collection = collection
        sourceID = source + "|collection|" + collection.title
    }
}

/// Primary and secondary pill actions used on album and artist pages.
struct PlayActions: View {
    let play: () -> Void
    let shuffle: () -> Void

    @Environment(\.isWideLayout) private var isWide

    /// The phone stretches the pair across the page; on a wide screen a button is as wide as its label.
    private var stretches: Bool { !isWide }

    var body: some View {
        HStack(spacing: 10) {
            Button(action: play) {
                Label("Play", systemImage: "play.fill")
                    .font(.headline)
                    .foregroundStyle(Palette.onInk)
                    .frame(maxWidth: stretches ? .infinity : nil)
                    .padding(.horizontal, stretches ? 0 : 12)
            }
            .buttonStyle(.glassProminent)
            .tint(Palette.ink)

            Button(action: shuffle) {
                Label("Shuffle", systemImage: "shuffle")
                    .font(.headline)
                    .frame(maxWidth: stretches ? .infinity : nil)
                    .padding(.horizontal, stretches ? 0 : 12)
            }
            .buttonStyle(.glass)
        }
        .controlSize(.large)
    }
}

/// A page's opening: cover, the title lines, then the actions. Stacked and centred on a phone; on
/// a Mac the cover sits on the left with the text and actions beside it, the way a wide page reads.
struct DetailHeader<Cover: View, Titles: View, Actions: View>: View {
    var coverSize: CGFloat
    @ViewBuilder let cover: () -> Cover
    @ViewBuilder let titles: () -> Titles
    @ViewBuilder let actions: () -> Actions
    @Environment(\.isWideLayout) private var isWide

    /// Cover size beside the text on a wide screen.
    private var wideCover: CGFloat {
        #if os(tvOS)
        400
        #else
        224
        #endif
    }

    var body: some View {
        if isWide {
            HStack(alignment: .bottom, spacing: wideCover * 0.13) {
                cover()
                    .frame(width: wideCover, height: wideCover)
                VStack(alignment: .leading, spacing: 6) {
                    titles()
                    actions()
                        .padding(.top, 18)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.top, 12)
        } else {
            VStack(spacing: 0) {
                cover()
                    .frame(width: coverSize, height: coverSize)
                    .padding(.top, 22)
                VStack(spacing: 5) {
                    titles()
                }
                .multilineTextAlignment(.center)
                .padding(.top, 24)
                actions()
                    .padding(.top, 22)
            }
        }
    }
}

/// Simple wrapping layout for tag-style chips.
nonisolated struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
