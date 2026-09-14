import SkyrCore
import SwiftUI

/// "Artists" facet: alphabetical card list.
struct ArtistsListView: View {
    @Environment(LibraryStore.self) private var library

    var body: some View {
        CardList(data: library.artists, separatorInset: 76) { artist in
            let destination = ArtistDestination(artist, source: "artists")
            NavigationLink(value: destination) {
                HStack(spacing: 14) {
                    ArtistPortrait(artist: artist, size: .row)
                        .frame(width: 46, height: 46)
                        .zoomSource(id: destination.sourceID, shape: .circle(46))
                    VStack(alignment: .leading, spacing: 2) {
                        FadingText(artist.name)
                            .font(.body.weight(.medium))
                        Text(artist.summary)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 8)
                    DisclosureChevron()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 11)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
        .padding(.top, 4)
    }
}
