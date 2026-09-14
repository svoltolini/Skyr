import SkyrShared
import SwiftUI
import WidgetKit

/// An album from the library that has not been played in a while, with a new pick every three
/// hours. The picks come from a daily list in the snapshot; the timeline walks it on its own, so the
/// widget keeps changing even when the app is closed.
struct RediscoverWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "SkyrRediscover", provider: RediscoverProvider()) { entry in
            RediscoverView(snapshot: entry.snapshot, offset: entry.offset)
        }
        .configurationDisplayName("Rediscover")
        .description("An album you haven't played in a while, with a new pick every few hours.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

nonisolated struct RediscoverEntry: TimelineEntry {
    let date: Date
    let snapshot: WidgetSnapshot
    /// Which pick of the day's list leads at this moment.
    let offset: Int
}

nonisolated struct RediscoverProvider: TimelineProvider {
    private static let slot: TimeInterval = 3 * 3600

    func placeholder(in context: Context) -> RediscoverEntry {
        RediscoverEntry(date: .now, snapshot: .sample, offset: 0)
    }

    func getSnapshot(in context: Context, completion: @escaping (RediscoverEntry) -> Void) {
        let snapshot = context.isPreview ? WidgetSnapshot.sample : (WidgetStore.load() ?? .empty)
        completion(RediscoverEntry(date: .now, snapshot: snapshot, offset: Self.offset(for: .now, count: snapshot.rediscover.count)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<RediscoverEntry>) -> Void) {
        let snapshot = WidgetStore.load() ?? .empty
        let count = snapshot.rediscover.count
        guard count > 1 else {
            completion(Timeline(entries: [RediscoverEntry(date: .now, snapshot: snapshot, offset: 0)], policy: .never))
            return
        }
        // The pick is a function of the clock, so every reload agrees on which album is up.
        let now = Date.now
        let slotStart = Date(timeIntervalSince1970: floor(now.timeIntervalSince1970 / Self.slot) * Self.slot)
        var entries: [RediscoverEntry] = []
        for step in 0..<8 {
            let date = step == 0 ? now : slotStart.addingTimeInterval(Double(step) * Self.slot)
            entries.append(RediscoverEntry(date: date, snapshot: snapshot, offset: Self.offset(for: date, count: count)))
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }

    static func offset(for date: Date, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return Int(floor(date.timeIntervalSince1970 / slot)) % count
    }
}

private struct RediscoverView: View {
    let snapshot: WidgetSnapshot
    let offset: Int
    @Environment(\.widgetFamily) private var family

    private var pool: [WidgetSnapshot.Album] { snapshot.rediscover }
    private var pick: WidgetSnapshot.Album? { pool.isEmpty ? nil : pool[offset % pool.count] }

    /// The picks after this one, in the order the widget will show them.
    private func upcoming(_ limit: Int) -> [WidgetSnapshot.Album] {
        guard pool.count > 1 else { return [] }
        return (1...min(limit, pool.count - 1)).map { pool[(offset + $0) % pool.count] }
    }

    var body: some View {
        if let pick {
            switch family {
            case .systemSmall: small(pick)
            case .systemLarge: large(pick)
            default: medium(pick)
            }
        } else {
            EmptyFace(symbol: "sparkles", title: "Rediscover", message: "Once your library is in, an album you haven't played in a while appears here.")
                .widgetURL(WidgetLink.tab("library"))
        }
    }

    private func small(_ pick: WidgetSnapshot.Album) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                Eyebrow(text: "Rediscover", symbol: "sparkles")
                    .padding(.top, 6)
                Spacer(minLength: 6)
                PlayButton(album: pick, isPlaying: snapshot.isPlaying(pick), size: 28)
            }
            Spacer(minLength: 0)
            Text(pick.title)
                .font(.headline)
                .lineLimit(2)
                .minimumScaleFactor(0.85)
            Text(pick.artist)
                .font(.caption)
                .opacity(0.82)
                .lineLimit(1)
                .padding(.top, 1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .foregroundStyle(.white)
        .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
        .containerBackground(for: .widget) {
            CoverBackdrop(album: pick)
        }
        .widgetURL(WidgetLink.album(id: pick.id))
    }

    private func medium(_ pick: WidgetSnapshot.Album) -> some View {
        HStack(alignment: .bottom, spacing: 14) {
            LeadCover(album: pick, isPlaying: snapshot.isPlaying(pick))
                .frame(maxHeight: .infinity)
            VStack(alignment: .leading, spacing: 3) {
                Eyebrow(text: "Rediscover", symbol: "sparkles")
                Text(pick.title)
                    .font(.headline)
                    .lineLimit(2)
                    .padding(.top, 2)
                Text(pick.artist)
                    .font(.subheadline)
                    .opacity(0.8)
                    .lineLimit(1)
                if !pick.metaLine.isEmpty {
                    Text(pick.metaLine)
                        .font(.caption)
                        .opacity(0.65)
                        .lineLimit(1)
                        .padding(.top, 3)
                }
                Spacer(minLength: 6)
                Shelf(albums: upcoming(4), spacing: 8, cornerRadius: 7)
            }
            .frame(maxHeight: .infinity, alignment: .topLeading)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: pick.colorA, colorB: pick.colorB)
        }
    }

    private func large(_ pick: WidgetSnapshot.Album) -> some View {
        let next = upcoming(8)
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                LeadCover(album: pick, isPlaying: snapshot.isPlaying(pick))
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 3) {
                    Eyebrow(text: "Rediscover", symbol: "sparkles")
                    Text(pick.title)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                        .padding(.top, 2)
                    Text(pick.artist)
                        .font(.subheadline)
                        .opacity(0.8)
                        .lineLimit(1)
                    if !pick.metaLine.isEmpty {
                        Text(pick.metaLine)
                            .font(.caption)
                            .opacity(0.65)
                            .lineLimit(1)
                            .padding(.top, 3)
                    }
                }
                Spacer(minLength: 0)
            }
            if !next.isEmpty {
                Shelf(title: "Coming up", albums: Array(next.prefix(4)))
            }
            if next.count > 4 {
                Shelf(albums: Array(next.dropFirst(4)))
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .containerBackground(for: .widget) {
            PaletteBackdrop(colorA: pick.colorA, colorB: pick.colorB)
        }
    }
}
