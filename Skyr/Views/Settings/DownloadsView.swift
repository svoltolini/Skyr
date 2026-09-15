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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    @Environment(\.isWideLayout) private var isWide
    private var columns: [GridItem] { Grids.cards(wide: isWide) }
    /// Listed downloads with songs neither saved nor on their way, offered as one bulk fetch.
    @State private var missing: [DownloadOwner] = []

    private struct MissingRequest: Equatable {
        let revision: UInt64
        let ownerIDs: [String]
    }

    var body: some View {
        let listed = downloads.listedOwnerIDs
        let albums = library.albums.filter { listed.contains(downloads.owner(for: $0).id) }
        let playlists = ([library.favouritesPlaylist] + library.playlists).filter { listed.contains(downloads.owner(for: $0).id) }
        let owners = playlists.map { downloads.owner(for: $0) } + albums.map { downloads.owner(for: $0) }
        let unused = downloads.unusedStorage
        ScrollView {
            if albums.isEmpty && playlists.isEmpty {
                VStack(spacing: 0) {
                    if !unused.isEmpty { DownloadsStorageCard(unused: unused, missing: []) }
                    EmptyStateView(
                        title: "No Downloads",
                        systemImage: "arrow.down.circle",
                        message: "Use the download button on an album or playlist to keep it on this \(Device.noun) and play it without the server.",
                        centered: unused.isEmpty
                    )
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    if !unused.isEmpty || !missing.isEmpty {
                        DownloadsStorageCard(unused: unused, missing: missing)
                    }
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
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: albums.map(\.id) + playlists.map(\.id))
            }
        }
        .skyrBackground(player.tint)
        .navigationTitle("Downloads")
        // The folder is read again each time the screen opens, so the figure matches what is there now.
        .task { downloads.refreshUnusedStorage() }
        // Manifest-only arithmetic, kept out of the body and redone when download state moves.
        .task(id: MissingRequest(revision: downloads.stateRevision, ownerIDs: owners.map(\.id))) {
            missing = owners.filter { downloads.missingCount(for: $0) > 0 }
        }
    }
}

/// What needs a decision before the grids: space no download here uses, and downloads restored from
/// iCloud whose songs are not on this device yet. Absent when there is nothing to decide.
private struct DownloadsStorageCard: View {
    let unused: UnusedDownloadStorage
    let missing: [DownloadOwner]
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @State private var isConfirmingRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            if !unused.isEmpty {
                row(symbol: "externaldrive.badge.xmark", tint: .orange,
                    title: "\(ByteText.format(unused.bytes)) not in use",
                    detail: unusedDetail) {
                    Button("Remove", role: .destructive) { isConfirmingRemoval = true }
                }
            }
            if !unused.isEmpty && !missing.isEmpty {
                Divider().padding(.leading, 60)
            }
            if !missing.isEmpty {
                row(symbol: "icloud.and.arrow.down", tint: .blue,
                    title: missing.count == 1 ? "1 download is missing songs" : "\(missing.count) downloads are missing songs",
                    detail: "Restored from iCloud. Songs already on this \(Device.noun) are kept; only the rest come down.") {
                    Button("Download") { downloadMissing() }
                }
            }
        }
        .background(Color.groupedCard, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 18)
        .confirmationDialog("Remove \(ByteText.format(unused.bytes)) not in use?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Files", role: .destructive) { downloads.removeUnused() }
        } message: {
            Text("These files aren’t part of any download on this \(Device.noun). Anything a family profile or another library still needs can be downloaded again.")
        }
    }

    private var unusedDetail: String {
        var text = "Left behind by earlier downloads; no album or playlist here uses these files."
        if unused.otherLibraryBytes > 0 {
            text += " \(ByteText.format(unused.otherLibraryBytes)) belong to a library this \(Device.noun) isn’t signed in to."
        }
        return text
    }

    private func downloadMissing() {
        for owner in missing {
            downloads.download(owner, driveID: library.catalogue.driveID, isSample: library.isDemo) {
                library.streamURL(for: $0, quality: .original)
            }
        }
    }

    private func row<Action: View>(symbol: String, tint: Color, title: String, detail: String, @ViewBuilder action: () -> Action) -> some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            action()
                .buttonStyle(.glass)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .accessibilityElement(children: .contain)
    }
}

