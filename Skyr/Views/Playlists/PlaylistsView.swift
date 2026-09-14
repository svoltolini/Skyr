import SkyrCore
import SwiftUI

/// Playlists tab: the lists the app keeps for you, then the ones you made.
struct PlaylistsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var isNamingPlaylist = false
    @State private var newPlaylistName = ""
    @State private var renaming: Playlist?
    @State private var renameText = ""
    @State private var deleting: Playlist?
    @Namespace private var artworkNamespace

    @Environment(\.isWideLayout) private var isWide
    private var columns: [GridItem] { Grids.cards(wide: isWide) }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SectionHeader(title: "Made for you")
                        .padding(.top, 4)
                    LazyVGrid(columns: columns, spacing: 18) {
                        PlaylistCard(playlist: library.favouritesPlaylist, subtitle: "Every song you favourite")
                        PlaylistCard(playlist: library.favouritesMixPlaylist, subtitle: "Favourites and songs like them")
                        PlaylistCard(playlist: library.recentlyPlayedPlaylist, subtitle: "The last 100 songs you played")
                        PlaylistCard(playlist: library.libraryShufflePlaylist, subtitle: "50 songs, new every day")
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 12)

                    SectionHeader(title: "Your playlists", actionTitle: "New") {
                        newPlaylistName = ""
                        isNamingPlaylist = true
                    }
                    .padding(.top, 32)
                    if library.playlists.isEmpty {
                        Text("Playlists you make appear here.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 24)
                            .padding(.top, 10)
                    } else {
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(library.playlists) { playlist in
                                PlaylistCard(playlist: playlist, subtitle: nil)
                                    .contextMenu {
                                        if library.isLocalPlaylist(playlist.id) {
                                            Button("Rename", systemImage: "pencil") {
                                                renameText = playlist.name
                                                renaming = playlist
                                            }
                                            Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                                                deleting = playlist
                                            }
                                        }
                                    }
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, 12)
                        .animation(.snappy(duration: 0.3), value: library.playlists.map(\.id))
                    }
                }
                .padding(.bottom, 32)
            }
            .skyrBackground(player.tint)
            .navigationTitle("Playlists")
            .alert("New Playlist", isPresented: $isNamingPlaylist) {
                TextField("Name", text: $newPlaylistName)
                Button("Create") {
                    library.createPlaylist(named: newPlaylistName)
                    newPlaylistName = ""
                }
                Button("Cancel", role: .cancel) {
                    newPlaylistName = ""
                }
            } message: {
                Text("Give your playlist a name.")
            }
            .alert("Rename Playlist", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Rename") {
                    if let renaming { library.renamePlaylist(id: renaming.id, to: renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
            .confirmationDialog(
                "Delete “\(deleting?.name ?? "")”?",
                isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } }),
                titleVisibility: .visible
            ) {
                Button("Delete Playlist", role: .destructive) {
                    if let deleting { library.deletePlaylist(id: deleting.id) }
                    deleting = nil
                }
            } message: {
                Text("The songs stay in your library.")
            }
            .libraryDestinations()
            // A playlist tapped on a Home Screen widget.
            .navigationDestination(item: $model.playlistToOpen) { PlaylistDetailView(playlist: $0) }
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }
}

/// Square cover with the name and a line of detail, like an album card.
struct PlaylistCard: View {
    let playlist: Playlist
    /// Replaces the song count for the app's own lists.
    var subtitle: String?

