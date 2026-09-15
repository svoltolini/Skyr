import SkyrCore
import SwiftUI

/// A retained row or confirmation can outlive the library or authenticated profile that opened it.
private struct AlbumActionScope: Equatable {
    let sourceID: String
    let profileID: String?
    let sessionID: UUID?

    init(library: LibraryStore, profiles: ProfileStore) {
        sourceID = library.catalogue.driveID
        profileID = profiles.activeID
        sessionID = profiles.sessionID
    }

    func isCurrent(library: LibraryStore, profiles: ProfileStore) -> Bool {
        profileID != nil && sessionID != nil && library.contentSourceID == sourceID
            && self == AlbumActionScope(library: library, profiles: profiles)
    }
}

private struct AlbumRemovalRequest {
    let album: Album
    let owner: DownloadOwner
    let scope: AlbumActionScope
}

struct AlbumView: View {
    let album: Album
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var isFlipped = false
    @State private var isConfirmingRemoval = false
    @State private var removalRequest: AlbumRemovalRequest?
    @State private var isRenaming = false
    /// The album's id once a rename gave it a new one; the page follows the album rather than the old id.
    @State private var renamedID: String?
    /// A new id whose album is still being derived after a rename.
    @State private var pendingID: String?

    private var currentID: String { renamedID ?? album.id }

    var body: some View {
        Group {
            if let current = library.album(id: currentID) {
                albumContent(current)
            } else if pendingID != nil {
                ProgressView("Updating album…")
                    .inlineTitle()
                    .windowTitle(album.title)
            } else {
                ContentUnavailableView("Album Unavailable", systemImage: "square.stack", description: Text("This album is no longer in the current library."))
                    .inlineTitle()
                    .windowTitle("Album Unavailable")
            }
        }
        .onChange(of: library.contentRevision) { _, _ in
            guard let pending = pendingID, library.album(id: pending) != nil else { return }
            renamedID = pending
            pendingID = nil
        }
    }

    /// The rename wrote a new title: follow the album to its new id as soon as the library shows it.
    private func follow(albumID: String) {
        guard albumID != currentID else { return }
        if library.album(id: albumID) != nil {
            renamedID = albumID
        } else {
            pendingID = albumID
        }
    }

