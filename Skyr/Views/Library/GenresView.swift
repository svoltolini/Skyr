import SkyrCore
import SwiftUI

/// "Genres" facet: decade tiles followed by a two column genre grid. Holding a genre card opens the editor.
struct GenresView: View {
    @Environment(LibraryStore.self) private var library
    @State private var editingGenre: Genre?
    @Environment(\.isWideLayout) private var isWide
    private var columns: [GridItem] { Grids.tiles(wide: isWide) }

    var body: some View {
        if !library.decades.isEmpty {
            Eyebrow(text: "Decades")
            ScrollView(.horizontal) {
                LazyHStack(spacing: 10) {
                    ForEach(library.decades) { decade in
                        let destination = CollectionDestination(AlbumCollection(title: decade.label, albums: decade.albums), source: "decades")
                        NavigationLink(value: destination) {
                            DecadeTile(decade: decade)
                                .zoomSource(id: destination.sourceID, shape: .rounded(14))
                        }
                        .cardButton()
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, 24, for: .scrollContent)
            .scrollTargetBehavior(.viewAligned)
            .scrollIndicators(.hidden)
            .padding(.top, 10)
        }

        Eyebrow(text: "Genres")
            .padding(.top, library.decades.isEmpty ? 0 : 26)
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(library.genres) { genre in
                let destination = CollectionDestination(AlbumCollection(title: genre.name, albums: genre.albums), source: "genres")
                NavigationLink(value: destination) {
                    GenreCard(genre: genre)
                        .zoomSource(id: destination.sourceID, shape: .rounded(14))
                }
                .cardButton()
                .simultaneousGesture(LongPressGesture(minimumDuration: 0.4).onEnded { _ in editingGenre = genre })
                .genreMenu { editingGenre = genre }
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 10)
        .sensoryFeedback(.impact(weight: .medium), trigger: editingGenre) { _, new in new != nil }
        .sheet(item: $editingGenre) { genre in
            GenreEditorSheet(genre: genre)
        }
    }
}

/// A decade as a mosaic of its own covers with the years written over it.
struct DecadeTile: View {
    let decade: Decade

    var body: some View {
        MosaicArtwork(albums: decade.albums, cornerRadius: 14)
            .frame(width: 150 * Metrics.scale, height: 150 * Metrics.scale)
            .overlay {
                LinearGradient(
                    stops: [.init(color: .clear, location: 0.35), .init(color: .black.opacity(0.62), location: 1)],
                    startPoint: .top, endPoint: .bottom
                )
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(decade.label)
                        .font(.title2.weight(.bold))
                        .kerning(-0.4)
                    Text(decade.countText)
                        .font(.caption.weight(.medium))
                        .opacity(0.85)
                }
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.35), radius: 4, y: 1)
                .padding(12)
            }
            .accessibilityElement(children: .combine)
    }
}

struct GenreCard: View {
    let genre: Genre

    var body: some View {
        HStack(spacing: 12) {
            ArtworkView(album: genre.albums[0], cornerRadius: 8, highlight: false, size: .row)
                .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(genre.name)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(genre.countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(Color.groupedCard, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// The Mac's way in to the genre editor; the phone holds the card instead.
    @ViewBuilder func genreMenu(_ action: @escaping () -> Void) -> some View {
        #if os(macOS)
        contextMenu {
            Button("Rename or Merge Genre…", systemImage: "pencil", action: action)
        }
        #else
        self
        #endif
    }
}
