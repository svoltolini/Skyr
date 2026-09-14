import SkyrCore
import SwiftUI

/// Non-model destinations reachable from the navigation stacks.
nonisolated enum LibraryRoute: Hashable {
    case downloads
}

/// A titled list of albums, used by "See all" and genre drill-downs.
nonisolated struct AlbumCollection: Hashable {
    let title: String
    let albums: [Album]
}

struct LibraryView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Namespace private var artworkNamespace

    private var isEmptyLibrary: Bool { library.isEmpty && !model.isDemo }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    if isEmptyLibrary {
                        emptyState
                    } else {
                        if model.indexingFailure != nil {
                            VStack(alignment: .leading, spacing: 8) {
                                Label("Library update incomplete", systemImage: "exclamationmark.triangle")
                                    .font(.headline)
                                Text("Your previous library has been kept. " + emptyDescription)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                Button("Retry Update") { model.rescan() }
                            }
                            .padding(20)
                        }
                        #if !os(macOS)
                        LibraryFacetHeader()
                            .padding(.bottom, 8)
                        #endif
                        Group {
                            switch model.facet {
                            case .recentlyAdded: LibraryHomeView()
                            case .artists: ArtistsListView()
                            case .genres: GenresView()
                            }
                        }
                        // The old facet fades out first; the new one then fades in while rising a little,
                        // so the two layouts never show on top of each other.
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .offset(y: 10)).animation(.easeOut(duration: 0.3).delay(0.12)),
                            removal: .opacity.animation(.easeIn(duration: 0.14))
                        ))
                    }
                }
                .padding(.bottom, 32)
                .animation(.easeInOut(duration: 0.25), value: model.facet)
            }
            .pullToRefresh {
                // Pull down to scan the folder again; the shelf shows progress from here on.
                await model.rescan()
                try? await Task.sleep(for: .seconds(1))
            }
            .skyrBackground(player.tint)
            .navigationTitle("Library")
            .modifier(LibrarySubtitle())
            .libraryDestinations()
            .navigationDestination(item: $model.albumToOpen) { AlbumView(album: $0) }
            .toolbar {
                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("Scan for New Music", systemImage: "arrow.clockwise") { model.rescan() }
                        .help("Look for music added to the folder since the last scan")
                }
                #endif
            }
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }

    private var emptyDescription: String {
        switch model.indexingFailure {
        case .missing: "The folder you chose no longer exists. You can pick another one in Settings."
        case .unreadable(_, let path): "Some folders in “\(LibraryIndexer.Failure.name(of: path))” couldn't be read. Check the account's permissions. \(Hints.tryAgain)"
        case .other(let message): message + " " + Hints.tryAgain
        case .noMusic, .none: "Add music to “\(library.catalogue.rootName)” and \(Hints.rescan), or pick another folder in Settings."
        }
    }

    /// Shown while the folder holds no music, or the chosen folder is gone. Pulling down scans again.
    private var emptyState: some View {
        EmptyStateView(title: "No Music Found", systemImage: "music.note", message: emptyDescription)
    }
}

extension View {
    /// Destinations shared by every navigation stack that can open catalogue content.
    func libraryDestinations() -> some View {
        self
            .navigationDestination(for: Album.self) { AlbumView(album: $0) }
            .navigationDestination(for: AlbumDestination.self) { AlbumView(album: $0.album).artworkZoom(from: $0) }
            .navigationDestination(for: Artist.self) { ArtistView(artist: $0) }
            .navigationDestination(for: ArtistDestination.self) { ArtistView(artist: $0.artist).zoomDestination(id: $0.sourceID) }
            .navigationDestination(for: AlbumCollection.self) { AlbumCollectionView(collection: $0) }
            .navigationDestination(for: CollectionDestination.self) { AlbumCollectionView(collection: $0.collection).zoomDestination(id: $0.sourceID) }
            .navigationDestination(for: Playlist.self) { PlaylistDetailView(playlist: $0) }
            .navigationDestination(for: PlaylistDestination.self) { PlaylistDetailView(playlist: $0.playlist).zoomDestination(id: $0.sourceID) }
            .navigationDestination(for: LibraryRoute.self) { route in
                switch route {
                case .downloads: DownloadsView()
                }
            }
    }
}

/// The line under the Library title, read in a scope of its own: it changes with every scan
/// progress report, and reading it in the Library's body re-evaluated every shelf each time.
private struct LibrarySubtitle: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.windowSubtitle(model.librarySubtitle)
    }
}

/// Facet chips placed at the top of each facet's content so they scroll with it.
struct LibraryFacetHeader: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        FacetPicker(selection: $model.facet)
    }
}

/// Horizontal row of glass chips. Selecting one is a quick, clean flip: the ink fades in over 0.2 s and the
/// label colour switches halfway through, so the text stays readable and nothing slides or bounces.
struct FacetPicker: View {
    @Binding var selection: LibraryFacet

    var body: some View {
        #if os(tvOS)
        // The television's own segmented control: focus lifts a segment to white, the chosen one
        // stays a lighter grey, and the segments keep their distance. Glass chips fuse together
        // at this size and give the remote nothing to highlight.
        Picker("Section", selection: $selection) {
            ForEach(LibraryFacet.allCases) { facet in
                Text(facet.rawValue).tag(facet)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .frame(maxWidth: .infinity)
        .padding(.top, 8)
        .padding(.bottom, 28)
        .sensoryFeedback(.selection, trigger: selection)
        #else
        chips
        #endif
    }

    private var chips: some View {
        ScrollView(.horizontal) {
            GlassEffectContainer(spacing: 8) {
                HStack(spacing: 8) {
                    ForEach(LibraryFacet.allCases) { facet in
                        chip(for: facet)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
        }
        .scrollIndicators(.hidden)
        .scrollClipDisabled()
        .sensoryFeedback(.selection, trigger: selection)
    }

    private func chip(for facet: LibraryFacet) -> some View {
        let isSelected = facet == selection
        return Button {
            selection = facet
        } label: {
            Text(facet.rawValue)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Palette.onInk : .primary)
                // Flip the label colour in a short window centred on the moment the ink is half way,
                // so it is never light-on-light or dark-on-dark.
                .animation(.easeInOut(duration: 0.05).delay(0.055), value: isSelected)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background {
                    Capsule()
                        .fill(Palette.ink)
                        .opacity(isSelected ? 1 : 0)
                        .animation(.easeInOut(duration: 0.22), value: isSelected)
                }
                .glassEffect(.regular, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

struct AlbumCollectionView: View {
    let collection: AlbumCollection
    @Environment(PlayerModel.self) private var player

    var body: some View {
        List(collection.albums) { album in
            let destination = AlbumDestination(album, source: "collection")
            NavigationLink(value: destination) {
                AlbumRow(album: album, detail: "\(album.artist)\(album.year > 0 ? " · \(String(album.year))" : "")", destination: destination)
            }
        }
        .hiddenScrollBackground()
        .skyrBackground(player.tint)
        .navigationTitle(collection.title)
        .inlineTitle()
    }
}

/// Compact album line used in lists: 48pt art, title, one detail line.
struct AlbumRow: View {
    let album: Album
    let detail: String
    var destination: AlbumDestination? = nil

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let destination {
                    ArtworkView(album: album, cornerRadius: 6, size: .row).artworkSource(destination, cornerRadius: 6)
                } else {
                    ArtworkView(album: album, cornerRadius: 6, size: .row)
                }
            }
            .frame(width: 48, height: 48)
            VStack(alignment: .leading, spacing: 2) {
                FadingText(album.title)
                    .font(.body.weight(.medium))
                FadingText(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
