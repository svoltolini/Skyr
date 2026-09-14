import SkyrCore
import SwiftUI

/// A selectable desktop table. Display sorting never changes the stored playlist order.
struct MacTrackTable: View {
    let entries: [TrackListEntry]
    let title: String
    var playlistID: String? = nil
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(AppModel.self) private var model
    @Environment(ProfileStore.self) private var profiles
    @State private var presentation: MacTablePresentation?
    @State private var preparationID = UUID()
    @State private var isPreparing = false
    @State private var actionNotice: String?
    @State private var selection: Set<TrackListEntry.ID> = []
    @State private var sortOrder = [KeyPathComparator(\MacSongRow.position)]
    @State private var playlistAddition: MacPlaylistAddition?

    var body: some View {
        let input = currentInput
        let request = MacTableRequest(input: input, sortOrder: sortOrder)
        let displayed = input.contentReady && presentation?.input.scope == input.scope ? presentation : nil
        Table(displayed?.rows ?? [], selection: $selection, sortOrder: $sortOrder) {
            TableColumn("#", value: \.position) { row in
                Text((row.position + 1).formatted()).foregroundStyle(.secondary)
            }
            .width(min: 34, ideal: 40, max: 56)
            TableColumn("Title", value: \.title) { row in
                HStack(spacing: 8) {
                    Text(row.title).lineLimit(1)
                    MacSongStatus(track: row.entry.track, library: library, downloads: downloads)
                }
            }
            .width(min: 160, ideal: 260)
            TableColumn("Artist", value: \.artist).width(min: 100, ideal: 170)
            TableColumn("Album", value: \.album).width(min: 100, ideal: 180)
            TableColumn("Time", value: \.duration) { row in
                Text(TimeText.clock(row.duration)).monospacedDigit().foregroundStyle(.secondary)
            }
            .width(60)
        }
        .tableStyle(.inset)
        .accessibilityLabel(title.localizedCaseInsensitiveCompare("Songs") == .orderedSame ? title : "\(title) songs")
        .contextMenu(forSelectionType: TrackListEntry.ID.self) { ids in
            if !ids.isEmpty {
                Button("Play", systemImage: "play.fill") { play(ids, from: displayed) }
                Button("Add to Playlist…", systemImage: "text.badge.plus") {
                    guard let rows = validatedRows(ids, from: displayed), let displayed else { return }
                    playlistAddition = MacPlaylistAddition(input: displayed.input, tracks: rows.map(\.entry.track))
                }
                if ids.count == 1, let row = displayed?.rows.first(where: { ids.contains($0.id) }) {
                    Button(library.isFavourite(row.entry.track) ? "Remove from Favourites" : "Favourite", systemImage: "heart") {
                        guard let row = validatedRows(ids, from: displayed)?.first else { return }
                        library.toggleFavourite(row.entry.track)
                    }
                    if let album = library.album(for: row.entry.track) {
                        Button("Go to Album", systemImage: "square.stack") {
                            guard validatedRows(ids, from: displayed) != nil,
                                  let live = library.album(id: album.id) else { return }
                            model.showAlbum(live)
                        }
                    }
                }
                if let playlistID, library.isLocalPlaylist(playlistID) {
                    Divider()
                    Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive) {
                        guard validatedRows(ids, from: displayed) != nil,
                              let live = library.playlist(id: playlistID) else { return }
                        let positions = live.entries.filter { ids.contains($0.id) }.map(\.position)
                        library.removeEntries(at: IndexSet(positions), fromPlaylist: playlistID)
                        selection = []
                    }
                }
            }
        } primaryAction: { ids in
            play(ids, from: displayed)
        }
        .onKeyPress(.return) {
            guard !selection.isEmpty else { return .ignored }
            play(selection, from: displayed)
            return .handled
        }
        .onKeyPress(.space) {
            guard let displayed, inputIsCurrent(displayed.input) else { return .ignored }
            if player.hasTrack { player.togglePlayPause() }
            else if !selection.isEmpty { play(selection, from: displayed) }
            else { return .ignored }
            return .handled
        }
        .task(id: request) { await prepare(request) }
        .onChange(of: input.scope) { _, _ in
            // A sheet captures tracks too; it must not survive signing out or changing the NAS.
            playlistAddition = nil
            selection = []
        }
        .sheet(item: $playlistAddition) { addition in
            AddToPlaylistSheet(tracks: addition.tracks, isContextCurrent: { inputIsCurrent(addition.input) })
                .environment(library)
                .frame(minWidth: 380, minHeight: 320)
        }
        .alert("Songs Updated", isPresented: Binding(get: { actionNotice != nil }, set: { if !$0 { actionNotice = nil } })) {
            Button("OK", role: .cancel) { actionNotice = nil }
        } message: {
            Text(actionNotice ?? "")
        }
        .overlay {
            if displayed == nil && !entries.isEmpty {
                ProgressView("Loading Songs…")
            } else if entries.isEmpty {
                ContentUnavailableView("No Songs", systemImage: "music.note", description: Text("Songs in this collection will appear here."))
            }
        }
        .overlay(alignment: .topTrailing) {
            if isPreparing && displayed != nil {
                ProgressView().controlSize(.small).padding(8)
                    .accessibilityLabel("Updating song order")
            }
        }
    }

    private var currentScope: MacTableScope {
        MacTableScope(sourceID: library.catalogue.driveID, profileID: profiles.activeID, sessionID: profiles.sessionID)
    }

    private var currentInput: MacTableInput {
        MacTableInput(scope: currentScope, entries: entries, revision: library.contentRevision, playlistID: playlistID,
                      contentReady: library.contentSourceID == library.catalogue.driveID)
    }

    private func prepare(_ request: MacTableRequest) async {
        guard !Task.isCancelled else { return }
        let generation = UUID()
        preparationID = generation
        isPreparing = true
        defer { if preparationID == generation { isPreparing = false } }

        if let previous = presentation {
            if previous.input.scope != request.input.scope ||
               previous.input.entries.map(\.id) != request.input.entries.map(\.id) {
                selection = []
            }
            if previous.input.scope != request.input.scope { presentation = nil }
        }
        guard request.input.scope == currentScope,
              inputIsCurrent(request.input) else {
            presentation = nil
            return
        }
        // Metadata reads take a small, bounded snapshot on the actor; locale-aware comparison of
        // thousands of rows happens in a cancellable worker. Progress/player updates do not enter it.
        let snapshot = request.input.entries.map { entry in
            let album = library.album(for: entry.track)
            return MacSongRow(entry: entry, artist: entry.track.artist ?? album?.artist ?? "Unknown Artist", album: album?.title ?? entry.track.albumTitleTag ?? "Unknown Album")
        }
        do {
            let sorted = try await BackgroundSort.sorted(snapshot, using: request.sortOrder)
            guard !Task.isCancelled, preparationID == generation,
                  currentInput == request.input, sortOrder == request.sortOrder,
                  inputIsCurrent(request.input) else { return }
            presentation = MacTablePresentation(input: request.input, rows: sorted)
            selection.formIntersection(Set(sorted.map(\.id)))
        } catch is CancellationError {
            // Another sort, collection update or navigation replaced this immutable request.
        } catch {
            actionNotice = "The songs couldn't be sorted. Choose the column again to retry."
        }
    }

    /// Check stores at the moment of the action, even before SwiftUI has delivered an onChange.
    private func inputIsCurrent(_ input: MacTableInput) -> Bool {
        guard input.scope == currentScope, input.scope.profileID != nil, input.scope.sessionID != nil,
              input.contentReady, library.contentSourceID == input.scope.sourceID,
              input.revision == library.contentRevision else { return false }
        if let playlistID = input.playlistID {
            guard let live = library.playlist(id: playlistID), live.entries == input.entries else { return false }
        }
        // Generic album/search/song inputs can briefly lag their parent while a new catalogue
        // arrives. Only current derived tracks may acquire this source's fresh presentation.
        guard input.entries.allSatisfy({ library.track(id: $0.track.id) == $0.track }) else { return false }
        return true
    }

    private func validatedRows(_ ids: Set<TrackListEntry.ID>, from displayed: MacTablePresentation?) -> [MacSongRow]? {
        guard let displayed, presentation?.id == displayed.id,
              currentInput == displayed.input, inputIsCurrent(displayed.input) else {
            selection = []
            actionNotice = "This collection changed. Select the songs again before continuing."
            return nil
        }
        let selected = displayed.rows.filter { ids.contains($0.id) }
        guard selected.count == ids.count, !selected.isEmpty else {
            selection = []
            return nil
        }
        return selected
    }

    private func play(_ ids: Set<TrackListEntry.ID>, from displayed: MacTablePresentation?) {
        guard let selected = validatedRows(ids, from: displayed), let displayed,
              let first = selected.first, let index = displayed.rows.firstIndex(where: { $0.id == first.id }) else { return }
        player.play(queue: displayed.rows.map(\.entry.track), startingAt: index, title: title)
    }
}

