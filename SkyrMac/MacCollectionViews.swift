import SkyrCore
import SwiftUI

/// A menu or button may outlive the collection that was visible when it was created.
struct MacLibraryActionScope: Equatable {
    private let sourceID: String
    private let profileID: String?
    private let sessionID: UUID?

    init(library: LibraryStore, profiles: ProfileStore) {
        sourceID = library.catalogue.driveID
        profileID = profiles.activeID
        sessionID = profiles.sessionID
    }

    func isCurrent(library: LibraryStore, profiles: ProfileStore) -> Bool {
        profileID != nil && sessionID != nil && library.contentSourceID == sourceID
            && self == MacLibraryActionScope(library: library, profiles: profiles)
    }
}

/// Desktop collection pages leave most of the window available for the song table.
struct MacAlbumDetailView: View {
    let album: Album
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(ProfileStore.self) private var profiles
    @State private var entries: [TrackListEntry] = []
    @State private var songSummary = ""
    @State private var isRenaming = false
    /// The album's id once a rename gave it a new one, and a new id whose album is still being derived.
    @State private var renamedID: String?
    @State private var pendingID: String?

    private var currentID: String { renamedID ?? album.id }

    var body: some View {
        Group {
            if let current = library.album(id: currentID) {
                albumContent(current)
            } else if pendingID != nil {
                ProgressView("Updating album…")
                    .navigationTitle(album.title)
            } else {
                ContentUnavailableView("Album Unavailable", systemImage: "square.stack", description: Text("This album is no longer in the current library."))
                    .navigationTitle("Album Unavailable")
            }
        }
        .onChange(of: library.contentRevision) { _, _ in
            guard let pending = pendingID, library.album(id: pending) != nil else { return }
            renamedID = pending
            pendingID = nil
        }
        .sheet(isPresented: $isRenaming) {
            if let current = library.album(id: currentID) {
                AlbumRenameSheet(album: current) { albumID in
                    guard albumID != currentID else { return }
                    if library.album(id: albumID) != nil { renamedID = albumID } else { pendingID = albumID }
                }
                .frame(minWidth: 420, minHeight: 300)
            }
        }
    }

