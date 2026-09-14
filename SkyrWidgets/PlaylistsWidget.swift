import SkyrShared
import SwiftUI
import WidgetKit

/// Your playlists: the app's own lists and the ones you made.
struct PlaylistsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkyrPlaylists", provider: SnapshotProvider()) { entry in
            PlaylistsView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Playlists")
        .description("Favourites, your mixes and the playlists you made, one tap away.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct PlaylistsView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    /// Favourites' colours for the backdrop, so the widget reads as the Playlists tab does.
    private let colorA = "#d4234f"
    private let colorB = "#5e0b26"

    var body: some View {
        if snapshot.playlists.isEmpty {
            EmptyFace(symbol: "music.note.list", title: "Playlists", message: "Your lists show up here once the library is in.")
                .widgetURL(WidgetLink.tab("playlists"))
        } else {
            switch family {
            case .systemSmall: small
            case .systemLarge: large
            default: medium
            }
        }
    }

    /// Four faces in a grid, no names; the whole widget opens the Playlists tab.
    private var small: some View {
        let shown = Array(snapshot.playlists.prefix(4))
        return VStack(alignment: .leading, spacing: 8) {
            Eyebrow(text: "Playlists", symbol: "music.note.list")
            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    ForEach(shown.prefix(2)) { playlist in PlaylistFace(playlist: playlist, cornerRadius: 9) }
                }
                GridRow {
                    ForEach(shown.dropFirst(2).prefix(2)) { playlist in PlaylistFace(playlist: playlist, cornerRadius: 9) }
                }
            }
            .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: colorA, colorB: colorB)
        }
        .widgetURL(WidgetLink.tab("playlists"))
    }

    /// The first four playlists with their names; each opens its list.
    private var medium: some View {
        VStack(alignment: .leading, spacing: 8) {
            Link(destination: WidgetLink.tab("playlists")) {
                Eyebrow(text: "Playlists", symbol: "music.note.list")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(snapshot.playlists.prefix(4)) { playlist in
                    PlaylistTile(playlist: playlist)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: colorA, colorB: colorB)
        }
    }

    /// Eight playlists in two rows: the app's own lists first, then yours.
    private var large: some View {
        let shown = Array(snapshot.playlists.prefix(8))
        return VStack(alignment: .leading, spacing: 14) {
            Link(destination: WidgetLink.tab("playlists")) {
                Eyebrow(text: "Playlists", symbol: "music.note.list")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack(alignment: .top, spacing: 10) {
                ForEach(shown.prefix(4)) { playlist in
                    PlaylistTile(playlist: playlist)
                }
            }
            if shown.count > 4 {
                Eyebrow(text: "Your playlists")
                    .padding(.top, 2)
                HStack(alignment: .top, spacing: 10) {
                    ForEach(shown.dropFirst(4)) { playlist in
                        PlaylistTile(playlist: playlist)
                    }
                    ForEach(0..<max(0, 8 - shown.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).aspectRatio(1, contentMode: .fit)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: colorA, colorB: colorB)
        }
    }
}
