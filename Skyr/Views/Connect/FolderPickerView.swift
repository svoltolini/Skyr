import SkyrCore
import SwiftUI

/// Lets the user choose which folder on the drive holds their music, drilling into subfolders.
struct FolderPickerView: View {
    enum Mode {
        case onboarding, settings
    }

    let mode: Mode
    var parent: RemoteEntry? = nil
    @Environment(AppModel.self) private var model
    @Environment(PlayerModel.self) private var player
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [RemoteEntry] = []
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        Group {
            if mode == .onboarding {
                SetupPage(step: .folder, showsBack: true, contentTitle: parent?.name ?? "Music folder") {
                    list
                }
            } else {
                list
            }
        }
        .skyrBackground(mode == .settings ? player.tint : Palette.neutralTint)
        .navigationTitle(parent?.name ?? "Music folder")
        .titleDisplay(large: parent == nil)
        .task(id: parent?.path) {
            isLoading = true
            error = nil
            do {
                folders = try await model.loadFolders(in: parent?.path)
            } catch {
                self.error = error.localizedDescription
            }
            isLoading = false
        }
    }

    private var list: some View {
        List {
            if let parent {
                Section {
                    Button {
                        choose(path: parent.path)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title3)
                                .foregroundStyle(Palette.onInk)
                                .frame(width: 38, height: 38)
                                .background(Palette.ink, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Use “\(parent.name)”")
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(.primary)
                                Text(parent.path)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                } footer: {
                    Text("Everything inside this folder, including subfolders, is indexed.")
                }
            }

            Section {
                if isLoading {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Loading folders…")
                            .foregroundStyle(.secondary)
                    }
                } else if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                } else if folders.isEmpty {
                    Text(parent == nil ? "No shared folders are visible to this account." : "No subfolders")
                        .foregroundStyle(.secondary)
                }
                ForEach(folders) { folder in
                    NavigationLink {
                        FolderPickerView(mode: mode, parent: folder)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: parent == nil ? "externaldrive.fill" : "folder.fill")
                                .font(.title3)
                                .foregroundStyle(.secondary)
                                .frame(width: 38, height: 38)
                                .background(.quaternary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(folder.name)
                                    .font(.body.weight(.medium))
                                Text(folder.path)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.head)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                Text(parent == nil ? "Shared folders" : "Subfolders")
            } footer: {
                if parent == nil {
                    Text("Open the shared folder that holds your music and choose it, or a folder inside it, if the share also contains movies or other media. You can change this later in Settings.")
                }
            }
        }
        .groupedList()
        .connectColumn(width: 640)
        .hiddenScrollBackground()
    }

    private func choose(path: String) {
        switch mode {
        case .onboarding:
            model.chooseMusicFolder(path: path, showsProgress: true)
        case .settings:
            model.chooseMusicFolder(path: path, showsProgress: false)
            dismiss()
        }
    }
}
