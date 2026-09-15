import SkyrShared
import AppIntents
import SwiftUI
import WidgetKit

// Building blocks shared by every Skyr widget.

nonisolated enum WidgetImages {
    static func cover(for album: WidgetSnapshot.Album, pixels: Int) -> UIImage? {
        guard let key = album.coverKey else { return nil }
        let url = WidgetStore.coverURL(key: key, pixels: pixels) ?? WidgetStore.coverURL(key: key, pixels: WidgetStore.tilePixels)
        return url.flatMap { UIImage(contentsOfFile: $0.path) }
    }

    static func color(hex: String) -> Color {
        var value: UInt64 = 0
        Scanner(string: String(hex.drop(while: { $0 == "#" }))).scanHexInt64(&value)
        return Color(red: Double((value >> 16) & 0xFF) / 255, green: Double((value >> 8) & 0xFF) / 255, blue: Double(value & 0xFF) / 255)
    }
}

/// Small uppercase label, optionally with a symbol in front; the waveform pulses while music plays.
struct Eyebrow: View {
    let text: String
    var symbol: String? = nil
    var pulsing = false

    var body: some View {
        HStack(spacing: 5) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.caption2.weight(.bold))
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: pulsing)
            }
            Text(text.uppercased())
                .font(.caption2.weight(.semibold))
                .kerning(0.6)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .opacity(0.72)
    }
}

/// "Now playing", "Last played" and so on.
struct LeadEyebrow: View {
    let lead: WidgetSnapshot.Lead

    var body: some View {
        switch lead {
        case .playing: Eyebrow(text: "Now playing", symbol: "waveform", pulsing: true)
        case .paused: Eyebrow(text: "Paused", symbol: "pause.fill")
        case .recentlyPlayed: Eyebrow(text: "Last played")
        case .recentlyAdded: Eyebrow(text: "New in your library")
        }
    }
}

/// The gradient an album without a cover shows in the app, with the same soft highlight.
struct GradientFace: View {
    let colorA: String
    let colorB: String

    var body: some View {
        ZStack {
            LinearGradient(colors: [WidgetImages.color(hex: colorA), WidgetImages.color(hex: colorB)], startPoint: .topLeading, endPoint: .bottomTrailing)
            EllipticalGradient(colors: [.white.opacity(0.28), .clear], center: UnitPoint(x: 0.3, y: 0.25), startRadiusFraction: 0, endRadiusFraction: 0.55)
        }
    }
}

/// A cover copy from the shared container, or the album's gradient when there is none.
struct CoverTile: View {
    let album: WidgetSnapshot.Album
    var pixels = WidgetStore.tilePixels
    var cornerRadius: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        Group {
            if let image = WidgetImages.cover(for: album, pixels: pixels) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
            } else {
                GradientFace(colorA: album.colorA, colorB: album.colorB)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
    }
}

/// A cover, or its gradient, behind a whole small widget with a scrim for the words.
struct CoverBackdrop: View {
    let album: WidgetSnapshot.Album

    var body: some View {
        ZStack {
            if let image = WidgetImages.cover(for: album, pixels: WidgetStore.heroPixels) {
                Image(uiImage: image)
                    .resizable()
                    .widgetAccentedRenderingMode(.desaturated)
                    .scaledToFill()
            } else {
                GradientFace(colorA: album.colorA, colorB: album.colorB)
            }
            LinearGradient(
                stops: [.init(color: .clear, location: 0.3), .init(color: .black.opacity(0.72), location: 1)],
                startPoint: .top, endPoint: .bottom
            )
        }
    }
}

/// Medium and large widgets sit on two palette colours, darkened so white text reads.
struct PaletteBackdrop: View {
    let colorA: String
    let colorB: String

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [WidgetImages.color(hex: colorA).mix(with: .black, by: 0.28), WidgetImages.color(hex: colorB).mix(with: .black, by: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            RadialGradient(colors: [.white.opacity(0.16), .clear], center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 320)
        }
    }
}

