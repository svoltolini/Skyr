import SkyrCore
import ImageIO
import SwiftUI

/// How big a cover is drawn, which picks the decode size: small rows never carry a 512 pixel bitmap.
enum ArtworkSize {
    /// Up to about 64 points: list rows, the mini player, genre cards.
    case row
    /// Cards, tiles and shelves.
    case card
    /// The album page, the player and the artist hero.
    case hero

    var pixels: Int {
        switch self {
        case .row: CoverImageCache.rowPixels
        case .card: CoverImageCache.thumbnailPixels
        case .hero: CoverImageCache.largePixels
        }
    }
}

/// Shows a cover straight from the memory cache when it is there, otherwise decodes it once in the
/// background while the placeholder shows. Once the image is there nothing is drawn underneath it.
private struct CoverImage<Placeholder: View>: View {
    let url: URL
    let album: Album
    let version: Int
    let size: ArtworkSize
    let shape: RoundedRectangle
    @ViewBuilder let placeholder: () -> Placeholder
    @State private var loaded: CGImage?

    private var key: String { "\(album.id)|\(version)|\(size.pixels)" }

    /// A smaller copy already decoded for another screen stands in while the right size loads.
    private var image: CGImage? {
        if let loaded { return loaded }
        if let exact = CoverImageCache.shared.cached(key) { return exact }
        for pixels in [CoverImageCache.thumbnailPixels, CoverImageCache.rowPixels] where pixels < size.pixels {
            if let smaller = CoverImageCache.shared.cached("\(album.id)|\(version)|\(pixels)") { return smaller }
        }
        return nil
    }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1)
                    .resizable()
                    .scaledToFill()
                    .clipShape(shape)
            } else {
                placeholder()
            }
        }
        .task(id: key) {
            guard CoverImageCache.shared.cached(key) == nil else { return }
            loaded = await CoverImageCache.shared.image(url: url, key: key, maxPixelSize: size.pixels)
        }
    }
}

/// Album artwork: the server's cover when available, otherwise the album's gradient placeholder.
struct ArtworkView: View {
    let album: Album
    var cornerRadius: CGFloat = 12
    var highlight = true
    var size: ArtworkSize = .card
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ZStack {
            if let url = library.coverURL(for: album) {
                CoverImage(url: url, album: album, version: library.coverVersion(for: album), size: size, shape: shape) {
                    placeholder(shape)
                }
            } else {
                placeholder(shape)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    private func placeholder(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [album.primaryColor, album.secondaryColor],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                if highlight {
                    shape.fill(
                        EllipticalGradient(
                            colors: [.white.opacity(0.28), .clear],
                            center: UnitPoint(x: 0.3, y: 0.25),
                            startRadiusFraction: 0,
                            endRadiusFraction: 0.55
                        )
                    )
                }
            }
    }
}

/// Circular artist portrait using the artist's first album cover, or its colours.
struct ArtistPortrait: View {
    let artist: Artist
    var size: ArtworkSize = .card

    var body: some View {
        ArtworkView(album: artist.albums[0], cornerRadius: 0, highlight: false, size: size)
            .clipShape(Circle())
            .accessibilityHidden(true)
    }
}

/// Cover for any playlist: the app's own lists get generated artwork, user playlists a mosaic of their albums.
struct PlaylistCover: View {
    let playlist: Playlist
    var cornerRadius: CGFloat = 8
    var placeholderSymbol = "music.note.list"

    var body: some View {
        switch playlist.id {
        case Playlist.favouritesID: SmartPlaylistCover(kind: .favourites, cornerRadius: cornerRadius)
        case Playlist.favouritesMixID: SmartPlaylistCover(kind: .mix, cornerRadius: cornerRadius)
        case Playlist.recentlyPlayedID: SmartPlaylistCover(kind: .recentlyPlayed, cornerRadius: cornerRadius)
        case Playlist.libraryShuffleID: SmartPlaylistCover(kind: .shuffle, cornerRadius: cornerRadius)
        default: MosaicArtwork(albums: playlist.covers, cornerRadius: cornerRadius, placeholderSymbol: placeholderSymbol)
        }
    }
}

/// Generated artwork for the app's own playlists: a gradient with a light drifting across it behind a still symbol.
struct SmartPlaylistCover: View {
    enum Kind { case favourites, mix, recentlyPlayed, shuffle }
    let kind: Kind
    var cornerRadius: CGFloat = 8

