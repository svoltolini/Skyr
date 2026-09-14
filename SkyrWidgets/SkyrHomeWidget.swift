import SkyrShared
import SwiftUI
import WidgetKit

/// The album playing (or played last) alone, with the recent shelf beside it, or with recently played
/// and recently added shelves under it.
struct SkyrHomeWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkyrHome", provider: SnapshotProvider()) { entry in
            HomeView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Now Playing")
        .description("What's playing, what you played last and what's new in your library.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct HomeView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let (album, lead) = snapshot.featured {
            switch family {
            case .systemSmall: SmallLayout(snapshot: snapshot, album: album, lead: lead)
            case .systemLarge: LargeLayout(snapshot: snapshot, album: album, lead: lead)
            default: MediumLayout(snapshot: snapshot, album: album, lead: lead)
            }
        } else {
            EmptyFace()
        }
    }
}

/// The lead cover fills the widget; the words sit on a scrim along the bottom, play in the top corner.
private struct SmallLayout: View {
    let snapshot: WidgetSnapshot
    let album: WidgetSnapshot.Album
    let lead: WidgetSnapshot.Lead

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                LeadEyebrow(lead: lead)
                    .padding(.top, 6)
                Spacer(minLength: 6)
                PlayButton(album: album, isPlaying: lead == .playing, size: 28)
            }
            Spacer(minLength: 0)
            Text(album.title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(album.artist)
                .font(.caption)
                .opacity(0.82)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        .containerBackground(for: .widget) {
            CoverBackdrop(album: album)
        }
        .widgetURL(WidgetLink.album(id: album.id))
    }
}

/// The lead cover as tall as the widget, its words beside it, and the recent albums in a row that
/// lines up with the bottom of the cover.
private struct MediumLayout: View {
    let snapshot: WidgetSnapshot
    let album: WidgetSnapshot.Album
    let lead: WidgetSnapshot.Lead

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            LeadCover(album: album, isPlaying: lead == .playing)
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                LeadEyebrow(lead: lead)
                Text(album.title)
                    .font(.headline)
                    .lineLimit(2)
                    .padding(.top, 2)
                Text(album.artist)
                    .font(.subheadline)
                    .opacity(0.8)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Shelf(albums: snapshot.others(limit: 4), spacing: 8, cornerRadius: 7)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: album.colorA, colorB: album.colorB)
        }
    }
}

/// The lead album on top, then a shelf of recently played and one of recently added covers.
private struct LargeLayout: View {
    let snapshot: WidgetSnapshot
    let album: WidgetSnapshot.Album
    let lead: WidgetSnapshot.Lead

    private var played: [WidgetSnapshot.Album] {
        Array(snapshot.recentlyPlayed.filter { $0.id != album.id }.prefix(4))
    }

    private var added: [WidgetSnapshot.Album] {
        Array(snapshot.recentlyAdded.filter { $0.id != album.id && !played.contains($0) }.prefix(4))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                LeadCover(album: album, isPlaying: lead == .playing)
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 3) {
                    LeadEyebrow(lead: lead)
                    Text(album.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .padding(.top, 2)
                    Text(album.artist)
                        .font(.subheadline)
                        .opacity(0.8)
                        .lineLimit(1)
                    if lead == .playing || lead == .paused, let title = snapshot.trackTitle {
                        Text(title)
                            .font(.caption)
                            .opacity(0.65)
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            if !played.isEmpty {
                Shelf(title: "Recently played", albums: played)
            }
            if !added.isEmpty {
                Shelf(title: "Recently added", albums: added)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: album.colorA, colorB: album.colorB)
        }
    }
}
