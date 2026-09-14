import SkyrCore
import SwiftUI

/// One playlist: download it to the watch, then play or shuffle it; songs below play from a tap.
struct PlaylistDetailView: View {
    private let initialPlaylist: WatchPlaylist
    @Environment(WatchStore.self) private var store
    @Environment(WatchDownloads.self) private var downloads
    @Environment(WatchPlayer.self) private var player
    @State private var isConfirmingRemoval = false

    init(playlist: WatchPlaylist) { initialPlaylist = playlist }

    private var currentPlaylist: WatchPlaylist? { store.catalogue?.playlist(matching: initialPlaylist) }
    private var playlist: WatchPlaylist { currentPlaylist ?? initialPlaylist }

    private var state: WatchDownloads.State { downloads.state(of: playlist) }
    private var isOnWatch: Bool { downloads.isDownloaded(playlist) }

    var body: some View {
        Group {
            if currentPlaylist != nil {
                playlistContent
            } else {
                VStack(spacing: 12) {
                    Text("This playlist is no longer in the current library.")
                        .multilineTextAlignment(.center)
                    Text("Go back to choose a playlist from your latest sync.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    removalButton
                }
                .padding()
            }
        }
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Remove from the watch?", isPresented: $isConfirmingRemoval, titleVisibility: .visible) {
            Button("Remove Download", role: .destructive) { downloads.remove(playlist) }
        }
    }

    private var playlistContent: some View {
        ScrollView {
            VStack(spacing: 10) {
                MosaicView(colours: playlist.coverColours, cornerRadius: 14)
                    .frame(width: 92, height: 92)
                    .padding(.top, 4)
                Text(playlist.name)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(summary)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                controls
                    .padding(.top, 2)
                if playlist.isCut {
                    Text("The first \(WatchCatalogue.songLimit) of \(playlist.totalSongs) songs come to the watch.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                songs
                    .padding(.top, 8)
            }
            .padding(.horizontal, 4)
        }
    }

    private var summary: String {
        "\(playlist.tracks.count) songs · \(ByteText.format(playlist.totalBytes))"
    }

    @ViewBuilder private var controls: some View {
        switch state {
        case .none, .failed:
            if case .failed(let message) = state {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            if store.isSample {
                Text("Downloads need a server; this is the sample library.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else if playlist.cacheID == nil {
                Text("Open Skyr on your iPhone to refresh this playlist before downloading.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            } else if let credentials = store.credentials(), credentials.matches(playlist) {
                Button {
                    Task { await downloads.download(playlist, credentials: credentials) }
                } label: {
                    Label(state == .none ? "Download" : "Try Again", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.brand)
            } else {
                Text("Open Skyr on your iPhone to sign the watch in.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        case .downloading(let done, let total):
            ProgressView(value: Double(done), total: Double(max(total, 1))) {
                Text("Downloading \(done) of \(total)")
                    .font(.caption2)
            }
            .tint(Palette.brand)
            Button("Cancel", role: .cancel) { downloads.cancel(playlist) }
                .font(.caption)
        case .downloaded:
            HStack(spacing: 8) {
                Button {
                    Task { await player.play(downloads.files(for: playlist), title: playlist.name) }
                } label: {
                    Label("Play", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.brand)
                Button {
                    Task { await player.play(downloads.files(for: playlist), title: playlist.name, shuffled: true) }
                } label: {
                    Image(systemName: "shuffle")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("Shuffle")
            }
        }
        removalButton
    }

    @ViewBuilder private var removalButton: some View {
        if downloads.hasSavedFiles(for: playlist) {
            Button("Remove from Watch", role: .destructive) { isConfirmingRemoval = true }
                .font(.caption2)
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
    }

    private var songs: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            ForEach(Array(playlist.tracks.enumerated()), id: \.element.id) { index, track in
                Button {
                    guard isOnWatch else { return }
                    let files = downloads.files(for: playlist)
                    guard let playableIndex = files.firstIndex(where: { $0.track.id == track.id }) else { return }
                    Task { await player.play(files, title: playlist.name, startingAt: playableIndex) }
                } label: {
                    HStack(spacing: 8) {
                        if player.current?.id == track.id {
                            Image(systemName: "speaker.wave.2.fill")
                                .font(.caption2)
                                .foregroundStyle(Palette.brand)
                                .frame(width: 16)
                        } else {
                            Text("\(index + 1)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .frame(width: 16, alignment: .trailing)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            Text(track.title)
                                .font(.footnote)
                                .lineLimit(1)
                            Text(track.artist)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .opacity(isOnWatch ? 1 : 0.55)
                if index < playlist.tracks.count - 1 {
                    Divider().padding(.leading, 24)
                }
            }
        }
    }
}
