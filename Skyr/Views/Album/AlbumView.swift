import SkyrCore
import SwiftUI

struct AlbumView: View {
    let album: Album
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The album as the library has it now: colours, tags and track order can change after the page opens.
    private var live: Album { library.album(id: album.id) ?? album }
    @State private var isFlipped = false
    @State private var isConfirmingRemoval = false

    var body: some View {
        let album = live
        ScrollView {
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
                    .accessibilityLabel(isFlipped ? "Album details, tap to show the cover" : "Album cover, tap for details")
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
                            player.play(album: album)
                        } shuffle: {
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
        return DownloadButton(state: downloads.state(for: owner)) {
            switch downloads.state(for: owner) {
            case .none:
                downloads.download(owner, driveID: library.catalogue.driveID, isSample: library.isDemo) { track in
                    library.streamURL(for: track, quality: .original)
                }
            case .downloading:
                downloads.cancel(owner)
            case .downloaded:
                isConfirmingRemoval = true
            }
        }
        .confirmationDialog("Remove this album from your \(Device.noun)?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { downloads.remove(owner) }
        } message: {
            Text("The songs stay on your server; copies a downloaded playlist still needs are kept.")
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isAddingToPlaylist = false

    private var isCurrent: Bool { player.isCurrent(track: track) }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                player.play(album: album, startingAt: track.index)
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
