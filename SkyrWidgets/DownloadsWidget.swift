import SkyrShared
import SwiftUI
import WidgetKit

/// The albums kept on this iPhone, ready to play without the server.
struct DownloadsWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkyrDownloads", provider: SnapshotProvider()) { entry in
            DownloadsView(snapshot: entry.snapshot)
        }
        .configurationDisplayName("Downloads")
        .description("The albums on your iPhone, ready to play anywhere.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct DownloadsView: View {
    let snapshot: WidgetSnapshot
    @Environment(\.widgetFamily) private var family

    var body: some View {
        if let lead = snapshot.downloads.first {
            switch family {
            case .systemSmall: SmallLayout(snapshot: snapshot, lead: lead)
            case .systemLarge: LargeLayout(snapshot: snapshot, lead: lead)
            default: MediumLayout(snapshot: snapshot, lead: lead)
            }
        } else {
            EmptyFace(symbol: "arrow.down.circle", title: "Downloads", message: "Tap the arrow on an album to keep it on this iPhone.")
                .widgetURL(WidgetLink.tab("downloads"))
        }
    }
}

/// A fan of the latest downloaded covers; the whole widget opens the Downloads tab.
private struct SmallLayout: View {
    let snapshot: WidgetSnapshot
    let lead: WidgetSnapshot.Album

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Eyebrow(text: "On this iPhone", symbol: "arrow.down.circle.fill")
            Spacer(minLength: 0)
            // Three covers fanned out; the span stays inside the narrowest widget.
            ZStack(alignment: .leading) {
                ForEach(Array(snapshot.downloads.prefix(3).enumerated().reversed()), id: \.element.id) { index, album in
                    CoverTile(album: album, cornerRadius: 11)
                        .frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
                        .rotationEffect(.degrees(Double(index) * 5 - 5), anchor: .bottomLeading)
                        .offset(x: CGFloat(index) * 21)
                }
            }
            .padding(.leading, 2)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: lead.colorA, colorB: lead.colorB)
        }
        .widgetURL(WidgetLink.tab("downloads"))
    }
}

/// The newest download as the lead, its name beside it, and four more covers along the bottom.
private struct MediumLayout: View {
    let snapshot: WidgetSnapshot
    let lead: WidgetSnapshot.Album

    var body: some View {
        HStack(alignment: .bottom, spacing: 14) {
            LeadCover(album: lead, isPlaying: snapshot.isPlaying(lead))
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Link(destination: WidgetLink.tab("downloads")) {
                    Eyebrow(text: "On this iPhone", symbol: "arrow.down.circle.fill")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text(lead.title)
                    .font(.headline)
                    .lineLimit(2)
                    .padding(.top, 2)
                Text(lead.artist)
                    .font(.subheadline)
                    .opacity(0.8)
                    .lineLimit(1)
                Spacer(minLength: 6)
                Shelf(albums: Array(snapshot.downloads.dropFirst().prefix(4)), spacing: 8, cornerRadius: 7)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: lead.colorA, colorB: lead.colorB)
        }
    }
}

/// The lead download with its name, then two rows of the rest.
private struct LargeLayout: View {
    let snapshot: WidgetSnapshot
    let lead: WidgetSnapshot.Album

    var body: some View {
        let rest = Array(snapshot.downloads.dropFirst())
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                LeadCover(album: lead, isPlaying: snapshot.isPlaying(lead))
                    .frame(width: 112, height: 112)
                Link(destination: WidgetLink.tab("downloads")) {
                    VStack(alignment: .leading, spacing: 3) {
                        Eyebrow(text: "On this iPhone", symbol: "arrow.down.circle.fill")
                        Text(lead.title)
                            .font(.title3.weight(.semibold))
                            .lineLimit(2)
                            .padding(.top, 2)
                        Text(lead.artist)
                            .font(.subheadline)
                            .opacity(0.8)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !rest.isEmpty {
                Shelf(title: "Also on this iPhone", albums: Array(rest.prefix(4)))
            }
            if rest.count > 4 {
                Shelf(albums: Array(rest.dropFirst(4).prefix(4)))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: lead.colorA, colorB: lead.colorB)
        }
    }
}