private nonisolated struct MacPlaylistAddition: Identifiable, Sendable {
    let id = UUID()
    let input: MacTableInput
    let tracks: [Track]
}

private nonisolated struct MacTableScope: Equatable, Sendable {
    let sourceID: String
    let profileID: String?
    let sessionID: UUID?
}

private nonisolated struct MacTableInput: Equatable, Sendable {
    let scope: MacTableScope
    let entries: [TrackListEntry]
    let revision: Int
    let playlistID: String?
    let contentReady: Bool
}

private nonisolated struct MacTableRequest: Equatable, Sendable {
    let input: MacTableInput
    let sortOrder: [KeyPathComparator<MacSongRow>]
}

private nonisolated struct MacTablePresentation: Sendable {
    let id = UUID()
    let input: MacTableInput
    let rows: [MacSongRow]
}

private nonisolated struct MacSongRow: Identifiable, Sendable {
    let entry: TrackListEntry
    let artist: String
    let album: String
    var id: TrackListEntry.ID { entry.id }
    var position: Int { entry.position }
    var title: String { entry.track.title }
    var duration: TimeInterval { entry.track.duration }
}

/// Keep download/favourite observation in visible cells instead of rebuilding the table.
private struct MacSongStatus: View {
    let track: Track
    let library: LibraryStore
    let downloads: DownloadManager

    var body: some View {
        HStack(spacing: 5) {
            if library.isFavourite(track) {
                Image(systemName: "heart.fill").accessibilityLabel("Favourite")
            }
            if let fraction = downloads.progress[track.id] {
                ProgressView(value: fraction).frame(width: 30).accessibilityLabel("Downloading")
            } else if downloads.isDownloaded(track) {
                Image(systemName: "arrow.down.circle.fill").accessibilityLabel("Downloaded")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
    }
}