    private func albumContent(_ album: Album) -> some View {
        let scope = MacLibraryActionScope(library: library, profiles: profiles)
        return VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 20) {
                ArtworkView(album: album, cornerRadius: 8, highlight: false)
                    .frame(width: 112, height: 112)
                VStack(alignment: .leading, spacing: 6) {
                    Text(album.title).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                    if let artist = library.artist(named: album.artist) {
                        NavigationLink(value: artist) { Text(album.artist).lineLimit(1) }
                            .buttonStyle(.link)
                    } else {
                        Text(album.artist).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Text(album.metaLine).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    Text(songSummary).font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        MacCollectionPlayButtons(isEmpty: album.tracks.isEmpty || !scope.isCurrent(library: library, profiles: profiles)) {
                            guard scope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                            player.play(album: album)
                        } shuffle: {
                            guard scope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                            player.play(queue: album.tracks.shuffled(), title: album.title)
                        }
                        MacCollectionDownloadControl(item: .album(album))
                    }
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(20)
            Divider()
            MacTrackTable(entries: entries, title: album.title)
        }
        .navigationTitle(album.title)
        .toolbar {
            if !library.isDemo {
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button("Rename Album…", systemImage: "pencil") { isRenaming = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .onChange(of: album.tracks, initial: true) { _, tracks in
            entries = TrackListEntry.make(from: tracks)
            let duration = tracks.reduce(0) { $0 + $1.duration }
            songSummary = "\(tracks.count) \(tracks.count == 1 ? "song" : "songs") · \(TimeText.long(duration)) · \(album.qualityLabel)"
        }
    }
}

struct MacPlaylistDetailView: View {
    let playlist: Playlist
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    @State private var isRenaming = false
    @State private var renameText = ""
    @State private var isConfirmingDelete = false
    @State private var editingPlaylist: Playlist?
    @State private var editingScope: MacLibraryActionScope?

    var body: some View {
        let live = library.playlist(id: playlist.id)
        let scope = MacLibraryActionScope(library: library, profiles: profiles)
        Group {
            if let playlist = live {
                VStack(spacing: 0) {
                    HStack(alignment: .top, spacing: 20) {
                        PlaylistCover(playlist: playlist, cornerRadius: 8)
                            .frame(width: 112, height: 112)
                        VStack(alignment: .leading, spacing: 8) {
                            Text(playlist.name).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                            Text(playlist.summary).foregroundStyle(.secondary).lineLimit(2)
                            HStack(spacing: 8) {
                                MacCollectionPlayButtons(isEmpty: playlist.tracks.isEmpty || !scope.isCurrent(library: library, profiles: profiles)) {
                                    guard scope.isCurrent(library: library, profiles: profiles), library.playlist(id: playlist.id) == playlist else { return }
                                    player.play(queue: playlist.tracks, title: playlist.name)
                                } shuffle: {
                                    guard scope.isCurrent(library: library, profiles: profiles), library.playlist(id: playlist.id) == playlist else { return }
                                    player.play(queue: playlist.tracks.shuffled(), title: playlist.name)
                                }
                                if playlist.kind == .local || playlist.id == Playlist.favouritesID {
                                    MacCollectionDownloadControl(item: .playlist(playlist))
                                }
                            }
                            .padding(.top, 4)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(20)
                    Divider()
                    MacTrackTable(entries: playlist.entries, title: playlist.name, playlistID: playlist.id)
                }
            } else {
                ContentUnavailableView("Playlist Unavailable", systemImage: "music.note.list", description: Text("This playlist is no longer in the current library."))
            }
        }
        .navigationTitle(live?.name ?? playlist.name)
        .toolbar {
            if scope.isCurrent(library: library, profiles: profiles), library.isLocalPlaylist(playlist.id), let live {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button("Rename Playlist…", systemImage: "pencil") {
                        editingPlaylist = live
                        editingScope = scope
                        renameText = live.name
                        isRenaming = true
                    }
                    Button("Delete Playlist…", systemImage: "trash", role: .destructive) {
                        editingPlaylist = live
                        editingScope = scope
                        isConfirmingDelete = true
                    }
                }
            }
        }
        .alert("Rename Playlist", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                guard let editingScope, editingScope.isCurrent(library: library, profiles: profiles), let editingPlaylist,
                      library.playlist(id: playlist.id) == editingPlaylist, library.isLocalPlaylist(playlist.id) else { return }
                library.renamePlaylist(id: playlist.id, to: renameText)
            }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel", role: .cancel) {}
        }
        .confirmationDialog("Delete “\(live?.name ?? playlist.name)”?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Playlist", role: .destructive) {
                guard let editingScope, editingScope.isCurrent(library: library, profiles: profiles), let editingPlaylist,
                      library.playlist(id: playlist.id) == editingPlaylist, library.isLocalPlaylist(playlist.id) else { return }
                library.deletePlaylist(id: playlist.id)
                if library.playlist(id: playlist.id) == nil { dismiss() }
            }
        } message: {
            Text("The songs stay in your library.")
        }
    }
}

struct MacArtistDetailView: View {
    let artist: Artist
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        Group {
            if let current = library.artist(named: artist.name), !current.albums.isEmpty {
                artistContent(current)
            } else {
                ContentUnavailableView("Artist Unavailable", systemImage: "person.crop.circle", description: Text("This artist is no longer in the current library."))
                    .navigationTitle("Artist Unavailable")
            }
        }
    }

    private func artistContent(_ artist: Artist) -> some View {
        let scope = MacLibraryActionScope(library: library, profiles: profiles)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .top, spacing: 20) {
                    if let album = artist.albums.first {
                        ArtworkView(album: album, cornerRadius: 56, highlight: false)
                            .frame(width: 112, height: 112)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text(artist.name).font(.title2.weight(.semibold)).lineLimit(2).textSelection(.enabled)
                        Text(artist.summary).foregroundStyle(.secondary)
                        MacCollectionPlayButtons(isEmpty: artist.albums.isEmpty || !scope.isCurrent(library: library, profiles: profiles)) {
                            guard scope.isCurrent(library: library, profiles: profiles), library.artist(named: artist.name) == artist else { return }
                            player.play(queue: artist.albums.flatMap(\.tracks), title: artist.name)
                        } shuffle: {
                            guard scope.isCurrent(library: library, profiles: profiles), library.artist(named: artist.name) == artist else { return }
                            player.play(queue: artist.albums.flatMap(\.tracks).shuffled(), title: artist.name)
                        }
                        .padding(.top, 4)
                    }
                    Spacer(minLength: 0)
                }
                Text("Albums").font(.headline)
                MacAlbumGrid(albums: artist.albums)
            }
            .padding(20)
        }
        .navigationTitle(artist.name)
    }
}