/// Play or pause on a cover. The intent runs in the app, so the music starts without opening it.
struct PlayButton: View {
    let album: WidgetSnapshot.Album
    let isPlaying: Bool
    var size: CGFloat = 34

    var body: some View {
        Button(intent: PlayAlbumIntent(albumID: album.id)) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.55))
                Circle()
                    .strokeBorder(.white.opacity(0.35), lineWidth: 0.5)
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 0.4, weight: .bold))
                    .foregroundStyle(.white)
                    .offset(x: isPlaying ? 0 : size * 0.04)
            }
            .frame(width: size, height: size)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .invalidatableContent()
        .accessibilityLabel(isPlaying ? "Pause \(album.title)" : "Play \(album.title)")
    }
}

/// A cover with the play button in its corner; the cover itself opens the album, or the play sheet
/// when this cover is the song that is playing or paused.
struct LeadCover: View {
    let album: WidgetSnapshot.Album
    let isPlaying: Bool
    var opensNowPlaying = false
    var cornerRadius: CGFloat = 14
    var buttonSize: CGFloat = 34

    var body: some View {
        Link(destination: opensNowPlaying ? WidgetLink.nowPlaying : WidgetLink.album(id: album.id)) {
            CoverTile(album: album, pixels: WidgetStore.heroPixels, cornerRadius: cornerRadius)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 6)
        }
        .overlay(alignment: .bottomTrailing) {
            PlayButton(album: album, isPlaying: isPlaying, size: buttonSize)
                .padding(buttonSize * 0.2)
        }
        .accessibilityLabel("\(album.title), \(album.artist)")
    }
}

/// A row of up to four covers under an eyebrow; each opens its album. Short rows keep the tile size.
struct Shelf: View {
    var title: String? = nil
    let albums: [WidgetSnapshot.Album]
    var columns = 4
    var spacing: CGFloat = 8
    var cornerRadius: CGFloat = 9

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title {
                Eyebrow(text: title)
            }
            HStack(spacing: spacing) {
                ForEach(albums.prefix(columns)) { album in
                    SquareCell {
                        Link(destination: WidgetLink.album(id: album.id)) {
                            CoverTile(album: album, cornerRadius: cornerRadius)
                                .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                        }
                        .accessibilityLabel("\(album.title), \(album.artist)")
                    }
                }
                ForEach(0..<max(0, columns - min(columns, albums.count)), id: \.self) { _ in
                    SquareCell { Color.clear }
                }
            }
        }
    }
}

/// An equal share of the row, square, with the content laid over it; every cell measures the same
/// whatever it holds, so short rows keep the tile size of full ones.
struct SquareCell<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        Color.clear
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .overlay { content() }
    }
}

/// A playlist's face: the app's generated artwork for its own lists, a mosaic of covers for yours.
struct PlaylistFace: View {
    let playlist: WidgetSnapshot.PlaylistInfo
    var cornerRadius: CGFloat = 9

    private var colors: [String] {
        switch playlist.kind {
        case .favourites: ["#ff7a95", "#d4234f", "#5e0b26"]
        case .mix: ["#8f7dff", "#4a2fd6", "#160b52"]
        case .recentlyPlayed: ["#5eead4", "#0d9488", "#083f3a"]
        case .shuffle: ["#fcd34d", "#ea580c", "#6b1d0b"]
        case .local: []
        }
    }

