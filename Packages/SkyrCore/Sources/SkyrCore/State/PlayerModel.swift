import AVFoundation
import MediaPlayer
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// Streams tracks from the server with AVPlayer; simulates playback for the demo catalogue.
@Observable
public final class PlayerModel {
    public nonisolated enum RepeatMode: String, CaseIterable, Sendable {
        case off, all, one
    }

    public private(set) var queue: [Track] = []
    /// The queue as it was handed over, for turning shuffle back off.
    private var orderedQueue: [Track] = []
    public private(set) var index = 0
    public var repeatMode: RepeatMode = .off {
        didSet { if repeatMode != oldValue { settingsChanged?(repeatMode, isShuffling) } }
    }
    public private(set) var isShuffling = false
    /// Set by the app: the profile remembers repeat and shuffle.
    public var settingsChanged: ((RepeatMode, Bool) -> Void)?

    /// Takes the profile's saved repeat and shuffle without touching the queue.
    public func applySettings(repeatMode: RepeatMode, shuffle: Bool) {
        self.repeatMode = repeatMode
        isShuffling = shuffle
    }

    /// Clears everything: another profile is taking over.
    public func stop() {
        teardown()
        queue = []
        orderedQueue = []
        index = 0
        album = nil
        queueTitle = nil
        isPlaying = false
        position = 0
        updateNowPlayingInfo()
    }
    public private(set) var isPlaying = false
    public private(set) var position: TimeInterval = 0
    public private(set) var album: Album?
    public private(set) var queueTitle: String?
    public private(set) var lastError: String?
    /// Output level, 0 to 1. The phone leaves this at 1 and uses its own controls; the Mac has a slider.
    public var volume: Float = 1 {
        didSet { player?.volume = volume }
    }

    /// Resolves a stream URL for a track; nil means the file is not reachable right now.
    public var streamURLProvider: ((Track) -> URL?)?
    /// Whether a track without a URL may pretend to play (the sample library) instead of reporting an error.
    public var allowsSimulation: (() -> Bool)?
    public var albumProvider: ((Track) -> Album?)?
    public var didStartAlbum: ((Album) -> Void)?
    public var didStartTrack: ((Track) -> Void)?

    private var player: AVPlayer?
    private var timeObserver: Any?
    private var endObserver: (any NSObjectProtocol)?
    private var statusObservation: NSKeyValueObservation?
    private var ticker: Task<Void, Never>?
    private var anchorDate: Date?
    private var anchorPosition: TimeInterval = 0
    private var isSimulated = false
    private var remoteCommandsReady = false
    private var interruptionObservers: [any NSObjectProtocol] = []
    private var wasPlayingBeforeInterruption = false
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkAlbumID: String?

    public init() {}

    public var track: Track? { queue.indices.contains(index) ? queue[index] : nil }
    public var hasTrack: Bool { track != nil }

    public var duration: TimeInterval {
        if let item = player?.currentItem, item.duration.isNumeric, item.duration.seconds > 0 {
            return item.duration.seconds
        }
        return track?.duration ?? 0
    }

    public var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    public var remaining: TimeInterval { max(0, duration - position) }
    /// Colour of the playing album as the library has it now, so cover colours read later still apply.
    public var tint: Color { (track.flatMap { albumProvider?($0) } ?? album)?.primaryColor ?? Palette.neutralTint }

    // MARK: Commands

    public func play(album: Album, startingAt index: Int = 0) {
        play(queue: album.tracks, startingAt: index, title: nil)
    }

    public func play(queue: [Track], startingAt index: Int = 0, title: String?) {
        guard !queue.isEmpty else { return }
        orderedQueue = queue
        queueTitle = title
        let start = min(max(0, index), queue.count - 1)
        if isShuffling {
            self.queue = [queue[start]] + queue.enumerated().filter { $0.offset != start }.map(\.element).shuffled()
            load(index: 0, autoplay: true)
        } else {
            self.queue = queue
            load(index: start, autoplay: true)
        }
    }

    /// Shuffles what comes after the current song, or restores the original order around it.
    public func toggleShuffle() {
        isShuffling.toggle()
        settingsChanged?(repeatMode, isShuffling)
        guard let current = track else { return }
        if isShuffling {
            queue = [current] + queue.filter { $0.id != current.id }.shuffled()
            index = 0
        } else if !orderedQueue.isEmpty {
            queue = orderedQueue
            index = orderedQueue.firstIndex { $0.id == current.id } ?? 0
        }
    }

