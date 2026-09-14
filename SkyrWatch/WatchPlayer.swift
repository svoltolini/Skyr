import AVFoundation
import Foundation
import MediaPlayer
import Observation
import SkyrCore

/// Plays a downloaded playlist from the watch's own storage, through whatever headphones the
/// system offers when the audio session comes up. The Now Playing screen and the crown are wired
/// through the system's remote commands and now-playing info.
@Observable
@MainActor
final class WatchPlayer {
    private(set) var current: WatchTrack?
    private(set) var isPlaying = false
    private(set) var queueTitle: String?

    private let player = AVQueuePlayer()
    private var queue: [(track: WatchTrack, url: URL)] = []
    private var itemTracks: [ObjectIdentifier: WatchTrack] = [:]
    private var observers: [NSKeyValueObservation] = []
    private var commandsReady = false

    init() {
        // KVO arrives on whatever thread changed the player; hop to the main actor before touching state.
        observers.append(player.observe(\.currentItem, options: [.new]) { @Sendable [weak self] player, _ in
            let item = player.currentItem
            Task { @MainActor in self?.currentItemChanged(item) }
        })
        observers.append(player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] player, _ in
            let playing = player.timeControlStatus == .playing
            Task { @MainActor in
                self?.isPlaying = playing
                self?.updateNowPlaying()
            }
        })
    }

    /// Starts the playlist from a song, in order or shuffled.
    func play(_ files: [(track: WatchTrack, url: URL)], title: String, startingAt index: Int = 0, shuffled: Bool = false) async {
        guard !files.isEmpty else { return }
        var order = files
        if shuffled {
            order.shuffle()
        } else if index > 0, index < order.count {
            order = Array(order[index...]) + Array(order[..<index])
        }
        queue = order
        queueTitle = title
        setupRemoteCommands()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, policy: .longFormAudio)
            _ = try await session.activate(options: [])
        } catch {
            return
        }
        player.removeAllItems()
        itemTracks = [:]
        for entry in order {
            let item = AVPlayerItem(url: entry.url)
            itemTracks[ObjectIdentifier(item)] = entry.track
            player.insert(item, after: nil)
        }
        player.play()
    }

    func togglePlayPause() {
        if player.timeControlStatus == .playing { player.pause() } else { player.play() }
    }

    func next() { player.advanceToNextItem() }

    func previous() {
        guard let track = current, let index = queue.firstIndex(where: { $0.track.id == track.id }) else { return }
        if player.currentTime().seconds > 3 || index == 0 {
            player.seek(to: .zero)
        } else {
            Task { await play(queue, title: queueTitle ?? "", startingAt: index - 1) }
        }
    }

    private func currentItemChanged(_ item: AVPlayerItem?) {
        current = item.flatMap { itemTracks[ObjectIdentifier($0)] }
        updateNowPlaying()
    }

    private func setupRemoteCommands() {
        guard !commandsReady else { return }
        commandsReady = true
        let centre = MPRemoteCommandCenter.shared()
        centre.playCommand.addTarget { [weak self] _ in self?.player.play(); return .success }
        centre.pauseCommand.addTarget { [weak self] _ in self?.player.pause(); return .success }
        centre.togglePlayPauseCommand.addTarget { [weak self] _ in self?.togglePlayPause(); return .success }
        centre.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        centre.previousTrackCommand.addTarget { [weak self] _ in self?.previous(); return .success }
    }

    private func updateNowPlaying() {
        guard let track = current else {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
            return
        }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: track.artist,
            MPMediaItemPropertyAlbumTitle: track.album,
            MPMediaItemPropertyPlaybackDuration: track.duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: player.currentTime().seconds.isFinite ? player.currentTime().seconds : 0,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
    }
}
