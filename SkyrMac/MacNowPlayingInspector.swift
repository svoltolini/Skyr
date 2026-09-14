import SkyrCore
import SwiftUI

/// A desktop companion to the library, with the current album and a selectable queue.
struct MacNowPlayingInspector: View {
    @Environment(PlayerModel.self) private var player
    @Environment(MacNavigation.self) private var navigation
    @State private var entries: [TrackListEntry] = []
    @State private var selection: TrackListEntry.ID?

    var body: some View {
        let displayedEntries = entries
        let displayedCommand = player.commandRevision
        VStack(spacing: 0) {
            HStack {
                Text("Now Playing").font(.headline)
                Spacer()
                Button("Close Now Playing", systemImage: "xmark") { navigation.isShowingNowPlaying = false }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
            }
            .padding(16)
            Divider()
            MacCurrentTrackDetails()
            Divider()
            HStack {
                Text("Queue").font(.headline)
                Spacer()
                Text(entries.count.formatted()).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            List(selection: $selection) {
                ForEach(entries) { entry in
                    MacQueueRow(entry: entry).tag(entry.id)
                }
            }
            .listStyle(.inset)
            .contextMenu(forSelectionType: TrackListEntry.ID.self) { ids in
                if !ids.isEmpty {
                    Button("Play", systemImage: "play.fill") {
                        play(ids, from: displayedEntries, command: displayedCommand)
                    }
                }
            } primaryAction: { ids in
                play(ids, from: displayedEntries, command: displayedCommand)
            }
            .onKeyPress(.return) {
                guard let selection else { return .ignored }
                play([selection], from: displayedEntries, command: displayedCommand)
                return .handled
            }
            .onKeyPress(.space) {
                guard player.hasTrack else { return .ignored }
                player.togglePlayPause()
                return .handled
            }
            .overlay {
                if entries.isEmpty { Text("Play a song to start your queue.").foregroundStyle(.secondary).padding() }
            }
            .accessibilityLabel("Playback queue")
        }
        .background(.background)
        .onChange(of: player.queue, initial: true) { _, queue in
            entries = TrackListEntry.make(from: queue)
            selection = nil
        }
    }

    private func play(_ ids: Set<TrackListEntry.ID>, from displayedEntries: [TrackListEntry], command: UUID) {
        // A menu can remain open while playback replaces its queue. Ignore that stale selection.
        guard command == player.commandRevision, displayedEntries == entries,
              displayedEntries.map(\.track) == player.queue,
              let entry = displayedEntries.first(where: { ids.contains($0.id) }) else { return }
        player.playQueuedTrack(at: entry.position)
    }
}

private struct MacCurrentTrackDetails: View {
    @Environment(PlayerModel.self) private var player
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let track = player.track {
                if let album = player.album {
                    ArtworkView(album: album, cornerRadius: 8, highlight: false, size: .hero)
                        .aspectRatio(1, contentMode: .fit)
                        .frame(maxWidth: 180)
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 8)
                }
                Text(track.title).font(.headline).lineLimit(2)
                Text(player.album?.artist ?? track.artist ?? "Unknown Artist").foregroundStyle(.secondary).lineLimit(2)
                Text(track.format).font(.caption).foregroundStyle(.secondary)
                if let album = player.album {
                    Button("Go to Album", systemImage: "square.stack") { model.showAlbum(album) }
                        .controlSize(.small)
                }
                if let error = player.lastError {
                    Text(error).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Button("Retry Playback", systemImage: "arrow.clockwise") { player.resume() }
                }
            } else {
                Label("Nothing Playing", systemImage: "music.note").foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }
}

private struct MacQueueRow: View {
    let entry: TrackListEntry
    @Environment(PlayerModel.self) private var player
    @Environment(LibraryStore.self) private var library

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: player.index == entry.position ? "speaker.wave.2.fill" : "music.note")
                .foregroundStyle(player.index == entry.position ? Color.accentColor : .secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.track.title).lineLimit(1)
                Text(entry.track.artist ?? library.album(for: entry.track)?.artist ?? "Unknown Artist")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(TimeText.clock(entry.track.duration)).font(.caption).monospacedDigit().foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
        .accessibilityValue(player.index == entry.position ? "Current song" : "")
    }
}