struct MacAlbumCollectionView: View {
    let collection: AlbumCollection
    @Environment(LibraryStore.self) private var library

    var body: some View {
        let albums = collection.albums.compactMap { library.album(id: $0.id) }
        Group {
            if albums.isEmpty {
                ContentUnavailableView("Collection Unavailable", systemImage: "square.stack", description: Text("These albums are no longer in the current library."))
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(collection.title).font(.title2.weight(.semibold))
                        Text("\(albums.count) \(albums.count == 1 ? "album" : "albums")")
                            .foregroundStyle(.secondary)
                        MacAlbumGrid(albums: albums)
                    }
                    .padding(20)
                }
            }
        }
        .navigationTitle(collection.title)
    }
}

struct MacDownloadsView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        // Resolve only listed collections, rather than constructing owners for every library item.
        let listed = downloads.listedOwnerIDs
        let scope = DownloadOwner.scope(downloads.activeProfileID)
        let albumPrefix = scope + DownloadOwner.albumPrefix
        let playlistPrefix = scope + DownloadOwner.playlistPrefix
        let albums = listed.compactMap { id in
            id.hasPrefix(albumPrefix) ? library.album(id: String(id.dropFirst(albumPrefix.count))) : nil
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        let playlists = listed.compactMap { id in
            id.hasPrefix(playlistPrefix) ? library.playlist(id: String(id.dropFirst(playlistPrefix.count))) : nil
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

        List {
            if !playlists.isEmpty {
                Section("Playlists") {
                    ForEach(playlists) { playlist in MacDownloadRow(item: .playlist(playlist)) }
                }
            }
            if !albums.isEmpty {
                Section("Albums") {
                    ForEach(albums) { album in MacDownloadRow(item: .album(album)) }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if albums.isEmpty && playlists.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle", description: Text("Download an album or playlist to keep it on this Mac and listen without the server."))
            }
        }
        .navigationTitle("Downloads")
    }
}

private struct MacCollectionPlayButtons: View {
    let isEmpty: Bool
    let play: () -> Void
    let shuffle: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button("Play", systemImage: "play.fill", action: play)
            Button("Shuffle", systemImage: "shuffle", action: shuffle)
        }
        .buttonStyle(.bordered)
        .disabled(isEmpty)
    }
}

private enum MacDownloadItem {
    case album(Album)
    case playlist(Playlist)

    var title: String {
        switch self { case .album(let album): album.title; case .playlist(let playlist): playlist.name }
    }

    var subtitle: String {
        switch self { case .album(let album): album.artist; case .playlist(let playlist): playlist.summary }
    }

    var removalMessage: String {
        switch self {
        case .album: "The songs stay on your server; copies a downloaded playlist still needs are kept."
        case .playlist: "The playlist stays; songs a downloaded album still needs are kept."
        }
    }

    func owner(in downloads: DownloadManager) -> DownloadOwner {
        switch self { case .album(let album): downloads.owner(for: album); case .playlist(let playlist): downloads.owner(for: playlist) }
    }

    func isCurrent(in library: LibraryStore) -> Bool {
        switch self {
        case .album(let album): library.album(id: album.id) == album
        case .playlist(let playlist): library.playlist(id: playlist.id) == playlist
        }
    }

