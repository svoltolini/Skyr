import SkyrCore
import SwiftUI

/// Rename a genre or fold it into another one; opened by holding a genre card. Typing or picking the
/// name of an existing genre merges the two, which fixes tags that came in another language.
struct GenreEditorSheet: View {
    let genre: Genre
    private let isContextCurrent: () -> Bool
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String
    @FocusState private var isEditingName: Bool

    init(genre: Genre, isContextCurrent: @escaping () -> Bool = { true }) {
        self.genre = genre
        self.isContextCurrent = isContextCurrent
        _name = State(initialValue: genre.name)
    }

    private var others: [Genre] { library.genres.filter { $0.id != genre.id } }
    private var trimmedName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    /// An existing genre whose name matches what was typed, so "religious" merges into "Religious".
    private var mergeTarget: Genre? { others.first { $0.name.localizedCaseInsensitiveCompare(trimmedName) == .orderedSame } }
    private var canSave: Bool { isContextCurrent() && !trimmedName.isEmpty && trimmedName != genre.name }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    TextField("Name", text: $name)
                        #if os(macOS)
                        .textFieldStyle(.roundedBorder)
                        #endif
                        .focused($isEditingName)
                        .submitLabel(.done)
                        .onSubmit { if canSave { save() } }
                    #if os(macOS)
                    Text(footer)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    #endif
                } header: {
                    Text("Name")
                } footer: {
                    #if !os(macOS)
                    Text(footer)
                        .fixedSize(horizontal: false, vertical: true)
                    #endif
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
                                            .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
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
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25), value: mergeTarget?.id)
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
        .onAppear { isEditingName = true }
    }

    private var footer: String {
        if let mergeTarget {
            return "“\(genre.name)” disappears and its \(genre.countText) join “\(mergeTarget.name)”."
        }
        return "Albums tagged “\(genre.name)” show under this name. You can change it back in Settings."
    }

    private func save() {
        guard canSave else { return }
        let name = genre.name
        let target = mergeTarget?.name ?? trimmedName
        dismiss()
        // The sheet starts closing first; the library changes behind it.
        Task { @MainActor in
            guard isContextCurrent() else { return }
            library.renameGenre(name, to: target)
        }
    }
}

#if os(tvOS)
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
                Text("Use Reset All to restore the original genre names.")
            }
            Section {
                Button("Reset All", role: .destructive) { library.resetGenreNames() }
            }
        }
        .hiddenScrollBackground()
    }
}

#else
/// Renamed genres use the same native list and reset actions as the other preferences.
struct GenreNamesView: View {
    @Environment(LibraryStore.self) private var library
    @State private var isConfirmingReset = false

    var body: some View {
        List {
            if library.genreRenames.isEmpty {
                ContentUnavailableView("No Renamed Genres", systemImage: "tag", description: Text(Hints.renameGenre))
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(library.genreRenames, id: \.tag) { rename in
                        HStack {
                            LabeledContent(rename.tag, value: rename.name)
                            #if os(macOS)
                            Button("Reset") { library.resetGenre(tag: rename.tag) }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Reset \(rename.name) to \(rename.tag)")
                            #endif
                        }
                    }
                    .onDelete { offsets in
                        let tags = offsets.map { library.genreRenames[$0].tag }
                        for tag in tags { library.resetGenre(tag: tag) }
                    }
                } header: {
                    Text("Custom names")
                } footer: {
                    #if os(macOS)
                    Text("Reset a genre to show its original name again. Your music files stay unchanged.")
                    #else
                    Text("Swipe a row to show that genre under its original name again. Your music files stay unchanged.")
                    #endif
                }
                Section {
                    Button("Reset All", role: .destructive) { isConfirmingReset = true }
                }
            }
        }
        .groupedList()
        .navigationTitle("Genre Names")
        .inlineTitle()
        .confirmationDialog("Reset all genre names?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
            Button("Reset All", role: .destructive) { library.resetGenreNames() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Every genre will use its original tag. This does not change the music files on your NAS.")
        }
    }
}
#endif
