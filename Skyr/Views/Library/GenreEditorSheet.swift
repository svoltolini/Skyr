import SkyrCore
import SwiftUI

/// Rename a genre or fold it into another one; opened by holding a genre card. Typing or picking the
/// name of an existing genre merges the two, which fixes tags that came in another language.
struct GenreEditorSheet: View {
    let genre: Genre
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @FocusState private var isEditingName: Bool

    init(genre: Genre) {
        self.genre = genre
        _name = State(initialValue: genre.name)
    }

    private var others: [Genre] { library.genres.filter { $0.id != genre.id } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// An existing genre whose name matches what was typed, so "religious" merges into "Religious".
    private var mergeTarget: Genre? { others.first { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame } }
    private var canSave: Bool { !trimmedName.isEmpty && trimmedName != genre.name }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        .focused($isEditingName)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                } header: {
                    Text("Name")
                } footer: {
                    Text(footer)
                }
                if !others.isEmpty {
                    Section {
                        ForEach(others) { other in
                            Button {
                                name = other.name
                                isEditingName = false
                            } label: {
                                HStack(spacing: 12) {
                                    ArtworkView(album: other.albums[0], cornerRadius: 6, highlight: false, size: .row)
                                        .frame(width: 36, height: 36)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(other.name)
                                            .foregroundStyle(.primary)
                                        Text(other.countText)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                    Spacer(minLength: 8)
                                    if mergeTarget?.id == other.id {
                                        Image(systemName: "checkmark")
                                            .font(.body.weight(.semibold))
                                            .foregroundStyle(Palette.ink)
                                            .transition(.scale.combined(with: .opacity))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        Text("Merge into")
                    }
                }
            }
            .animation(.snappy(duration: 0.25), value: mergeTarget?.id)
            .navigationTitle("Edit Genre")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { save() }
                        .disabled(!canSave)
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private var footer: String {
        if let mergeTarget {
            return "“\(genre.name)” disappears and its \(genre.countText) join “\(mergeTarget.name)”."
        }
        return "Albums tagged “\(genre.name)” show under this name. You can change it back in Settings."
    }

    private func save() {
        let name = genre.name
        let target = mergeTarget?.name ?? trimmedName
        dismiss()
        // The sheet starts closing first; the library changes behind it.
        Task { @MainActor in library.renameGenre(name, to: target) }
    }
}

/// Settings page listing every renamed genre, with a way to undo each one.
struct GenreNamesView: View {
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player

    var body: some View {
        Group {
            if library.genreRenames.isEmpty {
                ScrollView {
                    EmptyStateView(
                        title: "No Renamed Genres",
                        systemImage: "tag",
                        message: Hints.renameGenre
                    )
                }
            } else {
                renames
            }
        }
        .skyrBackground(player.tint)
        .navigationTitle("Genre Names")
        .inlineTitle()
    }

    private var renames: some View {
        List {
            Section {
                ForEach(library.genreRenames, id: \.tag) { rename in
                    HStack(spacing: 8) {
                        Text(rename.tag)
                            .foregroundStyle(.secondary)
                        Image(systemName: "arrow.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        Text(rename.name)
                    }
                    .lineLimit(1)
                }
                .onDelete { offsets in
                    for tag in offsets.map({ library.genreRenames[$0].tag }) {
                        library.resetGenre(tag: tag)
                    }
                }
            } footer: {
                Text("Swipe a row to show that genre under its original name again.")
            }
            Section {
                Button("Reset All", role: .destructive) { library.resetGenreNames() }
            }
        }
        .hiddenScrollBackground()
    }
}
