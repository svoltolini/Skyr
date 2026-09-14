import SkyrCore
import SwiftUI

/// Picks a playlist for one or more songs, or creates a new one for them.
struct AddToPlaylistSheet: View {
    let tracks: [Track]
    var isContextCurrent: () -> Bool = { true }
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @FocusState private var isNaming: Bool

    private var localPlaylists: [Playlist] { library.playlists.filter { library.isLocalPlaylist($0.id) } }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(Palette.ink)
                        TextField("New playlist", text: $newName)
                            .focused($isNaming)
                            .submitLabel(.done)
                            .onSubmit(createAndAdd)
                        if !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                            Button("Create", action: createAndAdd)
                                .font(.body.weight(.semibold))
                        }
                    }
                }
                Section("Your playlists") {
                    if localPlaylists.isEmpty {
                        Text("No playlists yet. Name one above to create it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(localPlaylists) { playlist in
                        Button {
                            guard isContextCurrent() else { dismiss(); return }
                            library.add(tracks, toPlaylist: playlist.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                MosaicArtwork(albums: playlist.covers, cornerRadius: 6)
                                    .frame(width: 44, height: 44)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(playlist.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text(playlist.summary)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            #if os(macOS)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                            #endif
                        }
                        #if os(macOS)
                        .buttonStyle(.plain)
                        #endif
                    }
                }
            }
            .navigationTitle(tracks.count == 1 ? "Add to Playlist" : "Add \(tracks.count) Songs")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheetDetents([.medium, .large])
    }

    private func createAndAdd() {
        guard isContextCurrent() else { dismiss(); return }
        guard library.createPlaylist(named: newName, tracks: tracks) != nil else { return }
        dismiss()
    }
}

/// Context menu entries shared by every song row.
/// The "…" button on a song row: favourite it, add it to a playlist or, when allowed, remove it.
struct TrackActionsMenu: View {
    let track: Track
    var onRemove: (() -> Void)? = nil
    @Binding var isAddingToPlaylist: Bool
    @Environment(LibraryStore.self) private var library

    var body: some View {
        Menu {
            Button(library.isFavourite(track) ? "Remove from Favourites" : "Favourite", systemImage: library.isFavourite(track) ? "heart.slash" : "heart") {
                library.toggleFavourite(track)
            }
            Button("Add to Playlist…", systemImage: "text.badge.plus") {
                isAddingToPlaylist = true
            }
            if let onRemove {
                Button("Remove from Playlist", systemImage: "minus.circle", role: .destructive, action: onRemove)
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, height: 44)
                .contentShape(Rectangle())
        }
        .menuIndicator(.hidden)
        .sensoryFeedback(.selection, trigger: library.isFavourite(track))
        .accessibilityLabel("More")
    }
}

/// Small heart shown on rows of favourite songs.
struct FavouriteMark: View {
    var body: some View {
        Image(systemName: "heart.fill")
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Favourite")
    }
}