    private var symbol: String {
        switch playlist.kind {
        case .favourites: "heart.fill"
        case .mix: "sparkles"
        case .recentlyPlayed: "clock.fill"
        case .shuffle: "shuffle"
        case .local: "music.note.list"
        }
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                if playlist.kind == .local {
                    Mosaic(covers: playlist.covers)
                } else {
                    LinearGradient(colors: colors.map { WidgetImages.color(hex: $0) }, startPoint: .topLeading, endPoint: .bottomTrailing)
                    EllipticalGradient(colors: [.white.opacity(0.38), .clear], center: UnitPoint(x: 0.47, y: 0.42), startRadiusFraction: 0, endRadiusFraction: 0.65)
                    Image(systemName: symbol)
                        .font(.system(size: side * 0.42, weight: .semibold))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.22), radius: side * 0.03, y: side * 0.015)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .aspectRatio(1, contentMode: .fit)
        .clipShape(shape)
    }

    /// One cover fills the tile, two share it, three give the first the left half, four form a grid.
    private struct Mosaic: View {
        let covers: [WidgetSnapshot.Album]

        var body: some View {
            switch covers.count {
            case 0:
                ZStack {
                    Color.white.opacity(0.14)
                    Image(systemName: "music.note.list")
                        .font(.title3)
                        .foregroundStyle(.white.opacity(0.7))
                }
            case 1:
                face(covers[0])
            case 2:
                HStack(spacing: 0) {
                    face(covers[0])
                    face(covers[1])
                }
            case 3:
                HStack(spacing: 0) {
                    face(covers[0])
                    VStack(spacing: 0) {
                        face(covers[1])
                        face(covers[2])
                    }
                }
            default:
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        face(covers[0])
                        face(covers[1])
                    }
                    HStack(spacing: 0) {
                        face(covers[2])
                        face(covers[3])
                    }
                }
            }
        }

        private func face(_ album: WidgetSnapshot.Album) -> some View {
            Group {
                if let image = WidgetImages.cover(for: album, pixels: WidgetStore.tilePixels) {
                    Image(uiImage: image)
                        .resizable()
                        .widgetAccentedRenderingMode(.desaturated)
                        .scaledToFill()
                } else {
                    GradientFace(colorA: album.colorA, colorB: album.colorB)
                }
            }
            .clipped()
        }
    }
}

/// A playlist tile with its name, opening the playlist.
struct PlaylistTile: View {
    let playlist: WidgetSnapshot.PlaylistInfo
    var showsName = true

    var body: some View {
        Link(destination: WidgetLink.playlist(id: playlist.id)) {
            VStack(alignment: .leading, spacing: 5) {
                PlaylistFace(playlist: playlist)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
                if showsName {
                    Text(playlist.name)
                        .font(.caption2.weight(.medium))
                        .lineLimit(1)
                        .opacity(0.9)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityLabel("\(playlist.name), \(playlist.summary)")
    }
}

/// One timeline entry for the widgets that only change when the app says so.
nonisolated struct SnapshotEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
}

/// Shared provider: the app rewrites the snapshot and reloads whenever something changes. A second
/// entry later stops claiming "Now playing" if the app went away without a word.
nonisolated struct SnapshotProvider: TimelineProvider {
    func placeholder(in context: Context) -> SnapshotEntry {
        SnapshotEntry(date: .now, snapshot: .sample)
    }

    func getSnapshot(in context: Context, completion: @escaping (SnapshotEntry) -> Void) {
        completion(SnapshotEntry(date: .now, snapshot: context.isPreview ? .sample : (WidgetStore.load() ?? .empty)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SnapshotEntry>) -> Void) {
        let snapshot = WidgetStore.load() ?? .empty
        var entries = [SnapshotEntry(date: .now, snapshot: snapshot)]
        if snapshot.isPlaying {
            var later = snapshot
            later.isPlaying = false
            entries.append(SnapshotEntry(date: .now.addingTimeInterval(45 * 60), snapshot: later))
        }
        completion(Timeline(entries: entries, policy: .never))
    }
}

/// Nothing to show yet: the app's colours and a nudge.
struct EmptyFace: View {
    var symbol = "music.note"
    var title = "Skyr Music"
    var message = "Play something and it shows up here."

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: symbol)
                .font(.title2.weight(.semibold))
                .padding(.bottom, 4)
            Spacer(minLength: 0)
            Text(title)
                .font(.headline)
            Text(message)
                .font(.caption)
                .opacity(0.8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.31, blue: 0.62), Color(red: 0.11, green: 0.09, blue: 0.24)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}
