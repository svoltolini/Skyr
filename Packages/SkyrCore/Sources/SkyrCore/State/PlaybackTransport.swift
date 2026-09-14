import AVFoundation
import Foundation

/// Keeps AVFoundation callbacks behind the same boundary used by deterministic playback tests.
protocol PlaybackTransport: AnyObject {
    var status: PlaybackTransportStatus { get }
    var duration: TimeInterval? { get }
    var volume: Float { get set }
    var statusChanged: (() -> Void)? { get set }
    var positionChanged: ((TimeInterval) -> Void)? { get set }
    var ended: (() -> Void)? { get set }
    func play()
    func pause()
    func seek(to seconds: TimeInterval, completion: @escaping @MainActor @Sendable (Bool) -> Void)
    func invalidate()
}

nonisolated enum PlaybackTransportStatus: Equatable, Sendable {
    case loading
    case ready
    case failed(String)
}

final class AVPlaybackTransport: PlaybackTransport {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private var timeObserver: Any?
    private var notifications: [any NSObjectProtocol] = []
    private var observations: [NSKeyValueObservation] = []
    private var playbackFailure: String?

    var statusChanged: (() -> Void)?
    var positionChanged: ((TimeInterval) -> Void)?
    var ended: (() -> Void)?

    var status: PlaybackTransportStatus {
        if let playbackFailure { return .failed(playbackFailure) }
        if item.status == .failed || player.status == .failed {
            return .failed(item.error?.localizedDescription ?? player.error?.localizedDescription ?? "This track couldn't be played.")
        }
        return item.status == .readyToPlay ? .ready : .loading
    }

    var duration: TimeInterval? {
        let seconds = item.duration.seconds
        return item.duration.isNumeric && seconds.isFinite && seconds > 0 ? seconds : nil
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    init(url: URL) {
        item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { [weak self] time in
            Task { @MainActor in self?.positionChanged?(time.seconds) }
        }
        observations = [
            item.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.statusChanged?() }
            },
            player.observe(\.status, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.statusChanged?() }
            },
        ]
        let center = NotificationCenter.default
        notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.ended?() }
        })
        notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: item, queue: .main) { [weak self] note in
            let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error)?.localizedDescription
            Task { @MainActor in
                guard let self else { return }
                self.playbackFailure = message ?? "This track couldn't be played."
                self.statusChanged?()
            }
        })
    }

    func play() { player.play() }
    func pause() { player.pause() }

    func seek(to seconds: TimeInterval, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        player.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { finished in
            Task { @MainActor in completion(finished) }
        }
    }

    func invalidate() {
        statusChanged = nil
        positionChanged = nil
        ended = nil
        player.pause()
        item.cancelPendingSeeks()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        observations.removeAll()
        notifications.forEach(NotificationCenter.default.removeObserver)
        notifications.removeAll()
    }
}