    public func cycleRepeat() {
        switch repeatMode {
        case .off: repeatMode = .all
        case .all: repeatMode = .one
        case .one: repeatMode = .off
        }
    }

    public func togglePlayPause() {
        isPlaying ? pause() : resume()
    }

    public func resume() {
        guard hasTrack else { return }
        if isSimulated {
            anchorPosition = position
            anchorDate = .now
            startTicker()
        } else {
            player?.play()
        }
        isPlaying = true
        updateNowPlayingInfo()
    }

    public func pause() {
        if isSimulated {
            syncSimulatedPosition()
            stopTicker()
            anchorDate = nil
        } else {
            player?.pause()
        }
        isPlaying = false
        updateNowPlayingInfo()
    }

    public func next() { advance(by: 1, autoplay: isPlaying || position == 0) }
    public func previous() { advance(by: -1, autoplay: isPlaying || position == 0) }

    public func seek(toFraction fraction: Double) {
        let target = max(0, min(1, fraction)) * duration
        if isSimulated {
            position = target
            anchorPosition = target
            anchorDate = isPlaying ? .now : nil
        } else {
            position = target
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        }
        updateNowPlayingInfo()
    }

    public func isCurrent(track: Track) -> Bool {
        self.track?.id == track.id && (isPlaying || position > 0)
    }

    // MARK: Loading

    private func advance(by delta: Int, autoplay: Bool) {
        guard !queue.isEmpty else { return }
        load(index: (index + delta + queue.count) % queue.count, autoplay: autoplay)
    }

    /// The song played to its end: repeat it, move on, wrap around, or stop, depending on the repeat mode.
    private func trackEnded() {
        guard !queue.isEmpty else { return }
        switch repeatMode {
        case .one:
            load(index: index, autoplay: true)
        case .all:
            load(index: (index + 1) % queue.count, autoplay: true)
        case .off:
            if index + 1 < queue.count {
                load(index: index + 1, autoplay: true)
            } else {
                load(index: index, autoplay: false)
            }
        }
    }

