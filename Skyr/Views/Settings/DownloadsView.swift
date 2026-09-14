import SkyrCore
import SwiftUI

/// Downloads tab: its own navigation stack so albums and playlists can be opened from it.
struct DownloadsTabView: View {
    @Namespace private var artworkNamespace

    var body: some View {
        NavigationStack {
            DownloadsView()
                .libraryDestinations()
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }
}

/// Albums and playlists kept on this \(Device.noun), as grids of covers. Anything still coming down shows its ring.
struct DownloadsView: View {
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    @Environment(\.isWideLayout) private var isWide
    private var columns: [GridItem] { Grids.cards(wide: isWide) }

    var body: some View {
        let listed = downloads.listedOwnerIDs
        let albums = library.albums.filter { listed.contains(downloads.owner(for: $0).id) }
        let playlists = ([library.favouritesPlaylist] + library.playlists).filter { listed.contains(downloads.owner(for: $0).id) }
        ScrollView {
            if albums.isEmpty && playlists.isEmpty {
                EmptyStateView(
                    title: "No Downloads",
                    systemImage: "arrow.down.circle",
                    message: "Use the download button on an album or playlist to keep it on this \(Device.noun) and play it without the server."
                )
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !playlists.isEmpty {
                        if !albums.isEmpty { Eyebrow(text: "Playlists") }
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(playlists) { playlist in
                                DownloadedPlaylistTile(playlist: playlist)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, albums.isEmpty ? 4 : 10)
                    }
                    if !albums.isEmpty {
                        if !playlists.isEmpty {
                            Eyebrow(text: "Albums")
                                .padding(.top, 26)
                        }
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(albums) { album in
                                DownloadedAlbumTile(album: album)
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, playlists.isEmpty ? 4 : 10)
                    }
                }
                .padding(.bottom, 32)
                .animation(.snappy(duration: 0.3), value: albums.map(\.id) + playlists.map(\.id))
            }
        }
        .skyrBackground(player.tint)
        .navigationTitle("Downloads")
    }
}

/// One downloaded album: cover, title, artist, and a ring or count only while something is missing.
private struct DownloadedAlbumTile: View {
    let album: Album
    @Environment(DownloadManager.self) private var downloads
    @State private var isConfirmingRemoval = false

    var body: some View {
        let destination = AlbumDestination(album, source: "downloads")
        let owner = downloads.owner(for: album)
        let state = downloads.state(for: owner)
        NavigationLink(value: destination) {
            DownloadTileLabel(title: album.title, detail: state.detail(complete: album.artist, downloaded: downloads.downloadedCount(for: owner), total: album.tracks.count), state: state) {
                ArtworkView(album: album, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                    .artworkSource(destination, cornerRadius: 12, shadow: .tile)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove Download", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
        }
        .confirmationDialog("Remove “\(album.title)” from your \(Device.noun)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { downloads.remove(owner) }
        } message: {
            Text("The songs stay on your server.")
        }
        .accessibilityElement(children: .combine)
    }
}

/// One downloaded playlist: its cover, name, and song count or progress.
private struct DownloadedPlaylistTile: View {
    let playlist: Playlist
    @Environment(DownloadManager.self) private var downloads
    @State private var isConfirmingRemoval = false

    var body: some View {
        let destination = PlaylistDestination(playlist, source: "downloads")
        let owner = downloads.owner(for: playlist)
        let state = downloads.state(for: owner)
        NavigationLink(value: destination) {
            DownloadTileLabel(title: playlist.name, detail: state.detail(complete: playlist.summary, downloaded: downloads.downloadedCount(for: owner), total: playlist.tracks.count), state: state) {
                PlaylistCover(playlist: playlist, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                    .zoomSource(id: destination.sourceID, shape: .rounded(12), shadow: .tile)
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Remove Download", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
        }
        .confirmationDialog("Remove “\(playlist.name)” from your \(Device.noun)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { downloads.remove(owner) }
        } message: {
            Text("The playlist stays; songs a downloaded album still needs are kept.")
        }
        .accessibilityElement(children: .combine)
    }
}

/// Cover with a progress badge, name and one status line, shared by album and playlist tiles.
private struct DownloadTileLabel<Cover: View>: View {
    let title: String
    let detail: String
    let state: DownloadState
    @ViewBuilder let cover: () -> Cover

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            cover()
                .overlay(alignment: .bottomTrailing) {
                    if case .downloading(let fraction, _, _) = state {
                        MiniProgressRing(fraction: fraction)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                            .padding(8)
                    }
                }
                .padding(.bottom, 8)
            FadingText(title)
                .font(.subheadline.weight(.medium))
            FadingText(detail)
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())
    }
}

private extension DownloadState {
    /// The tile's second line: progress while downloading, the given text once complete, else how much is here.
    func detail(complete: String, downloaded: Int, total: Int) -> String {
        switch self {
        case .downloading(_, let done, let total): "Downloading \(done + 1) of \(total)"
        case .downloaded: complete
        case .none: "\(downloaded) of \(total) songs"
        }
    }
}
