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
    /// Original position of each queued occurrence. The same song may appear more than once.
    private var queueOrigins: [Int] = []
    public private(set) var index = 0
    /// Shared by app, widget and CarPlay requests so a late server response cannot replace newer intent.
    public private(set) var commandRevision = UUID()
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
        recordPlaybackCommand()
        teardown()
        queue = []
        orderedQueue = []
        queueOrigins = []
        index = 0
        album = nil
        queueTitle = nil
        isPlaying = false
        position = 0
        lastError = nil
        nowPlayingArtwork = nil
        artworkAlbumID = nil
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

    private var player: (any PlaybackTransport)?
    private let makePlayer: (URL) -> any PlaybackTransport
    private let publishNowPlaying: ([String: Any]?) -> Void
    private let usesSystemControls: Bool
    /// User intent survives item preparation, but pausing must prevent a late callback from starting audio.
    private var wantsToPlay = false
    private var playbackGeneration = UUID()
    private var seekGeneration = UUID()
    private var pendingStartPosition: TimeInterval?
    private var recoverySeekInFlight = false
    private var hasRecordedTrackStart = false
    private var ticker: Task<Void, Never>?
    private var anchorDate: Date?
    private var anchorPosition: TimeInterval = 0
    private var isSimulated = false
    private var remoteCommandsReady = false
    private var interruptionObservers: [any NSObjectProtocol] = []
    private var interruptionResumeRevision: UUID?
    private var nowPlayingArtwork: MPMediaItemArtwork?
    private var artworkAlbumID: String?

    public init() {
        makePlayer = { AVPlaybackTransport(url: $0) }
        publishNowPlaying = { MPNowPlayingInfoCenter.default().nowPlayingInfo = $0 }
        usesSystemControls = true
    }

    /// Exercises the actual command and recovery paths without audio output or shared system controls.
    init(makePlayer: @escaping (URL) -> any PlaybackTransport, publishNowPlaying: @escaping ([String: Any]?) -> Void) {
        self.makePlayer = makePlayer
        self.publishNowPlaying = publishNowPlaying
        usesSystemControls = false
    }

    public var track: Track? { queue.indices.contains(index) ? queue[index] : nil }
    public var hasTrack: Bool { track != nil }

    public var duration: TimeInterval {
        if let duration = player?.duration { return duration }
        return track?.duration ?? 0
    }

    public var progress: Double { duration > 0 ? min(1, position / duration) : 0 }
    public var remaining: TimeInterval { max(0, duration - position) }
    /// Colour of the playing album as the library has it now, so cover colours read later still apply.
    public var tint: Color { (track.flatMap { albumProvider?($0) } ?? album)?.primaryColor ?? Palette.neutralTint }

    // MARK: Commands

    /// Reserves a command before an asynchronous server wait; compare the returned revision before playing.
    @discardableResult
    public func beginDeferredPlaybackCommand() -> UUID {
        recordPlaybackCommand()
        return commandRevision
    }

    private func recordPlaybackCommand() {
        commandRevision = UUID()
        interruptionResumeRevision = nil
    }

    public func play(album: Album, startingAt index: Int = 0) {
        play(queue: album.tracks, startingAt: index, title: nil)
    }

    public func play(queue: [Track], startingAt index: Int = 0, title: String?) {
        recordPlaybackCommand()
        guard !queue.isEmpty else { return }
        orderedQueue = queue
        queueTitle = title
        let start = min(max(0, index), queue.count - 1)
        if isShuffling {
            queueOrigins = [start] + queue.indices.filter { $0 != start }.shuffled()
            self.queue = queueOrigins.map { queue[$0] }
            load(index: 0, autoplay: true)
        } else {
            queueOrigins = Array(queue.indices)
            self.queue = queue
            load(index: start, autoplay: true)
        }
    }

    /// Starts this occurrence in the existing queue without rebuilding or reshuffling that queue.
    public func playQueuedTrack(at index: Int) {
        guard queue.indices.contains(index) else { return }
        recordPlaybackCommand()
        load(index: index, autoplay: true)
    }

    /// Shuffles what comes after the current song, or restores the original order around it.
    public func toggleShuffle() {
        isShuffling.toggle()
        settingsChanged?(repeatMode, isShuffling)
        guard queueOrigins.indices.contains(index) else { return }
        let currentOrigin = queueOrigins[index]
        if isShuffling {
            queueOrigins = [currentOrigin] + queueOrigins.filter { $0 != currentOrigin }.shuffled()
            queue = queueOrigins.map { orderedQueue[$0] }
            index = 0
        } else if !orderedQueue.isEmpty {
            queue = orderedQueue
            queueOrigins = Array(orderedQueue.indices)
            index = currentOrigin
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
        wantsToPlay ? pause() : resume()
    }

    public func resume() {
        recordPlaybackCommand()
        resumePlayback()
    }

    private func resumePlayback() {
        guard hasTrack else { return }
        wantsToPlay = true
        if isSimulated {
            anchorPosition = position
            anchorDate = .now
            startTicker()
            isPlaying = true
            recordTrackStart()
        } else if let player, case .failed = player.status {
            load(index: index, autoplay: true, resumingAt: position, isRetry: true)
        } else if player == nil {
            // A reconnect or a completed download may now provide a URL. Resolve it again.
            load(index: index, autoplay: true, resumingAt: position, isRetry: true)
        } else {
            playWhenReady()
        }
        updateNowPlayingInfo()
    }

    public func pause() {
        recordPlaybackCommand()
        pausePlayback()
    }

    /// The interruption path uses this without discarding its conditional resume token.
    private func pausePlayback() {
        wantsToPlay = false
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

    public func next() {
        recordPlaybackCommand()
        advance(by: 1, autoplay: wantsToPlay || position == 0)
    }

    public func previous() {
        recordPlaybackCommand()
        advance(by: -1, autoplay: wantsToPlay || position == 0)
    }

    public func seek(toFraction fraction: Double) {
        recordPlaybackCommand()
        let target = max(0, min(1, fraction)) * duration
        if isSimulated {
            position = target
            anchorPosition = target
            anchorDate = isPlaying ? .now : nil
        } else {
            position = target
            seekGeneration = UUID()
            recoverySeekInFlight = false
            pendingStartPosition = target
            playWhenReady()
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

    private func load(index: Int, autoplay: Bool, resumingAt savedPosition: TimeInterval = 0, isRetry: Bool = false) {
        let alreadyRecordedStart = isRetry && hasRecordedTrackStart
        teardown()
        self.index = index
        position = savedPosition.isFinite ? max(0, savedPosition) : 0
        lastError = nil
        wantsToPlay = autoplay
        hasRecordedTrackStart = alreadyRecordedStart
        guard let track else { return }
        let resolved = albumProvider?(track)
        if resolved?.id != album?.id, let resolved { didStartAlbum?(resolved) }
        album = resolved
        // CarPlay and lock-screen Play must also work after the first URL lookup failed.
        if usesSystemControls { setupRemoteCommands() }

        if let url = streamURLProvider?(track) {
            isSimulated = false
            if usesSystemControls { configureAudioSession() }
            let player = makePlayer(url)
            player.volume = volume
            self.player = player
            pendingStartPosition = position > 0 ? position : nil
            let generation = playbackGeneration
            player.positionChanged = { [weak self] seconds in
                guard let self, playbackGeneration == generation,
                      self.player?.status == .ready,
                      pendingStartPosition == nil, !recoverySeekInFlight else { return }
                position = seconds.isFinite ? max(0, seconds) : 0
            }
            player.ended = { [weak self] in
                guard let self, playbackGeneration == generation, wantsToPlay else { return }
                trackEnded()
            }
            player.statusChanged = { [weak self] in
                guard let self, playbackGeneration == generation else { return }
                playWhenReady()
            }
            playWhenReady()
        } else if allowsSimulation?() ?? true {
            isSimulated = true
            if autoplay {
                anchorPosition = position
                anchorDate = .now
                isPlaying = true
                startTicker()
                recordTrackStart()
            } else {
                isPlaying = false
            }
        } else {
            // Offline and not downloaded: say so rather than pretending to play.
            isSimulated = false
            isPlaying = false
            wantsToPlay = false
            lastError = "This song isn't downloaded and the server can't be reached."
        }
        refreshNowPlayingArtwork()
        updateNowPlayingInfo()
    }

    private func teardown() {
        playbackGeneration = UUID()
        seekGeneration = UUID()
        wantsToPlay = false
        isPlaying = false
        isSimulated = false
        pendingStartPosition = nil
        recoverySeekInFlight = false
        if nowPlayingArtwork == nil { artworkAlbumID = nil }
        stopTicker()
        anchorDate = nil
        player?.invalidate()
        player = nil
    }

    /// A play request becomes playback only once the current item and any recovery seek are ready.
    private func playWhenReady() {
        guard let player else { return }
        switch player.status {
        case .loading:
            isPlaying = false
        case .failed(let message):
            wantsToPlay = false
            isPlaying = false
            lastError = message
            player.pause()
        case .ready:
            if let requestedPosition = pendingStartPosition, !recoverySeekInFlight {
                let target = player.duration.map { min(requestedPosition, $0) } ?? requestedPosition
                position = target
                recoverySeekInFlight = true
                isPlaying = false
                player.pause()
                let generation = playbackGeneration
                let seek = seekGeneration
                player.seek(to: target) { [weak self] finished in
                    guard let self, playbackGeneration == generation, seekGeneration == seek else { return }
                    recoverySeekInFlight = false
                    if finished {
                        pendingStartPosition = nil
                        playWhenReady()
                    } else {
                        wantsToPlay = false
                        isPlaying = false
                        lastError = "Playback couldn't return to this position. Try playing again."
                        updateNowPlayingInfo()
                    }
                }
            } else if !recoverySeekInFlight, wantsToPlay, !isPlaying {
                lastError = nil
                player.play()
                isPlaying = true
                recordTrackStart()
            }
        }
        updateNowPlayingInfo()
    }

    private func recordTrackStart() {
        guard !hasRecordedTrackStart, let track else { return }
        hasRecordedTrackStart = true
        didStartTrack?(track)
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

    /// System interruption handling is separate from explicit Pause, which cancels an automatic resume.
    func interruptionBegan() {
        let shouldResume = wantsToPlay
        recordPlaybackCommand()
        interruptionResumeRevision = shouldResume ? commandRevision : nil
        pausePlayback()
    }

    func interruptionEnded(shouldResume: Bool) {
        let interruptedCommand = interruptionResumeRevision
        interruptionResumeRevision = nil
        guard shouldResume, interruptedCommand == commandRevision else { return }
        resumePlayback()
    }

    func outputDeviceRemoved() {
        // This must cancel a pending interruption resume even while the transport is already paused.
        pause()
    }

    /// Registers once for the system transport controls and for interruptions such as calls.
    private func setupRemoteCommands() {
        guard !remoteCommandsReady else { return }
        remoteCommandsReady = true
        let center = MPRemoteCommandCenter.shared()
        // The system may call these on any thread, so each one hops to the main actor before touching the player.
        func onMain(_ action: @escaping @MainActor (PlayerModel) -> Void) -> @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus {
            { [weak self] _ in
                Task { @MainActor in
                    // Pause also cancels deferred widget/CarPlay starts before a track exists.
                    guard let self else { return }
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
                    self.interruptionBegan()
                case .ended:
                    self.interruptionEnded(shouldResume: options.contains(.shouldResume))
                @unknown default:
                    break
                }
            }
        })
        // Headphones unplugged: pause rather than blare from the speaker.
        interruptionObservers.append(notifications.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt).flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, reason == .oldDeviceUnavailable else { return }
                self.outputDeviceRemoved()
            }
        })
        #endif
    }

    /// What the lock screen and Control Center show: title, artist, artwork, duration and position.
    private func updateNowPlayingInfo() {
        guard let track else {
            publishNowPlaying(nil)
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
        publishNowPlaying(info)
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
        let generation = playbackGeneration
        Task { [weak self] in
            guard let image = await CoverImageCache.shared.image(url: url, key: key, maxPixelSize: CoverImageCache.largePixels) else { return }
            guard let self, playbackGeneration == generation, artworkAlbumID == album.id else { return }
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