/// One downloaded album: cover, title, artist, and a ring or count only while something is missing.
private struct DownloadedAlbumTile: View {
    let album: Album
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @State private var isConfirmingRemoval = false

    var body: some View {
        let destination = AlbumDestination(album, source: "downloads")
        let owner = downloads.owner(for: album)
        DownloadStateReader(owner: owner) { currentState in
            let state = currentState ?? .none
            NavigationLink(value: destination) {
                DownloadTileLabel(
                    title: album.title,
                    detail: currentState == nil
                        ? "Checking downloads…" : state.detail(complete: album.artist, downloaded: 0, total: album.tracks.count),
                    state: state
                ) {
                    ArtworkView(album: album, cornerRadius: 12)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                        .artworkSource(destination, cornerRadius: 12, shadow: .tile)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if currentState != nil {
                    if state != .downloaded && !state.isDownloading {
                        Button("Retry Missing Songs", systemImage: "arrow.clockwise") {
                            downloads.download(owner, driveID: library.catalogue.driveID, isSample: library.isDemo) {
                                library.streamURL(for: $0, quality: .original)
                            }
                        }
                    }
                    Button("Remove Download", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
                }
            }
            .confirmationDialog(
                "Remove “\(album.title)” from your \(Device.noun)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible
            ) {
                Button("Remove Download", role: .destructive) { downloads.remove(owner) }
            } message: {
                Text("The songs stay on your server.")
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// One downloaded playlist: its cover, name, and song count or progress.
private struct DownloadedPlaylistTile: View {
    let playlist: Playlist
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @State private var isConfirmingRemoval = false

    var body: some View {
        let destination = PlaylistDestination(playlist, source: "downloads")
        let owner = downloads.owner(for: playlist)
        DownloadStateReader(owner: owner) { currentState in
            let state = currentState ?? .none
            NavigationLink(value: destination) {
                DownloadTileLabel(
                    title: playlist.name,
                    detail: currentState == nil
                        ? "Checking downloads…" : state.detail(complete: playlist.summary, downloaded: 0, total: playlist.tracks.count),
                    state: state
                ) {
                    PlaylistCover(playlist: playlist, cornerRadius: 12)
                        .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                        .zoomSource(id: destination.sourceID, shape: .rounded(12), shadow: .tile)
                }
            }
            .buttonStyle(.plain)
            .contextMenu {
                if currentState != nil {
                    if state != .downloaded && !state.isDownloading {
                        Button("Retry Missing Songs", systemImage: "arrow.clockwise") {
                            downloads.download(owner, driveID: library.catalogue.driveID, isSample: library.isDemo) {
                                library.streamURL(for: $0, quality: .original)
                            }
                        }
                    }
                    Button("Remove Download", systemImage: "trash", role: .destructive) { isConfirmingRemoval = true }
                }
            }
            .confirmationDialog(
                "Remove “\(playlist.name)” from your \(Device.noun)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible
            ) {
                Button("Remove Download", role: .destructive) { downloads.remove(owner) }
            } message: {
                Text("The playlist stays; songs a downloaded album still needs are kept.")
            }
            .accessibilityElement(children: .combine)
        }
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
                    switch state {
                    case .downloading(let fraction, _, _):
                        MiniProgressRing(fraction: fraction)
                            .padding(6)
                            .background(.thinMaterial, in: Circle())
                            .padding(8)
                    case .failed, .partial, .cancelled:
                        Image(systemName: "arrow.clockwise")
                            .font(.footnote.weight(.semibold))
                            .padding(8)
                            .background(.thinMaterial, in: Circle())
                            .padding(8)
                    case .none, .downloaded:
                        EmptyView()
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
        case .failed: "Download failed · Retry available"
        case .partial(let done, let total, _): "\(done) of \(total) saved · Retry available"
        case .cancelled(let done, let total): "Cancelled · \(done) of \(total) saved"
        }
    }
}