    @ViewBuilder var cover: some View {
        switch self {
        case .album(let album): ArtworkView(album: album, cornerRadius: 6, highlight: false, size: .row)
        case .playlist(let playlist): PlaylistCover(playlist: playlist, cornerRadius: 6)
        }
    }
}

/// Capture the collection as well as its account scope before an action or confirmation opens.
private struct MacDownloadActionContext {
    let scope: MacLibraryActionScope
    let item: MacDownloadItem
    let owner: DownloadOwner

    func isCurrent(library: LibraryStore, profiles: ProfileStore, downloads: DownloadManager) -> Bool {
        scope.isCurrent(library: library, profiles: profiles) && downloads.activeProfileID == profiles.activeID
            && item.isCurrent(in: library) && item.owner(in: downloads).id == owner.id
    }
}

/// Keep progress observation away from the collection's table and cached entry preparation.
private struct MacCollectionDownloadControl: View {
    let item: MacDownloadItem
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @Environment(DownloadManager.self) private var downloads

    var body: some View {
        let scope = MacLibraryActionScope(library: library, profiles: profiles)
        let owner = item.owner(in: downloads)
        let context = MacDownloadActionContext(scope: scope, item: item, owner: owner)
        if scope.isCurrent(library: library, profiles: profiles) {
            DownloadStateReader(owner: owner) { state in
                if let state {
                    MacDownloadActions(context: context, state: state)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking downloads")
                }
            }
        } else {
            ProgressView().controlSize(.small).accessibilityLabel("Updating library")
        }
    }
}

private struct MacDownloadRow: View {
    let item: MacDownloadItem
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(ProfileStore.self) private var profiles
    @Environment(DownloadManager.self) private var downloads
    @State private var removalContext: MacDownloadActionContext?

    var body: some View {
        let scope = MacLibraryActionScope(library: library, profiles: profiles)
        let owner = item.owner(in: downloads)
        let context = MacDownloadActionContext(scope: scope, item: item, owner: owner)
        DownloadStateReader(owner: owner) { state in
            HStack(spacing: 16) {
                Group {
                    switch item {
                    case .album(let album): NavigationLink(value: album) { label(state: state) }
                    case .playlist(let playlist): NavigationLink(value: playlist) { label(state: state) }
                    }
                }
                .buttonStyle(.plain)
                if let state {
                    MacDownloadActions(context: context, state: state, isListed: true)
                } else {
                    ProgressView().controlSize(.small).accessibilityLabel("Checking downloads")
                }
            }
            .padding(.vertical, 6)
            .disabled(!scope.isCurrent(library: library, profiles: profiles))
            .contextMenu {
                if state != nil {
                    Button("Play", systemImage: "play.fill") {
                        guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
                        player.play(queue: owner.tracks, title: owner.title)
                    }
                    .disabled(owner.tracks.isEmpty)
                    if state?.isDownloading == true {
                        Button("Cancel Download", systemImage: "xmark") {
                            guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
                            downloads.cancel(owner)
                        }
                    } else if let state, state != .downloaded {
                        Button("Retry Missing Songs", systemImage: "arrow.clockwise") {
                            guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
                            downloads.download(owner, driveID: library.catalogue.driveID, isSample: library.isDemo) {
                                library.streamURL(for: $0, quality: .original)
                            }
                        }
                        .disabled(owner.tracks.isEmpty)
                    }
                    Button("Remove Download…", systemImage: "trash", role: .destructive) {
                        guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
                        removalContext = context
                    }
                }
            }
            .confirmationDialog("Remove “\(removalContext?.owner.title ?? owner.title)” from your Mac?", isPresented: Binding(
                get: { removalContext != nil }, set: { if !$0 { removalContext = nil } }
            ), titleVisibility: .visible) {
                Button("Remove Download", role: .destructive) {
                    guard let removalContext, removalContext.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
                    downloads.remove(removalContext.owner)
                    self.removalContext = nil
                }
            } message: {
                Text(removalContext?.item.removalMessage ?? item.removalMessage)
            }
        }
    }

