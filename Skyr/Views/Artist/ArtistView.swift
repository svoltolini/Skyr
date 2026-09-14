import SkyrCore
import SwiftUI

struct ArtistView: View {
    let artist: Artist
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Group {
            if let current = library.artist(named: artist.name), !current.albums.isEmpty {
                ArtistDetailContent(artist: current)
            } else {
                ContentUnavailableView("Artist Unavailable", systemImage: "person.crop.circle", description: Text("This artist is no longer in the current library."))
                    .inlineTitle()
                    .windowTitle("Artist Unavailable")
            }
        }
    }
}

private struct ArtistDetailContent: View {
    let artist: Artist
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @State private var pull: CGFloat = 0

    private var featuredAlbum: Album { artist.albums[0] }
    private var relatedArtists: [Artist] { library.artists.filter { $0.id != artist.id }.prefix(8).map { $0 } }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero

                PlayActions {
                    guard library.artist(named: artist.name) == artist else { return }
                    player.play(queue: artist.albums.flatMap(\.tracks), startingAt: 0, title: artist.name)
                } shuffle: {
                    guard library.artist(named: artist.name) == artist else { return }
                    player.play(queue: artist.albums.flatMap(\.tracks).shuffled(), startingAt: 0, title: artist.name)
                }
                .padding(.horizontal, 24)
                .padding(.top, 20)

                SectionHeader(title: "Albums")
                    .padding(.top, 28)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(artist.albums) { album in
                            let destination = AlbumDestination(album, source: "artist")
                            NavigationLink(value: destination) {
                                VStack(alignment: .leading, spacing: 2) {
                                    ArtworkView(album: album, cornerRadius: 12)
                                        .shadow(color: .black.opacity(0.3), radius: 14, y: 10)
                                        .artworkSource(destination, cornerRadius: 12, shadow: .card)
                                        .frame(width: 170 * Metrics.scale, height: 170 * Metrics.scale)
                                    .padding(.bottom, 7)
                                    FadingText(album.title)
                                        .font(.subheadline.weight(.medium))
                                    Text(album.year > 0 ? String(album.year) : album.genre)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                                .frame(width: 170 * Metrics.scale, alignment: .leading)
                            }
                            .cardButton()
                        }
                    }
                    .scrollTargetLayout()
                }
                .contentMargins(.horizontal, 24, for: .scrollContent)
                .scrollTargetBehavior(.viewAligned)
                .scrollIndicators(.hidden)
                .scrollClipDisabled()
                .padding(.top, 12)

                SectionHeader(title: "Songs")
                    .padding(.top, 26)
                CardList(data: artist.topTracks, separatorInset: 70) { track in
                    Button {
                        if let album = library.album(for: track), let index = album.tracks.firstIndex(where: { $0.id == track.id }) {
                            player.play(album: album, startingAt: index)
                        }
                    } label: {
                        HStack(spacing: 14) {
                            ArtworkView(album: library.album(for: track) ?? featuredAlbum, cornerRadius: 6, highlight: false, size: .row)
                                .frame(width: 40, height: 40)
                            Text(track.title)
                                .font(.body.weight(player.isCurrent(track: track) ? .semibold : .medium))
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text(TimeText.clock(track.duration))
                                .font(.footnote)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .cardButton()
                }
                .padding(.horizontal, 24)
                .padding(.top, 12)

                if !relatedArtists.isEmpty {
                    SectionHeader(title: "Also in your library")
                        .padding(.top, 28)
                    ScrollView(.horizontal) {
                        LazyHStack(alignment: .top, spacing: 12) {
                            ForEach(relatedArtists) { related in
                                let destination = ArtistDestination(related, source: "related|\(artist.id)")
                                NavigationLink(value: destination) {
                                    VStack(spacing: 8) {
                                        ArtistPortrait(artist: related)
                                            .frame(width: 132 * Metrics.scale, height: 132 * Metrics.scale)
                                            .zoomSource(id: destination.sourceID, shape: .circle(132))
                                        FadingText(related.name, fadeWidth: 40, alignment: .center)
                                            .font(.caption.weight(.medium))
                                    }
                                    .frame(width: 132 * Metrics.scale)
                                }
                                .cardButton()
                            }
                        }
                        .scrollTargetLayout()
                    }
                    .contentMargins(.horizontal, 24, for: .scrollContent)
                    .scrollTargetBehavior(.viewAligned)
                    .scrollIndicators(.hidden)
                    .padding(.top, 12)
                }
            }
            .padding(.bottom, 32)
        }
        .onScrollGeometryChange(for: CGFloat.self) { geometry in
            geometry.contentOffset.y + geometry.contentInsets.top
        } action: { _, offset in
            pull = min(0, offset)
        }
        .heroUnderBar()
        .skyrBackground(artist.primaryColor)
        .clearNavigationBar()
        .inlineTitle()
        .windowTitle(artist.name)
    }

    private var hero: some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(
                colors: [artist.primaryColor, artist.secondaryColor],
                startPoint: UnitPoint(x: 0.2, y: 0),
                endPoint: UnitPoint(x: 0.8, y: 1)
            )
            ArtworkView(album: featuredAlbum, cornerRadius: 0, highlight: false, size: .hero)
                .aspectRatio(nil, contentMode: .fill)
                .frame(height: 300)
                .clipped()
                .blur(radius: 24)
                .opacity(0.9)
            LinearGradient(colors: [.black.opacity(0.05), .black.opacity(0.45)], startPoint: .top, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 8) {
                Text(artist.name)
                    .font(.largeTitle.weight(.bold))
                    .lineLimit(2)
                Text(artist.summary)
                    .font(.subheadline)
                    .opacity(0.8)
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.bottom, 22)
        }
        .frame(height: 300 - pull)
        .clipped()
        .offset(y: pull)
        .accessibilityElement(children: .combine)
    }
}