    private func albumContent(_ album: Album) -> some View {
        let scope = AlbumActionScope(library: library, profiles: profiles)
        return ScrollView {
            VStack(spacing: 0) {
                DetailHeader(coverSize: 260) {
                    // Tap the cover to turn it over; the back carries the year, genre and quality.
                    FlipView(angle: isFlipped ? 180 : 0) {
                        ArtworkView(album: album, cornerRadius: 14, size: .hero)
                    } back: {
                        CoverBack(album: album)
                    }
                    .shadow(color: .black.opacity(0.4), radius: 28, y: 18)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(reduceMotion ? .easeInOut(duration: 0.15) : .spring(duration: 0.7, bounce: 0.18)) { isFlipped.toggle() }
                    }
                    .sensoryFeedback(.impact(weight: .light), trigger: isFlipped)
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(isFlipped ? "Album details. Show cover" : "Album cover. Show details")
                } titles: {
                    Text(album.title)
                        .font(Fonts.pageTitle)
                    if let artist = library.artist(named: album.artist) {
                        NavigationLink(value: artist) {
                            Text(album.artist)
                                .font(.body)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Text(album.artist)
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                    QualityBars(quality: album.quality)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(album.qualityLabel)
                        .padding(.top, 5)
                } actions: {
                    HStack(spacing: 10) {
                        PlayActions {
                            guard scope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                            player.play(album: album)
                        } shuffle: {
                            guard scope.isCurrent(library: library, profiles: profiles), library.album(id: album.id) == album else { return }
                            player.play(queue: album.tracks.shuffled(), startingAt: 0, title: album.title)
                        }
                        #if !os(tvOS)
                        downloadButton(for: album)
                        #endif
                    }
                }

                if album.hasMultipleDiscs {
                    ForEach(album.discs) { disc in
                        discHeader(disc)
                            .padding(.top, 26)
                        TrackList(album: album, tracks: disc.tracks)
                            .padding(.top, 6)
                    }
                } else {
                    TrackList(album: album, tracks: album.tracks)
                        .padding(.top, 18)
                }

                Text(footerText(for: album))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 16)
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
        .skyrBackground(album.primaryColor)
        .inlineTitle()
        .windowTitle(album.title, subtitle: album.artist)
        #if !os(tvOS)
        .toolbar {
            if !library.isDemo {
                ToolbarItem(placement: .trailingBar) {
                    Menu {
                        Button("Rename Album…", systemImage: "pencil") { isRenaming = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .accessibilityLabel("More")
                }
            }
        }
        .sheet(isPresented: $isRenaming) {
            AlbumRenameSheet(album: album) { albumID in follow(albumID: albumID) }
        }
        #endif
    }

    private func discHeader(_ disc: Disc) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Disc \(disc.number)")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .kerning(0.5)
            Spacer()
            Text("\(disc.tracks.count) \(disc.tracks.count == 1 ? "song" : "songs") · \(TimeText.long(disc.duration))")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 4)
    }

    private func footerText(for album: Album) -> String {
        var parts: [String] = []
        if album.hasMultipleDiscs { parts.append("\(album.discs.count) discs") }
        parts.append("\(album.tracks.count) \(album.tracks.count == 1 ? "song" : "songs")")
        parts.append(TimeText.long(album.duration))
        parts.append(album.sizeText)
        return parts.joined(separator: " · ")
    }

    private func downloadButton(for album: Album) -> some View {
        let owner = downloads.owner(for: album)
        let scope = AlbumActionScope(library: library, profiles: profiles)
        return DownloadStateReader(owner: owner) { state in
            if let state {
                DownloadButton(state: state) {
                    guard scope.isCurrent(library: library, profiles: profiles),
                          library.album(id: album.id) == album, downloads.owner(for: album) == owner else { return }
                    switch state {
                    case .none, .failed, .partial, .cancelled:
                        downloads.download(owner, driveID: scope.sourceID, isSample: library.isDemo) {
                            track in
                            library.streamURL(for: track, quality: .original)
                        }
                    case .downloading:
                        downloads.cancel(owner)
                    case .downloaded:
                        removalRequest = AlbumRemovalRequest(album: album, owner: owner, scope: scope)
                        isConfirmingRemoval = true
                    }
                }
            } else {
                ProgressView().frame(width: 50, height: 50).accessibilityLabel("Checking downloads")
            }
        }
        .confirmationDialog(
            "Remove this album from your \(Device.noun)?", isPresented: $isConfirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove Download", role: .destructive) {
                guard let request = removalRequest else { return }
                removalRequest = nil
                guard request.scope.isCurrent(library: library, profiles: profiles),
                      library.album(id: request.album.id) == request.album,
                      downloads.owner(for: request.album) == request.owner else { return }
                downloads.remove(request.owner)
            }
        } message: {
            Text("The songs stay on your server; copies a downloaded playlist still needs are kept.")
        }
    }


}

/// Renames an album for good by writing the new title into the album tag of each of its songs on
/// the NAS. Everything else in the files, and the album's other details, stay exactly as they were.
struct AlbumRenameSheet: View {
    let album: Album
    /// Receives the album's id once the write is done: a new one when the title changed.
    let onRenamed: (String) -> Void
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var isWriting = false
    @State private var writtenTitle = ""
    @State private var report: MetadataWriteReport?
    @FocusState private var isEditingTitle: Bool

    init(album: Album, onRenamed: @escaping (String) -> Void) {
        self.album = album
        self.onRenamed = onRenamed
        _title = State(initialValue: album.title)
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSave: Bool { library.canWriteTags && !trimmedTitle.isEmpty && trimmedTitle != album.title && !isWriting }
    private var songCount: Int { library.album(id: album.id)?.tracks.count ?? album.tracks.count }

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    resultSections(report)
                } else if isWriting {
                    Section {
                        TagWriteProgressView(writer: library.metadataWriter, title: "Writing “\(writtenTitle)” to \(songCount) \(songCount == 1 ? "song" : "songs")")
                    } footer: {
                        Text("Each song is downloaded, its album tag rewritten and the file put back on your NAS. Songs already written stay written if you stop.")
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    Section {
                        TextField("Title", text: $title)
                            #if os(macOS)
                            .textFieldStyle(.roundedBorder)
                            #endif
                            .focused($isEditingTitle)
                            .submitLabel(.done)
                            .onSubmit { if canSave { save() } }
                        #if os(macOS)
                        Text(footer)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        #endif
                    } header: {
                        Text("Title")
                    } footer: {
                        #if !os(macOS)
                        Text(footer)
                            .fixedSize(horizontal: false, vertical: true)
                        #endif
                    }
                }
            }
            .navigationTitle("Rename Album")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isWriting {
                        Button("Stop") { library.metadataWriter.cancel() }
                    } else if report == nil {
                        Button("Cancel") { dismiss() }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if report != nil {
                        Button("Done") { dismiss() }
                    } else if !isWriting {
                        Button("Rename") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWriting)
        .onAppear { isEditingTitle = true }
    }