    var body: some View {
        let destination = PlaylistDestination(playlist, source: "playlists")
        NavigationLink(value: destination) {
            VStack(alignment: .leading, spacing: 2) {
                PlaylistCover(playlist: playlist, cornerRadius: 12)
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 8)
                    .zoomSource(id: destination.sourceID, shape: .rounded(12), shadow: .tile)
                    .padding(.bottom, 8)
                FadingText(playlist.name)
                    .font(.subheadline.weight(.medium))
                FadingText(subtitle ?? playlist.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .cardButton()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(playlist.name), \(subtitle ?? playlist.summary)")
    }
}

/// Songs of one playlist with play and shuffle. Your own playlists can be renamed or deleted here.
struct PlaylistDetailView: View {
    let playlist: Playlist
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @State private var addingTrack: Track?
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    @State private var isConfirmingRemoval = false
    @Environment(\.dismiss) private var dismiss

    /// The playlist as it is right now, since favourites and contents change while the page is open.
    private var live: Playlist { library.playlist(id: playlist.id) ?? playlist }
    private var isLocal: Bool { library.isLocalPlaylist(playlist.id) }
    /// Your own lists and Favourites can be kept on the iPhone; the mixes change on their own, so they cannot.
    private var canDownload: Bool { playlist.kind == .local || playlist.id == Playlist.favouritesID }

    var body: some View {
        let playlist = live
        ScrollView {
            VStack(spacing: 0) {
                DetailHeader(coverSize: 200) {
                    PlaylistCover(playlist: playlist, cornerRadius: 14)
                        .shadow(color: .black.opacity(0.35), radius: 24, y: 16)
                } titles: {
                    Text(playlist.name)
                        .font(Fonts.pageTitle)
                    Text(playlist.summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } actions: {
                    HStack(spacing: 10) {
                        PlayActions {
                            player.play(queue: playlist.tracks, startingAt: 0, title: playlist.name)
                        } shuffle: {
                            player.play(queue: playlist.tracks.shuffled(), startingAt: 0, title: playlist.name)
                        }
                        #if !os(tvOS)
                        if canDownload {
                            downloadButton(for: playlist)
                        }
                        #endif
                    }
                    .disabled(playlist.tracks.isEmpty)
                }

                if playlist.tracks.isEmpty {
                    EmptyStateView(title: emptyTitle, systemImage: emptySymbol, message: emptyDescription, centered: false)
                } else {
                    // Lazy: Recently played holds a hundred songs and only the visible rows need to exist.
                    LazyVStack(spacing: 0) {
                        ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { position, track in
                            PlaylistTrackRow(track: track, position: position, playlist: playlist, isLocal: isLocal, addingTrack: $addingTrack)
                            if position < playlist.tracks.count - 1 {
                                Divider().padding(.leading, 58)
                            }
                        }
                    }
                    .padding(.top, 18)
                    .animation(.snappy(duration: 0.3), value: playlist.tracks.map(\.id))
                }
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .skyrBackground(player.tint)
        .inlineTitle()
        .windowTitle(playlist.name, subtitle: playlist.summary)
        .toolbar {
            if isLocal {
                ToolbarItem(placement: .trailingBar) {
                    Menu {
                        Button("Rename", systemImage: "pencil") {
                            renameText = playlist.name
                            isRenaming = true
                        }
                        Button("Delete Playlist", systemImage: "trash", role: .destructive) {
                            isConfirmingDelete = true
                        }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(item: $addingTrack) { track in
            AddToPlaylistSheet(tracks: [track])
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") { library.renamePlaylist(id: playlist.id, to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(playlist.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                library.deletePlaylist(id: playlist.id)
                dismiss()
            }
        } message: {
            Text("The songs stay in your library.")
        }
    }
}

extension PlaylistDetailView {
    /// Same control as on an album: songs already downloaded for an album are shared, not fetched again.
    private func downloadButton(for playlist: Playlist) -> some View {
        let owner = downloads.owner(for: playlist)
        return DownloadButton(state: downloads.state(for: owner)) {
            switch downloads.state(for: owner) {
        case .none, .failed, .partial, .cancelled:
                downloads.download(owner, driveID: library.catalogue.driveID, isSample: library.isDemo) { track in
                    library.streamURL(for: track, quality: .original)
                }
            case .downloading:
                downloads.cancel(owner)
            case .downloaded:
                isConfirmingRemoval = true
            }
        }
        .confirmationDialog("Remove this playlist from your \(Device.noun)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { downloads.remove(owner) }
        } message: {
            Text("The playlist stays; songs a downloaded album still needs are kept.")
        }
    }

    private var emptyTitle: String {
        switch playlist.id {
        case Playlist.favouritesID: "No Favourites Yet"
        case Playlist.favouritesMixID: "Nothing to Mix Yet"
        case Playlist.recentlyPlayedID: "Nothing Played Yet"
        case Playlist.libraryShuffleID: "Nothing to Shuffle"
        default: "No Songs"
        }
    }

    private var emptySymbol: String {
        switch playlist.id {
        case Playlist.favouritesID, Playlist.favouritesMixID: "heart"
        case Playlist.recentlyPlayedID: "clock"
        case Playlist.libraryShuffleID: "shuffle"
        default: "music.note.list"
        }
    }

    private var emptyDescription: String {
        switch playlist.id {
        case Playlist.favouritesID, Playlist.favouritesMixID: "\(Hints.songMenu) on any song and choose Favourite."
        case Playlist.recentlyPlayedID: "Songs you play show up here, newest first."
        case Playlist.libraryShuffleID: "Add music to your library first."
        default: "\(Hints.songMenu) on a song and choose Add to Playlist."
        }
    }
}

/// One song of a playlist: tap to play, "…" to favourite, add to another playlist or remove it.
private struct PlaylistTrackRow: View {
    let track: Track
    let position: Int
    let playlist: Playlist
    let isLocal: Bool
    @Binding var addingTrack: Track?
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        HStack(spacing: 0) {
            Button {
                player.play(queue: playlist.tracks, startingAt: position, title: playlist.name)
            } label: {
                HStack(spacing: 14) {
                    if let album = library.album(for: track) {
                        ArtworkView(album: album, cornerRadius: 6, highlight: false, size: .row)
                            .frame(width: 44, height: 44)
                    } else {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(.quaternary)
                            .frame(width: 44, height: 44)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        FadingText(track.title)
                            .font(.body.weight(player.isCurrent(track: track) ? .semibold : .regular))
                        FadingText(library.album(for: track).map { "\($0.artist) · \($0.title)" } ?? track.artist ?? " ")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    if library.isFavourite(track) {
                        FavouriteMark()
                            .transition(.scale.combined(with: .opacity))
                    }
                    if let fraction = downloads.progress[track.id] {
                        MiniProgressRing(fraction: fraction)
                            .transition(.scale.combined(with: .opacity))
                    } else if downloads.isQueued(track) {
                        Circle()
                            .stroke(.quaternary, lineWidth: 2)
                            .frame(width: 13, height: 13)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel("Waiting to download")
                    } else if downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .transition(.scale.combined(with: .opacity))
                            .accessibilityLabel("Downloaded")
                    }
                    Text(TimeText.clock(track.duration))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .animation(.snappy(duration: 0.3), value: downloads.isDownloaded(track))
                .animation(.snappy(duration: 0.3), value: library.isFavourite(track))
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())

            TrackActionsMenu(
                track: track,
                onRemove: isLocal ? { withAnimation(.snappy(duration: 0.3)) { library.remove(track, fromPlaylist: playlist.id) } } : nil,
                isAddingToPlaylist: Binding(get: { addingTrack?.id == track.id }, set: { addingTrack = $0 ? track : nil })
            )
            .padding(.leading, 2)
        }
    }
}