    private func load(index: Int, autoplay: Bool) {
        teardown()
        self.index = index
        position = 0
        lastError = nil
        guard let track else { return }
        let resolved = albumProvider?(track)
        if resolved?.id != album?.id, let resolved { didStartAlbum?(resolved) }
        album = resolved
        if autoplay { didStartTrack?(track) }

        if let url = streamURLProvider?(track) {
            isSimulated = false
            configureAudioSession()
            let item = AVPlayerItem(url: url)
            let player = AVPlayer(playerItem: item)
            player.volume = volume
            player.automaticallyWaitsToMinimizeStalling = true
            self.player = player
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, !self.isSimulated else { return }
                    let seconds = time.seconds
                    self.position = seconds.isFinite ? max(0, seconds) : 0
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.trackEnded()
                }
            }
            statusObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if item.status == .failed {
                        self.lastError = item.error?.localizedDescription ?? "This track couldn't be played."
                        self.isPlaying = false
                    }
                    // The real duration is known once the item is ready; the lock screen wants it.
                    self.updateNowPlayingInfo()
                }
            }
            if autoplay {
                player.play()
                isPlaying = true
            } else {
                isPlaying = false
            }
        } else if allowsSimulation?() ?? true {
            isSimulated = true
            if autoplay {
                anchorPosition = 0
                anchorDate = .now
                isPlaying = true
                startTicker()
            } else {
                isPlaying = false
            }
        } else {
            // Offline and not downloaded: say so rather than pretending to play.
            isSimulated = false
            isPlaying = false
            lastError = "This song isn't on your iPhone and the server can't be reached."
        }
        refreshNowPlayingArtwork()
        updateNowPlayingInfo()
    }

    private func teardown() {
        stopTicker()
        anchorDate = nil
        if let player, let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
        if let endObserver {
            NotificationCenter.default.removeObserver(endObserver)
        }
        endObserver = nil
        statusObservation = nil
        player?.pause()
        player = nil
    }

    private func configureAudioSession() {
        #if !os(macOS)
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default)
        try? session.setActive(true)
        #endif
        setupRemoteCommands()
    }

    // MARK: Lock screen, Control Center and headphone controls

    /// Registers once for the system transport controls and for interruptions such as calls.
    private func setupRemoteCommands() {
        guard !remoteCommandsReady else { return }
        remoteCommandsReady = true
        let center = MPRemoteCommandCenter.shared()
        // The system may call these on any thread, so each one hops to the main actor before touching the player.
        func onMain(_ action: @escaping @MainActor (PlayerModel) -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.hasTrack else { return }
                    action(self)
                }
                return .success
            }
        }
        center.playCommand.addTarget(handler: onMain { $0.resume() })
        center.pauseCommand.addTarget(handler: onMain { $0.pause() })
        center.togglePlayPauseCommand.addTarget(handler: onMain { $0.togglePlayPause() })
        center.nextTrackCommand.addTarget(handler: onMain { $0.next() })
        center.previousTrackCommand.addTarget(handler: onMain { $0.previous() })
        center.changePlaybackPositionCommand.addTarget { [weak self] event in
            let seconds = (event as? MPChangePlaybackPositionCommandEvent)?.positionTime ?? 0
            Task { @MainActor in
                guard let self, self.hasTrack, self.duration > 0 else { return }
                self.seek(toFraction: seconds / self.duration)
            }
            return .success
        }
        center.skipForwardCommand.isEnabled = false
        center.skipBackwardCommand.isEnabled = false

        #if !os(macOS)
        let notifications = NotificationCenter.default
        interruptionObservers.append(notifications.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            // Read the plain values first; the notification itself must not cross into the actor.
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt).flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self, let type else { return }
                switch type {
                case .began:
                    self.wasPlayingBeforeInterruption = self.isPlaying
                    if self.isPlaying { self.pause() }
                case .ended:
                    if self.wasPlayingBeforeInterruption, options.contains(.shouldResume) { self.resume() }
                    self.wasPlayingBeforeInterruption = false
                @unknown default:
                    break
                }
            }
        })
        // Headphones unplugged: pause rather than blare from the speaker.
        interruptionObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        })
        #endif
    }

    /// What the lock screen and Control Center show: title, artist, artwork, duration and position.
    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let track else {
            center.nowPlayingInfo = nil
            return
        }
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: track.title,
            MPMediaItemPropertyArtist: album?.artist ?? track.artist ?? "",
            MPMediaItemPropertyAlbumTitle: album?.title ?? queueTitle ?? "",
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
        ]
        if let nowPlayingArtwork, artworkAlbumID == album?.id {
            info[MPMediaItemPropertyArtwork] = nowPlayingArtwork
        }
        center.nowPlayingInfo = info
    }

    /// Loads the album cover for the lock screen once per album.
    private func refreshNowPlayingArtwork() {
        guard let album else {
            nowPlayingArtwork = nil
            artworkAlbumID = nil
            return
        }
        guard artworkAlbumID != album.id else { return }
        nowPlayingArtwork = nil
        artworkAlbumID = album.id
        guard CoverStore.hasCover(for: album.id) else { return }
        let url = CoverStore.fileURL(for: album.id)
        let key = "\(album.id)|lockscreen"
        Task { [weak self] in
            guard let image = await CoverImageCache.shared.image(url: url, key: key, maxPixelSize: CoverImageCache.largePixels) else { return }
            guard let self, artworkAlbumID == album.id else { return }
            let size = CGSize(width: image.width, height: image.height)
            // Requested on a background thread by the system; only the CGImage crosses into the closure.
            nowPlayingArtwork = MPMediaItemArtwork(boundsSize: size) { @Sendable _ in
                #if canImport(UIKit)
                UIImage(cgImage: image)
                #else
                NSImage(cgImage: image, size: size)
                #endif
            }
            updateNowPlayingInfo()
        }
    }

    // MARK: Demo simulation

    private func startTicker() {
        stopTicker()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                tick()
            }
        }
    }

    private func stopTicker() {
        ticker?.cancel()
        ticker = nil
    }

    private func syncSimulatedPosition() {
        guard let anchorDate else { return }
        position = anchorPosition + Date.now.timeIntervalSince(anchorDate)
    }

    private func tick() {
        guard isPlaying, isSimulated else { return }
        syncSimulatedPosition()
        if position >= duration {
            trackEnded()
        }
    }
}