    private var colors: [Color] {
        switch kind {
        case .favourites: [Color(hex: "#ff7a95"), Color(hex: "#d4234f"), Color(hex: "#5e0b26")]
        case .mix: [Color(hex: "#8f7dff"), Color(hex: "#4a2fd6"), Color(hex: "#160b52")]
        case .recentlyPlayed: [Color(hex: "#5eead4"), Color(hex: "#0d9488"), Color(hex: "#083f3a")]
        case .shuffle: [Color(hex: "#fcd34d"), Color(hex: "#ea580c"), Color(hex: "#6b1d0b")]
        }
    }

    private var symbolName: String {
        switch kind {
        case .favourites: "heart.fill"
        case .mix: "sparkles"
        case .recentlyPlayed: "clock.fill"
        case .shuffle: "shuffle"
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                DriftingLightTile(colors: colors.map { PlatformColor($0) }, cornerRadius: cornerRadius)
                symbol(size: side)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// The symbol stays still; only the light behind it moves.
    private func symbol(size: CGFloat) -> some View {
        Image(systemName: symbolName)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(.white)
            .shadow(color: .black.opacity(0.22), radius: size * 0.03, y: size * 0.015)
    }
}

/// The gradient and its drifting light as Core Animation layers. The render server moves the light,
/// so a scrolling screen never waits on SwiftUI to redraw the tiles, and the loop's phase follows the
/// clock, so a tile that leaves the screen and comes back is in step with the others.
#if canImport(UIKit)
private struct DriftingLightTile: UIViewRepresentable {
    let colors: [PlatformColor]
    let cornerRadius: CGFloat

    func makeUIView(context: Context) -> DriftingLightView { DriftingLightView() }

    func updateUIView(_ view: DriftingLightView, context: Context) {
        view.colors = colors
        view.hostLayer.cornerRadius = cornerRadius
    }
}
#else
private struct DriftingLightTile: NSViewRepresentable {
    let colors: [PlatformColor]
    let cornerRadius: CGFloat

    func makeNSView(context: Context) -> DriftingLightView { DriftingLightView() }

    func updateNSView(_ view: DriftingLightView, context: Context) {
        view.colors = colors
        view.hostLayer.cornerRadius = cornerRadius
    }
}
#endif

final class DriftingLightView: PlatformView {
    var colors: [PlatformColor] = [] {
        didSet { base.colors = colors.map(\.cgColor) }
    }

    private let base = CAGradientLayer()
    private let light = CAGradientLayer()
    /// One loop of the light; the two axes run four and three cycles in it so the path closes.
    private let period: Double = 100

    /// The backing layer, which a Mac view only has once asked for.
    var hostLayer: CALayer {
        #if canImport(UIKit)
        layer
        #else
        layer!
        #endif
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        #if canImport(UIKit)
        isUserInteractionEnabled = false
        #else
        wantsLayer = true
        #endif
        hostLayer.cornerCurve = .continuous
        hostLayer.masksToBounds = true
        base.startPoint = CGPoint(x: 0, y: 0)
        base.endPoint = CGPoint(x: 1, y: 1)
        light.type = .radial
        light.colors = [PlatformColor.white.withAlphaComponent(0.38).cgColor, PlatformColor.white.withAlphaComponent(0).cgColor]
        light.startPoint = CGPoint(x: 0.5, y: 0.5)
        light.endPoint = CGPoint(x: 1, y: 1)
        hostLayer.addSublayer(base)
        hostLayer.addSublayer(light)
        // The system drops layer animations while the app is in the background; selector observers
        // unregister themselves when the view goes away.
        NotificationCenter.default.addObserver(self, selector: #selector(appDidBecomeActive), name: .appBecameActive, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func appDidBecomeActive() {
        restartDrift()
    }

    #if canImport(UIKit)
    override func layoutSubviews() {
        super.layoutSubviews()
        placeLayers()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { restartDrift() }
    }
    #else
    override func layout() {
        super.layout()
        placeLayers()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { restartDrift() }
    }

    /// Decoration only: clicks go to whatever is underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #endif

    private func placeLayers() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        base.frame = bounds
        let diameter = bounds.width * 1.3
        light.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        CATransaction.commit()
        restartDrift()
    }

    private func restartDrift() {
        guard bounds.width > 0 else { return }
        light.removeAnimation(forKey: "drift")
        let width = bounds.width
        let height = bounds.height
        let steps = 240
        let points: [CGPoint] = (0...steps).map { step in
            let s = Double(step) / Double(steps)
            let x = 0.47 + 0.26 * sin(2 * .pi * 4 * s)
            let y = 0.42 + 0.22 * sin(2 * .pi * 3 * s + 1.1)
            return CGPoint(x: x * width, y: y * height)
        }
        let drift = CAKeyframeAnimation(keyPath: "position")
        #if os(macOS)
        drift.values = points.map { NSValue(point: $0) }
        #else
        drift.values = points.map { NSValue(cgPoint: $0) }
        #endif
        drift.calculationMode = .linear
        drift.duration = period
        drift.repeatCount = .infinity
        // Join the loop where the clock says it is, so every tile shows the same moment.
        drift.timeOffset = CACurrentMediaTime().truncatingRemainder(dividingBy: period)
        light.position = points[0]
        light.add(drift, forKey: "drift")
    }
}

/// Cover collage for playlists and decades: one cover fills the tile, two share it side by side,
/// three give the first the left half, four or more form a two-by-two mosaic.
struct MosaicArtwork: View {
    let albums: [Album]
    var cornerRadius: CGFloat = 8
    var placeholderSymbol = "music.note.list"

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            Group {
                switch albums.count {
                case 0:
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .fill(.quaternary)
                        .overlay {
                            Image(systemName: placeholderSymbol)
                                .font(.title3)
                                .foregroundStyle(.secondary)
                        }
                case 1:
                    ArtworkView(album: albums[0], cornerRadius: 0, highlight: false)
                case 2:
                    HStack(spacing: 0) {
                        half(albums[0], side: side)
                        half(albums[1], side: side)
                    }
                case 3:
                    HStack(spacing: 0) {
                        half(albums[0], side: side)
                        VStack(spacing: 0) {
                            ArtworkView(album: albums[1], cornerRadius: 0, highlight: false)
                            ArtworkView(album: albums[2], cornerRadius: 0, highlight: false)
                        }
                        .frame(width: side / 2)
                    }
                default:
                    VStack(spacing: 0) {
                        HStack(spacing: 0) {
                            ArtworkView(album: albums[0], cornerRadius: 0, highlight: false)
                            ArtworkView(album: albums[1], cornerRadius: 0, highlight: false)
                        }
                        HStack(spacing: 0) {
                            ArtworkView(album: albums[2], cornerRadius: 0, highlight: false)
                            ArtworkView(album: albums[3], cornerRadius: 0, highlight: false)
                        }
                    }
                }
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }

    /// A full-height strip showing the middle of a square cover.
    private func half(_ album: Album, side: CGFloat) -> some View {
        ArtworkView(album: album, cornerRadius: 0, highlight: false)
            .frame(width: side, height: side)
            .frame(width: side / 2, height: side)
            .clipped()
    }
}

/// Gradient tile used for genre and decade cards.
struct GradientTile: View {
    let primary: Color
    let secondary: Color
    var cornerRadius: CGFloat = 14

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .fill(LinearGradient(colors: [primary, secondary], startPoint: .topLeading, endPoint: .bottomTrailing))
            .accessibilityHidden(true)
    }
}
