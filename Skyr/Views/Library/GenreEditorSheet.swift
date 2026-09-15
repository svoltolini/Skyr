import SkyrCore
import SwiftUI

/// Rename a genre or fold it into another one; opened by holding a genre card. Typing or picking the
/// name of an existing genre merges the two, which fixes tags that came in another language.
/// With the server signed in, the new name is written into the songs' own genre tags on the NAS;
/// otherwise, and for songs whose files cannot be changed, it is shown on this device only.
struct GenreEditorSheet: View {
    let genre: Genre
    private let isContextCurrent: () -> Bool
    @Environment(LibraryStore.self) private var library
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name: String
    @State private var songCount = 0
    /// Songs shown here whose files carry another genre tag, left by a rename made before files were written.
    @State private var untaggedCount = 0
    @State private var isWriting = false
    @State private var writtenName = ""
    @State private var report: MetadataWriteReport?
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
    private var target: String { mergeTarget?.name ?? trimmedName }
    private var writesFiles: Bool { library.canWriteTags }
    /// The name is unchanged, but some files still carry another tag from a device-only rename:
    /// Done writes the shown name into them.
    private var commitsDeviceOnlyName: Bool { writesFiles && trimmedName == genre.name && untaggedCount > 0 }
    private var canSave: Bool {
        isContextCurrent() && !trimmedName.isEmpty && (trimmedName != genre.name || commitsDeviceOnlyName) && !isWriting
    }

    var body: some View {
        NavigationStack {
            List {
                if let report {
                    resultSections(report)
                } else if isWriting {
                    progressSection
                } else {
                    editingSections
                }
            }
            .animation(reduceMotion ? .easeInOut(duration: 0.15) : .snappy(duration: 0.25), value: mergeTarget?.id)
            .navigationTitle("Edit Genre")
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
                        Button("Done") { save() }
                            .disabled(!canSave)
                    }
                }
            }
        }
        .sheetDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isWriting)
        .onAppear {
            songCount = library.tracks(shownUnderGenre: genre.name).count
            untaggedCount = library.tracksCarryingAnotherTag(underGenre: genre.name).count
            isEditingName = true
        }
    }

    @ViewBuilder private var editingSections: some View {
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

    private var progressSection: some View {
        Section {
            TagWriteProgressView(writer: library.metadataWriter, title: "Writing “\(writtenName)”")
        } footer: {
            Text("Each song is downloaded, its genre tag rewritten and the file put back on your NAS. Songs already written stay written if you stop.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func resultSections(_ report: MetadataWriteReport) -> some View {
        Section {
            Label(TagWriteSummary.line(for: report, noun: "genre"), systemImage: report.written.isEmpty ? "exclamationmark.triangle" : "checkmark.circle")
            ForEach(report.reasons, id: \.self) { reason in
                Text(reason)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } header: {
            Text(report.failures.isEmpty ? "Stopped" : "Some files were left unchanged")
        } footer: {
            Text("Those songs still show under “\(writtenName)” on this \(Device.noun). Genre Names in Settings lists them and can show them under their original tag again.")
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: String {
        let songs = "\(songCount) \(songCount == 1 ? "song" : "songs")"
        if writesFiles {
            if let mergeTarget {
                return "“\(genre.name)” disappears: the genre tag of its \(songs) is rewritten on your NAS as “\(mergeTarget.name)”. Other tags stay as they are."
            }
            if commitsDeviceOnlyName {
                return "\(untaggedCount) of these \(songs) carry another genre tag, or none, in their files. Done writes “\(genre.name)” into them on your NAS."
            }
            return "The genre tag of \(songs) is rewritten on your NAS. Other tags stay as they are; with many songs this can take a while."
        }
        if let mergeTarget {
            return "“\(genre.name)” disappears and its \(genre.countText) join “\(mergeTarget.name)” on this \(Device.noun). Connect to your server to change the files themselves."
        }
        return "Albums tagged “\(genre.name)” show under this name on this \(Device.noun). Connect to your server to change the files themselves."
    }

    private func save() {
        guard canSave else { return }
        let name = genre.name
        let newName = target
        guard writesFiles else {
            dismiss()
            // The sheet starts closing first; the library changes behind it.
            Task { @MainActor in
                guard isContextCurrent() else { return }
                library.renameGenre(name, to: newName)
            }
            return
        }
        isEditingName = false
        writtenName = newName
        isWriting = true
        Task { @MainActor in
            guard isContextCurrent() else {
                isWriting = false
                return
            }
            let result = await library.writeGenre(name, to: newName)
            isWriting = false
            if result.isComplete {
                dismiss()
            } else {
                report = result
            }
        }
    }
}

/// The bar and counter for a tag write in progress, fed by the store's writer.
struct TagWriteProgressView: View {
    let writer: MetadataWriter
    let title: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ProgressView(value: writer.progress) {
                Text(title)
            } currentValueLabel: {
                HStack {
                    Text("\(writer.completed) of \(writer.total)")
                    if let current = writer.currentTitle {
                        Text("· \(current)")
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// One line saying what a tag write did.
enum TagWriteSummary {
    static func line(for report: MetadataWriteReport, noun: String) -> String {
        var parts: [String] = []
        if !report.written.isEmpty {
            parts.append("The \(noun) was written to \(report.written.count) \(report.written.count == 1 ? "song" : "songs").")
        }
        if !report.unchanged.isEmpty {
            parts.append("\(report.unchanged.count) already had it.")
        }
        if !report.failures.isEmpty {
            parts.append("\(report.failures.count) \(report.failures.count == 1 ? "song" : "songs") couldn't be changed.")
        }
        if report.wasCancelled {
            parts.append("You stopped before the rest were tried.")
        }
        return parts.isEmpty ? "Nothing needed changing." : parts.joined(separator: " ")
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
                    Text("These names apply on this Mac only, for songs whose files couldn't be rewritten when a genre was renamed. Reset a genre to show its original tag again.")
                    #else
                    Text("These names apply on this \(Device.noun) only, for songs whose files couldn't be rewritten when a genre was renamed. Swipe a row to show that genre under its original tag again.")
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
            Text("Every genre will show the tag its files carry. Nothing on your NAS changes.")
        }
    }
}
#endif
