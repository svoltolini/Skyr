import SkyrCore
import SwiftUI

/// Every playlist the phone shared, with a note on whether it is on the watch already.
struct PlaylistsListView: View {
    @Environment(WatchStore.self) private var store
    @Environment(WatchDownloads.self) private var downloads

    var body: some View {
        List(store.catalogue?.playlists ?? []) { playlist in
            NavigationLink(value: playlist) {
                PlaylistRow(playlist: playlist, state: downloads.state(of: playlist))
            }
        }
        .listStyle(.carousel)
        .navigationTitle("Playlists")
        .navigationDestination(for: WatchPlaylist.self) { playlist in
            PlaylistDetailView(playlist: playlist)
        }
    }
}

private struct PlaylistRow: View {
    let playlist: WatchPlaylist
    let state: WatchDownloads.State

    var body: some View {
        HStack(spacing: 10) {
            MosaicView(colours: playlist.coverColours, cornerRadius: 8)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(playlist.name)
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
    }

    private var detail: String {
        let songs = "\(playlist.tracks.count) songs"
        switch state {
        case .downloaded: return "\(songs) · On watch"
        case .downloading(let done, let total): return "Downloading \(done) of \(total)"
        case .failed: return "\(songs) · Download failed"
        case .none: return "\(songs) · \(ByteText.format(playlist.totalBytes))"
        }
    }
}

/// Four gradient tiles from the playlist's covers; fewer covers repeat to fill the square.
struct MosaicView: View {
    let colours: [WatchColourPair]
    var cornerRadius: CGFloat = 8

    var body: some View {
        let pairs = colours.isEmpty ? [WatchColourPair(a: "#4a5568", b: "#141821")] : colours
        Grid(horizontalSpacing: 0, verticalSpacing: 0) {
            ForEach(0..<2, id: \.self) { row in
                GridRow {
                    ForEach(0..<2, id: \.self) { column in
                        let pair = pairs[(row * 2 + column) % pairs.count]
                        LinearGradient(colors: [Color(hex: pair.a), Color(hex: pair.b)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}
