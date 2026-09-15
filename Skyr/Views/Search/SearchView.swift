import SkyrCore
import SwiftUI

/// Search tab: type to find artists, albums and songs; recent searches while the field is empty.
struct SearchView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    @Namespace private var artworkNamespace
    /// Recomputed for query changes or a published catalogue revision, preserving the search field and stack.
    @State private var results = SearchResults()
    @FocusState private var isSearchFocused: Bool

    private var query: String { model.searchQuery.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        @Bindable var model = model
        NavigationStack {
            Group {
                if query.isEmpty {
                    idleView
                        .transition(.opacity)
                } else {
                    resultsList
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.2), value: query.isEmpty)
            .onChange(of: query, initial: true) { _, query in
                results = library.searchResults(query)
            }
            .onChange(of: library.contentRevision) { _, _ in
                results = library.searchResults(query)
            }
            .hiddenScrollBackground()
            .skyrBackground(player.tint)
            .navigationTitle("Search")
            .largeTitle()
            .searchField(text: $model.searchQuery, prompt: "Albums, artists, songs")
            .focusesSearch($isSearchFocused)
            .onAppear {
                #if os(macOS)
                isSearchFocused = true
                #endif
            }
            .onSubmit(of: .search) {
                library.noteSearch(model.searchQuery)
            }
            .libraryDestinations()
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }

    /// Recent searches as chips, or a quiet prompt when there are none yet.
    @ViewBuilder
    private var idleView: some View {
        if library.recentSearches.isEmpty {
            ScrollView {
                EmptyStateView(title: "Search Your Library", systemImage: "magnifyingglass", message: "Find albums, artists and songs by name.")
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Eyebrow(text: "Recent")
                    FlowLayout(spacing: 8) {
                        ForEach(library.recentSearches, id: \.self) { term in
                            Button(term) { model.searchQuery = term }
                                .buttonStyle(.glass)
                        }
                    }
                    .padding(.horizontal, 24)
                }
                .padding(.top, 8)
            }
        }
    }

    @ViewBuilder
    private var resultsList: some View {
        if results.isEmpty {
            ScrollView {
                EmptyStateView(title: "No Results", systemImage: "magnifyingglass", message: "Nothing in your library matches “\(query)”.")
            }
        } else {
            List {
                if !results.artists.isEmpty {
                    Section("Artists") {
                        ForEach(results.artists) { artist in
                            let destination = ArtistDestination(artist, source: "search")
                            NavigationLink(value: destination) {
                                HStack(spacing: 12) {
                                    ArtistPortrait(artist: artist, size: .row)
                                        .frame(width: 44, height: 44)
                                        .zoomSource(id: destination.sourceID, shape: .circle(44))
                                    VStack(alignment: .leading, spacing: 2) {
                                        FadingText(artist.name)
                                            .font(.body.weight(.medium))
                                        Text(artist.summary)
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    }
                }
                if !results.albums.isEmpty {
                    Section("Albums") {
                        ForEach(results.albums) { album in
                            let destination = AlbumDestination(album, source: "search")
                            NavigationLink(value: destination) {
                                AlbumRow(album: album, detail: album.artist, destination: destination)
                            }
                        }
                    }
                }
                if !results.tracks.isEmpty {
                    Section("Songs") {
                        ForEach(results.tracks) { track in
                            Button {
                                if let album = library.album(for: track) {
                                    player.play(album: album, startingAt: track.index)
                                }
                            } label: {
                                HStack(spacing: 12) {
                                    if let album = library.album(for: track) {
                                        ArtworkView(album: album, cornerRadius: 6, highlight: false, size: .row)
                                            .frame(width: 44, height: 44)
                                    }
                                    VStack(alignment: .leading, spacing: 2) {
                                        FadingText(track.title)
                                            .font(.body.weight(player.isCurrent(track: track) ? .semibold : .regular))
                                        FadingText(library.album(for: track).map { "\($0.artist) · \($0.title)" } ?? track.artist ?? " ")
                                            .font(.footnote)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    Text(TimeText.clock(track.duration))
                                        .font(.footnote)
                                        .monospacedDigit()
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .groupedList()
        }
    }
}