    private func label(state: DownloadState?) -> some View {
        HStack(spacing: 12) {
            item.cover.frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).font(.body.weight(.medium)).lineLimit(1)
                Text(item.subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                if let detail = state?.macDetail {
                    Text(detail).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer(minLength: 8)
        }
        .contentShape(Rectangle())
    }
}

private struct MacDownloadActions: View {
    let context: MacDownloadActionContext
    let state: DownloadState
    var isListed = false
    @Environment(LibraryStore.self) private var library
    @Environment(ProfileStore.self) private var profiles
    @Environment(DownloadManager.self) private var downloads
    @State private var removalContext: MacDownloadActionContext?

    private var owner: DownloadOwner { context.owner }

    var body: some View {
        HStack(spacing: 8) {
            if case .downloading(let fraction, let done, let total) = state {
                ProgressView(value: fraction)
                    .frame(width: 80)
                    .accessibilityLabel("Downloading \(owner.title)")
                    .accessibilityValue("\(done) of \(total) songs saved")
            }
            Button(buttonTitle, systemImage: buttonSymbol) { performAction() }
                .buttonStyle(.bordered)
                .disabled(owner.tracks.isEmpty && state == .none)
                .help(state == .downloaded ? "Remove Download…" : state.macDetail ?? buttonTitle)
                .accessibilityLabel("\(state == .downloaded ? "Remove Download" : buttonTitle) for \(owner.title)")
        }
        .fixedSize(horizontal: true, vertical: false)
        .disabled(!context.scope.isCurrent(library: library, profiles: profiles))
        .contextMenu {
            if state.isDownloading {
                Button("Cancel Download", systemImage: "xmark") {
                    guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
                    downloads.cancel(owner)
                }
            } else if state != .downloaded {
                Button("Retry Missing Songs", systemImage: "arrow.clockwise", action: download)
                    .disabled(owner.tracks.isEmpty)
            }
            if isListed || state != .none {
                Button("Remove Download…", systemImage: "trash", role: .destructive) { confirmRemoval() }
            }
        }
        .confirmationDialog("Remove “\(removalContext?.owner.title ?? owner.title)” from your Mac?", isPresented: Binding(
            get: { removalContext != nil }, set: { if !$0 { removalContext = nil } }
        ), titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) {
                guard let removalContext, removalContext.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
                downloads.remove(removalContext.owner)
                self.removalContext = nil
            }
        } message: {
            Text(removalContext?.item.removalMessage ?? context.item.removalMessage)
        }
    }

    private var buttonTitle: String {
        switch state {
        case .none: "Download"
        case .downloading: "Cancel"
        case .downloaded: "Downloaded"
        case .failed, .partial, .cancelled: "Retry"
        }
    }

    private var buttonSymbol: String {
        switch state {
        case .none: "arrow.down.circle"
        case .downloading: "xmark"
        case .downloaded: "checkmark.circle"
        case .failed, .partial, .cancelled: "arrow.clockwise"
        }
    }

    private func performAction() {
        guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
        switch state {
        case .none, .failed, .partial, .cancelled: download()
        case .downloading: downloads.cancel(owner)
        case .downloaded: confirmRemoval()
        }
    }

    private func confirmRemoval() {
        guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
        removalContext = context
    }

    private func download() {
        guard context.isCurrent(library: library, profiles: profiles, downloads: downloads) else { return }
        downloads.download(owner, driveID: library.catalogue.driveID, isSample: library.isDemo) {
            library.streamURL(for: $0, quality: .original)
        }
    }
}

private extension DownloadState {
    var macDetail: String? {
        switch self {
        case .none: nil
        case .downloaded: "Downloaded"
        case .downloading(_, let done, let total): "\(done) of \(total) songs saved"
        case .failed(let message): "Download failed: \(message)"
        case .partial(let done, let total, let message): "\(done) of \(total) songs saved" + (message.map { " · \($0)" } ?? "")
        case .cancelled(let done, let total): "Cancelled · \(done) of \(total) songs saved"
        }
    }
}