    @ViewBuilder private func resultSections(_ report: MetadataWriteReport) -> some View {
        Section {
            Label(TagWriteSummary.line(for: report, noun: "title"), systemImage: report.written.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
            ForEach(report.reasons, id: \.self) { reason in
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(report.failures.isEmpty ? "Stopped" : "Some files were left unchanged")
        } footer: {
            if !report.written.isEmpty {
                Text("Songs whose files keep the old title show as a separate album until they can be written too.")
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var footer: String {
        let songs = "\(songCount) \(songCount == 1 ? "song" : "songs")"
        guard library.canWriteTags else {
            return "Connect to your server to rename this album. The new title is written into its \(songs) on the NAS, so it holds everywhere and survives a rescan."
        }
        return "The album tag of \(songs) is rewritten on your NAS as the new title. Artist, year, genre, song titles and artwork stay as they are."
    }

    private func save() {
        guard canSave else { return }
        let newTitle = trimmedTitle
        isEditingTitle = false
        writtenTitle = newTitle
        isWriting = true
        Task { @MainActor in
            let outcome = await library.renameAlbum(album, to: newTitle)
            isWriting = false
            onRenamed(outcome.albumID)
            if outcome.report.isComplete {
                dismiss()
            } else {
                report = outcome.report
            }
        }
    }
}

/// The back of the cover: the album's colours with its year, genre and quality.
struct CoverBack: View {
    let album: Album

    var body: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(album.secondaryColor)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(
                        EllipticalGradient(
                            colors: [album.primaryColor.opacity(0.55), .clear],
                            center: UnitPoint(x: 0.3, y: 0.2),
                            startRadiusFraction: 0,
                            endRadiusFraction: 0.8
                        )
                    )
            }
            .overlay {
                VStack(spacing: 6) {
                    Text(album.year > 0 ? String(album.year) : "—")
                        .font(.system(size: 46, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(album.genre)
                        .font(.title3.weight(.medium))
                    Text(album.qualityLabel)
                        .font(.subheadline)
                        .opacity(0.75)
                        .padding(.top, 10)
                }
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .padding(20)
            }
            .accessibilityElement(children: .combine)
    }
}

/// Plain song rows on the page background, separated by hairlines that start at the title.
struct TrackList: View {
    let album: Album
    let tracks: [Track]

    var body: some View {
        // Lazy, so a long compilation lays out only the rows on screen when the page opens.
        LazyVStack(spacing: 0) {
            ForEach(Array(tracks.enumerated()), id: \.element.id) { index, track in
                TrackRow(album: album, track: track)
                if index < tracks.count - 1 {
                    Divider().padding(.leading, 38)
                }
            }
        }
    }
}

/// One numbered track line; the loaded track shows a speaker glyph instead of its number.
/// Tapping plays it; the "…" opens favourite and playlist actions.
struct TrackRow: View {
    let album: Album
    let track: Track
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAddingToPlaylist = false

    private var isCurrent: Bool { player.isCurrent(track: track) }

    var body: some View {
        let scope = AlbumActionScope(library: library, profiles: profiles)
        HStack(spacing: 0) {
            Button {
                guard scope.isCurrent(library: library, profiles: profiles),
                      let current = library.album(id: album.id),
                      let index = current.tracks.firstIndex(where: { $0.id == track.id }) else { return }
                player.play(album: current, startingAt: index)
            } label: {
                HStack(spacing: 14) {
                    Group {
                        if isCurrent {
                            Image(systemName: "speaker.wave.2.fill")
                                .symbolEffect(.variableColor.iterative, isActive: player.isPlaying)
                                .symbolEffectsRemoved(reduceMotion)
                                .foregroundStyle(album.primaryColor)
                        } else {
                            Text(track.number, format: .number)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.subheadline)
                    .monospacedDigit()
                    .frame(width: 24, alignment: .trailing)
                    FadingText(track.title)
                        .font(.body.weight(isCurrent ? .semibold : .regular))
                    Spacer(minLength: 8)
                    if library.isFavourite(track) {
                        FavouriteMark()
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    }
                    if let fraction = downloads.progress[track.id] {
                        MiniProgressRing(fraction: fraction)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                    } else if downloads.isQueued(track) {
                        Circle()
                            .stroke(.quaternary, lineWidth: 2)
                            .frame(width: 13, height: 13)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                            .accessibilityLabel("Waiting to download")
                    } else if downloads.isDownloaded(track) {
                        Image(systemName: "arrow.down.circle.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
                            .accessibilityLabel("Downloaded")
                    }
                    Text(TimeText.clock(track.duration))
                        .font(.footnote)
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: downloads.isDownloaded(track))
                .animation(reduceMotion ? nil : .snappy(duration: 0.3), value: library.isFavourite(track))
                .padding(.vertical, 17)
                .padding(.leading, 4)
                .contentShape(Rectangle())
                .animation(.easeInOut(duration: 0.25), value: isCurrent)
            }
            .buttonStyle(RowPressStyle())
            .accessibilityLabel("\(track.number). \(track.title), \(TimeText.clock(track.duration))")

            TrackActionsMenu(track: track, isAddingToPlaylist: $isAddingToPlaylist)
                .padding(.leading, 2)
        }
        .sheet(isPresented: $isAddingToPlaylist) {
            AddToPlaylistSheet(tracks: [track])
        }
    }
}
