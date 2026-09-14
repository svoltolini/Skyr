import Foundation
import MediaPlayer
import Testing
@testable import SkyrCore

@Suite struct PlaybackRecoveryTests {
    @Test(arguments: PlaybackCommand.allCases)
    func explicitPlaybackCommandsSupersedeDeferredRequests(_ command: PlaybackCommand) {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first"), track("second")], title: nil)
        let pending = fixture.model.beginDeferredPlaybackCommand()
        switch command {
        case .play: fixture.model.play(queue: [track("new")], title: nil)
        case .pause: fixture.model.pause()
        case .resume: fixture.model.resume()
        case .next: fixture.model.next()
        case .previous: fixture.model.previous()
        case .queueJump: fixture.model.playQueuedTrack(at: 1)
        case .seek: fixture.model.seek(toFraction: 0.5)
        case .stop: fixture.model.stop()
        }
        #expect(fixture.model.commandRevision != pending)
    }

    @Test(arguments: [0, 2, 4])
    func shuffleKeepsEveryDuplicateAndRestoresTheCurrentOccurrence(_ startingAt: Int) {
        let fixture = PlaybackFixture(status: .ready)
        let repeated = track("repeat")
        let original = [repeated, track("second"), repeated, track("fourth"), repeated]
        fixture.model.repeatMode = .all
        fixture.model.play(queue: original, startingAt: startingAt, title: "Duplicates")
        fixture.transports[0].positionChanged?(37)
        for _ in 0..<3 {
            fixture.model.toggleShuffle()
            #expect(fixture.model.queue.count == original.count)
            #expect(fixture.model.queue.filter { $0.id == "repeat" }.count == 3)
            #expect(fixture.model.queue.map(\.id).sorted() == original.map(\.id).sorted())
            #expect(fixture.model.index == 0)
            #expect(fixture.model.track == repeated)
            fixture.model.toggleShuffle()
            #expect(fixture.model.queue == original)
            #expect(fixture.model.index == startingAt)
            #expect(fixture.model.position == 37)
            #expect(fixture.model.isPlaying)
            #expect(fixture.model.repeatMode == .all)
            #expect(fixture.model.queueTitle == "Duplicates")
            #expect(fixture.transports.count == 1)
        }
    }

    @Test func initiallyShuffledQueueRestoresTheRequestedDuplicateOccurrence() {
        let fixture = PlaybackFixture(status: .ready)
        let repeated = track("repeat")
        let original = [repeated, track("middle"), repeated, repeated]
        fixture.model.applySettings(repeatMode: .one, shuffle: true)
        fixture.model.play(queue: original, startingAt: 2, title: "Duplicates")
        #expect(fixture.model.queue.count == 4)
        #expect(fixture.model.queue.filter { $0.id == "repeat" }.count == 3)
        #expect(fixture.model.index == 0)
        fixture.model.toggleShuffle()
        #expect(fixture.model.queue == original)
        #expect(fixture.model.index == 2)
        #expect(fixture.model.repeatMode == .one)
        #expect(fixture.transports.count == 1)
    }

    @Test func queueJumpPreservesShuffledOrderAndTheSelectedDuplicateOccurrence() throws {
        let fixture = PlaybackFixture(status: .ready)
        // Equal file IDs may also carry different metadata snapshots. Keep the selected occurrence.
        let original = (0..<5).map { position in
            var value = track(position.isMultiple(of: 2) ? "repeat" : "other-\(position)")
            value.title = "Occurrence \(position)"
            return value
        }
        fixture.model.play(queue: original, startingAt: 2, title: "Original order")
        fixture.model.repeatMode = .one
        fixture.model.toggleShuffle()
        let shuffled = fixture.model.queue
        let selected = try #require(shuffled.firstIndex { $0.title == "Occurrence 4" })
        fixture.transports[0].positionChanged?(48)
        fixture.model.pause()
        let pending = fixture.model.beginDeferredPlaybackCommand()
        fixture.model.playQueuedTrack(at: selected)
        #expect(fixture.model.commandRevision != pending)
        #expect(fixture.model.queue == shuffled)
        #expect(fixture.model.index == selected)
        #expect(fixture.model.track?.title == "Occurrence 4")
        #expect(fixture.model.position == 0)
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.isShuffling)
        #expect(fixture.model.repeatMode == .one)
        #expect(fixture.model.queueTitle == "Original order")
        #expect(fixture.transports.count == 2)
        #expect(fixture.transports[0].invalidated)
        #expect(fixture.transports[1].playCount == 1)
        fixture.model.toggleShuffle()
        #expect(fixture.model.queue == original)
        #expect(fixture.model.index == 4)
        #expect(fixture.model.track?.title == "Occurrence 4")
        #expect(fixture.transports.count == 2)
    }

    @Test func invalidQueueJumpLeavesPlaybackAndDeferredCommandsUnchanged() {
        let fixture = PlaybackFixture(status: .ready)
        var pending = fixture.model.beginDeferredPlaybackCommand()
        fixture.model.playQueuedTrack(at: 0)
        #expect(fixture.model.commandRevision == pending)
        #expect(fixture.transports.isEmpty)
        fixture.model.play(queue: [track("first"), track("second")], title: "Queue")
        fixture.transports[0].positionChanged?(23)
        fixture.model.pause()
        pending = fixture.model.beginDeferredPlaybackCommand()
        let original = fixture.model.queue
        for invalidIndex in [Int.min, -1, original.count, Int.max] {
            fixture.model.playQueuedTrack(at: invalidIndex)
            #expect(fixture.model.commandRevision == pending)
            #expect(fixture.model.queue == original)
            #expect(fixture.model.index == 0)
            #expect(fixture.model.position == 23)
            #expect(!fixture.model.isPlaying)
            #expect(fixture.transports.count == 1)
        }
    }

    @Test func queueJumpInvalidatesPendingRecoveryCallbacks() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first"), track("second")], title: "Queue")
        fixture.transports[0].positionChanged?(40)
        fixture.transports[0].status = .failed("Connection lost")
        fixture.model.resume()
        let recovery = fixture.transports[1]
        let latePosition = recovery.positionChanged
        let lateStatus = recovery.statusChanged
        let lateEnd = recovery.ended
        fixture.model.playQueuedTrack(at: 1)
        latePosition?(99)
        recovery.status = .failed("Old failure")
        lateStatus?()
        lateEnd?()
        recovery.seeks[0].completion(false)
        #expect(fixture.model.index == 1)
        #expect(fixture.model.track?.id == "second")
        #expect(fixture.model.position == 0)
        #expect(fixture.model.lastError == nil)
        #expect(fixture.model.isPlaying)
        #expect(fixture.transports.count == 3)
        #expect(recovery.invalidated)
        #expect(recovery.playCount == 0)
    }

    @Test func queueJumpDuringInterruptionCancelsOldResumeAfterNewItemFails() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first"), track("second")], title: nil)
        fixture.model.interruptionBegan()
        fixture.nextStatus = .failed("Second song unavailable")
        fixture.model.playQueuedTrack(at: 1)
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(fixture.model.index == 1)
        #expect(fixture.transports.count == 2)
        #expect(fixture.transports[1].playCount == 0)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.lastError == "Second song unavailable")
    }

    @Test func pauseWithoutATrackCancelsDeferredPlayback() {
        let fixture = PlaybackFixture()
        let pending = fixture.model.beginDeferredPlaybackCommand()
        fixture.model.pause()
        #expect(fixture.model.commandRevision != pending)
        #expect(!fixture.model.hasTrack)
        #expect(!fixture.model.isPlaying)
    }

    @Test func newestDeferredRequestSupersedesEarlierWidgetOrCarPlayWaits() {
        let fixture = PlaybackFixture()
        let carPlayRequest = fixture.model.beginDeferredPlaybackCommand()
        let widgetRequest = fixture.model.beginDeferredPlaybackCommand()
        #expect(fixture.model.commandRevision != carPlayRequest)
        #expect(fixture.model.commandRevision == widgetRequest)
        let newerCarPlayRequest = fixture.model.beginDeferredPlaybackCommand()
        #expect(fixture.model.commandRevision != widgetRequest)
        #expect(fixture.model.commandRevision == newerCarPlayRequest)
    }

    @Test func playbackPreparationAndPositionCallbacksDoNotSupersedeUserCommands() {
        let fixture = PlaybackFixture()
        fixture.model.play(queue: [track("first")], title: nil)
        let pending = fixture.model.beginDeferredPlaybackCommand()
        fixture.transports[0].status = .ready
        fixture.transports[0].positionChanged?(12)
        #expect(fixture.model.commandRevision == pending)
        #expect(fixture.model.isPlaying)
    }

    @Test func explicitPauseDuringInterruptionCancelsAutomaticResume() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.model.interruptionBegan()
        let interrupted = fixture.model.commandRevision
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        fixture.model.pause()
        #expect(fixture.model.commandRevision != interrupted)
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        #expect(fixture.transports[0].playCount == 1)
    }

    @Test func headphonesRemovedDuringInterruptionCancelAutomaticResume() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.model.interruptionBegan()
        let interrupted = fixture.model.commandRevision
        fixture.model.outputDeviceRemoved()
        #expect(fixture.model.commandRevision != interrupted)
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        #expect(fixture.transports[0].playCount == 1)
    }

    @Test func ordinaryInterruptionResumesOnceWhenNoNewCommandArrives() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.transports[0].positionChanged?(20)
        fixture.model.interruptionBegan()
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.position == 20)
        #expect(fixture.transports.count == 1)
        #expect(fixture.transports[0].playCount == 2)
        fixture.model.pause()
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.transports[0].playCount == 2)
    }

    @Test func interruptionDuringPreparationWaitsForEndAndHonorsLaterPause() {
        let fixture = PlaybackFixture()
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.model.interruptionBegan()
        fixture.transports[0].status = .ready
        #expect(!fixture.model.isPlaying)
        #expect(fixture.transports[0].playCount == 0)
        fixture.model.pause()
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.transports[0].playCount == 0)
        fixture.model.resume()
        #expect(fixture.model.isPlaying)
    }

    @Test func interruptionCancelsADeferredStartAndDeniedResumeCannotBeReplayed() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        let pending = fixture.model.beginDeferredPlaybackCommand()
        fixture.model.interruptionBegan()
        #expect(fixture.model.commandRevision != pending)
        fixture.model.interruptionEnded(shouldResume: false)
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.transports[0].playCount == 1)
    }

    @Test func deferredSelectionDuringInterruptionCancelsTheOldAutomaticResume() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.model.interruptionBegan()
        let pending = fixture.model.beginDeferredPlaybackCommand()
        fixture.model.interruptionEnded(shouldResume: true)
        #expect(fixture.model.commandRevision == pending)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.transports[0].playCount == 1)
    }

    @Test func missingSourceNeverReportsPlayingAndPlayResolvesAgain() {
        let fixture = PlaybackFixture()
        var source: URL?
        var lookups = 0
        fixture.model.streamURLProvider = { _ in lookups += 1; return source }
        fixture.model.play(queue: [track("first")], title: "Queue")
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        #expect(fixture.model.lastError != nil)
        fixture.model.resume()
        #expect(lookups == 2)
        #expect(fixture.transports.isEmpty)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)

        source = URL(filePath: "/fixture/downloaded.m4a")
        fixture.model.resume()
        #expect(lookups == 3)
        #expect(fixture.urls == [source!])
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        fixture.transports[0].status = .ready
        #expect(fixture.model.isPlaying)
        #expect(fixture.rate == 1)
        #expect(fixture.model.lastError == nil)
    }

    @Test func healthyPauseResumeKeepsTransportAndElapsedPosition() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        let transport = fixture.transports[0]
        transport.positionChanged?(42)
        fixture.model.pause()
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        fixture.model.resume()
        #expect(fixture.transports.count == 1)
        #expect(fixture.model.position == 42)
        #expect(transport.seeks.isEmpty)
        #expect(transport.playCount == 2)
        #expect(fixture.model.isPlaying)
        #expect(fixture.rate == 1)
        #expect(fixture.startedTrackIDs == ["first"])
    }

    @Test func failedItemRefreshesURLAndSeeksBeforeRestarting() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.repeatMode = .all
        fixture.model.play(queue: [track("first"), track("second")], startingAt: 1, title: "Favorites")
        fixture.model.toggleShuffle()
        let queue = fixture.model.queue
        let first = fixture.transports[0]
        first.positionChanged?(42)
        first.status = .failed("Connection lost")
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        #expect(fixture.model.lastError == "Connection lost")
        fixture.nextStatus = .loading
        fixture.model.streamURLProvider = { _ in URL(filePath: "/fixture/refreshed.m4a") }
        fixture.model.resume()
        let replacement = fixture.transports[1]
        #expect(first.invalidated)
        #expect(fixture.urls.last?.lastPathComponent == "refreshed.m4a")
        #expect(fixture.model.queue == queue)
        #expect(fixture.model.track?.id == "second")
        #expect(fixture.model.queueTitle == "Favorites")
        #expect(fixture.model.repeatMode == .all)
        #expect(fixture.model.isShuffling)
        replacement.positionChanged?(0)
        #expect(fixture.model.position == 42)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        replacement.status = .ready
        #expect(replacement.seeks.map(\.seconds) == [42])
        #expect(replacement.playCount == 0)
        replacement.seeks[0].completion(true)
        #expect(fixture.model.isPlaying)
        #expect(fixture.rate == 1)
        #expect(fixture.model.position == 42)
        #expect(fixture.model.lastError == nil)
        #expect(fixture.startedTrackIDs == ["second"])
    }

    @Test func failedItemWithMissingReplacementStaysStoppedUntilAURLReturns() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.transports[0].positionChanged?(35)
        fixture.transports[0].status = .failed("Expired source")
        fixture.model.streamURLProvider = { _ in nil }
        fixture.model.resume()
        #expect(fixture.transports.count == 1)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.position == 35)
        #expect(fixture.rate == 0)
        fixture.model.resume()
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.position == 35)
        fixture.model.streamURLProvider = { _ in URL(filePath: "/fixture/restored.m4a") }
        fixture.model.resume()
        let replacement = fixture.transports[1]
        #expect(replacement.seeks.map(\.seconds) == [35])
        #expect(replacement.playCount == 0)
        replacement.seeks[0].completion(true)
        #expect(fixture.model.isPlaying)
    }

    @Test func pauseDuringPreparationPreventsLateAutoplayAndRepeatedPlayDoesNotReload() {
        let fixture = PlaybackFixture()
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.model.resume()
        fixture.model.resume()
        #expect(fixture.transports.count == 1)
        fixture.model.togglePlayPause()
        let transport = fixture.transports[0]
        transport.status = .ready
        #expect(transport.playCount == 0)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        fixture.model.togglePlayPause()
        #expect(transport.playCount == 1)
        #expect(fixture.model.isPlaying)
    }

    @Test func pauseDuringRecoverySeekPreventsLateAutoplay() {
        let fixture = preparedRecovery()
        let replacement = fixture.transports[1]
        fixture.model.pause()
        replacement.seeks[0].completion(true)
        #expect(!fixture.model.isPlaying)
        #expect(replacement.playCount == 0)
        #expect(fixture.rate == 0)
        fixture.model.resume()
        #expect(fixture.transports.count == 2)
        #expect(replacement.playCount == 1)
        #expect(fixture.model.position == 40)
    }

    @Test func stopForProfileSwitchRejectsPendingCallbacksAndRecoverySeek() {
        let fixture = preparedRecovery()
        let replacement = fixture.transports[1]
        let latePosition = replacement.positionChanged
        let lateStatus = replacement.statusChanged
        let lateEnd = replacement.ended
        fixture.model.stop()
        latePosition?(98)
        lateStatus?()
        lateEnd?()
        replacement.seeks[0].completion(true)
        fixture.model.resume()
        #expect(replacement.invalidated)
        #expect(replacement.playCount == 0)
        #expect(fixture.model.queue.isEmpty)
        #expect(!fixture.model.hasTrack)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.position == 0)
        #expect(fixture.model.lastError == nil)
        #expect(fixture.nowPlaying == nil)
    }

    @Test func replacementTrackRejectsAllOldCallbacksIncludingFailedSeek() {
        let fixture = preparedRecovery()
        let old = fixture.transports[1]
        let latePosition = old.positionChanged
        let lateStatus = old.statusChanged
        let lateEnd = old.ended
        fixture.model.play(queue: [track("new"), track("after")], title: "New profile")
        latePosition?(99)
        old.status = .failed("Old failure")
        lateStatus?()
        lateEnd?()
        old.seeks[0].completion(false)
        #expect(fixture.model.track?.id == "new")
        #expect(fixture.model.position == 0)
        #expect(fixture.model.lastError == nil)
        #expect(fixture.model.isPlaying)
        #expect(fixture.rate == 1)
        #expect(fixture.nowPlaying?[MPMediaItemPropertyTitle] as? String == "new")
        #expect(old.playCount == 0)
    }

    @Test func failedRecoverySeekStaysPausedAndCanBeRetried() {
        let fixture = preparedRecovery()
        let replacement = fixture.transports[1]
        replacement.seeks[0].completion(false)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        #expect(fixture.model.lastError != nil)
        #expect(replacement.playCount == 0)
        fixture.model.resume()
        #expect(fixture.transports.count == 2)
        #expect(replacement.seeks.map(\.seconds) == [40, 40])
        replacement.seeks[1].completion(true)
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.lastError == nil)
    }

    @Test func newerSeekSupersedesRecoverySeekCompletion() {
        let fixture = preparedRecovery()
        let replacement = fixture.transports[1]
        fixture.model.seek(toFraction: 0.75)
        #expect(replacement.seeks.map(\.seconds) == [40, 90])
        replacement.seeks[0].completion(true)
        #expect(!fixture.model.isPlaying)
        #expect(replacement.playCount == 0)
        #expect(fixture.model.position == 90)
        replacement.seeks[1].completion(true)
        #expect(fixture.model.isPlaying)
        #expect(replacement.playCount == 1)
    }

    @Test func itemFailureDuringSeekCannotRestartPlaybackOnCompletion() {
        let fixture = preparedRecovery()
        let replacement = fixture.transports[1]
        replacement.status = .failed("Disconnected again")
        replacement.seeks[0].completion(true)
        #expect(!fixture.model.isPlaying)
        #expect(fixture.rate == 0)
        #expect(fixture.model.lastError == "Disconnected again")
        #expect(replacement.playCount == 0)
    }

    @Test func recoveryPositionClampsToReplacementDuration() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.transports[0].positionChanged?(180)
        fixture.transports[0].status = .failed("Connection lost")
        fixture.model.resume()
        #expect(fixture.transports[1].seeks.map(\.seconds) == [120])
        #expect(fixture.model.position == 120)
    }

    @Test func samplePlaybackStillPausesAndResumesWithoutResolvingAgain() {
        let fixture = PlaybackFixture()
        var resolutions = 0
        fixture.model.allowsSimulation = { true }
        fixture.model.streamURLProvider = { _ in resolutions += 1; return nil }
        fixture.model.play(queue: [track("sample")], title: nil)
        #expect(fixture.model.isPlaying)
        fixture.model.seek(toFraction: 0.25)
        fixture.model.pause()
        #expect(!fixture.model.isPlaying)
        fixture.model.resume()
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.position >= 30)
        #expect(resolutions == 1)
        #expect(fixture.transports.isEmpty)
        fixture.model.stop()
    }

    @Test(arguments: PlayerModel.RepeatMode.allCases)
    func naturalCompletionHonorsRepeatModeAtTheEndOfTheQueue(_ repeatMode: PlayerModel.RepeatMode) {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.repeatMode = repeatMode
        let queue = [track("first"), track("last")]
        fixture.model.play(queue: queue, startingAt: 1, title: "Queue")
        fixture.transports[0].ended?()
        #expect(fixture.model.queue == queue)
        #expect(fixture.model.index == (repeatMode == .all ? 0 : 1))
        #expect(fixture.model.isPlaying == (repeatMode != .off))
        #expect(fixture.transports.count == 2)
        #expect(fixture.transports[0].invalidated)
        #expect(fixture.transports[1].playCount == (repeatMode == .off ? 0 : 1))
    }

    @Test func manualSkipStillAdvancesWhenRepeatingOneSong() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.repeatMode = .one
        fixture.model.play(queue: [track("first"), track("second")], title: nil)
        fixture.model.next()
        #expect(fixture.model.track?.id == "second")
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.repeatMode == .one)
        fixture.transports[1].ended?()
        #expect(fixture.model.track?.id == "second")
        #expect(fixture.transports.count == 3)
    }

    @Test func failedNextItemStopsAndRetriesTheSelectedItemWithoutReplayingOldCompletion() {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first"), track("second")], title: "Queue")
        let oldCompletion = fixture.transports[0].ended
        fixture.nextStatus = .failed("Next song unavailable")
        oldCompletion?()
        #expect(fixture.model.track?.id == "second")
        #expect(!fixture.model.isPlaying)
        #expect(fixture.model.lastError == "Next song unavailable")
        #expect(fixture.startedTrackIDs == ["first"])
        oldCompletion?()
        #expect(fixture.transports.count == 2)
        fixture.nextStatus = .ready
        fixture.model.resume()
        #expect(fixture.model.track?.id == "second")
        #expect(fixture.model.isPlaying)
        #expect(fixture.model.lastError == nil)
        #expect(fixture.startedTrackIDs == ["first", "second"])
        #expect(fixture.transports.count == 3)
    }

    private func preparedRecovery() -> PlaybackFixture {
        let fixture = PlaybackFixture(status: .ready)
        fixture.model.play(queue: [track("first")], title: nil)
        fixture.transports[0].positionChanged?(40)
        fixture.transports[0].status = .failed("Connection lost")
        fixture.model.resume()
        return fixture
    }

    private func track(_ id: String) -> Track {
        Track(id: id, albumID: "album", title: id, index: 0, number: 1, disc: 1,
              duration: 120, codec: "m4a", path: "/\(id).m4a", format: "AAC", isEnriched: false)
    }
}

nonisolated enum PlaybackCommand: CaseIterable, Sendable {
    case play, pause, resume, next, previous, queueJump, seek, stop
}

private final class PlaybackFixture {
    var transports: [FakePlaybackTransport] = []
    var urls: [URL] = []
    var nowPlaying: [String: Any]?
    var startedTrackIDs: [String] = []
    var nextStatus: PlaybackTransportStatus
    var rate: Double? { nowPlaying?[MPNowPlayingInfoPropertyPlaybackRate] as? Double }

    lazy var model: PlayerModel = {
        let model = PlayerModel(makePlayer: { [unowned self] url in
            let transport = FakePlaybackTransport(status: nextStatus)
            urls.append(url)
            transports.append(transport)
            return transport
        }, publishNowPlaying: { [unowned self] in nowPlaying = $0 })
        model.allowsSimulation = { false }
        model.streamURLProvider = { _ in URL(filePath: "/fixture/source.m4a") }
        model.didStartTrack = { [unowned self] in startedTrackIDs.append($0.id) }
        return model
    }()

    init(status: PlaybackTransportStatus = .loading) { nextStatus = status }
}

private final class FakePlaybackTransport: PlaybackTransport {
    var status: PlaybackTransportStatus { didSet { statusChanged?() } }
    var duration: TimeInterval? = 120
    var volume: Float = 1
    var statusChanged: (() -> Void)?
    var positionChanged: ((TimeInterval) -> Void)?
    var ended: (() -> Void)?
    var playCount = 0
    var invalidated = false
    var seeks: [(seconds: TimeInterval, completion: @MainActor @Sendable (Bool) -> Void)] = []

    init(status: PlaybackTransportStatus) { self.status = status }
    func play() { playCount += 1 }
    func pause() {}
    func seek(to seconds: TimeInterval, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        seeks.append((seconds, completion))
    }
    func invalidate() {
        invalidated = true
        statusChanged = nil
        positionChanged = nil
        ended = nil
    }
}

// Real transports share AVFoundation's host media service; fake transport tests remain parallel.
// Give service callbacks a bounded integration-test budget even when other MainActor tests are busy.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AVPlaybackTransportTests {
    @Test func localInvalidAudioReportsFailureWithoutPlaying() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "skyr-invalid-audio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("This is not audio".utf8).write(to: url)
        let transport = AVPlaybackTransport(url: url)
        defer { transport.invalidate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while transport.status == .loading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard case .failed = transport.status else {
            Issue.record("Invalid local audio did not report failure: \(transport.status)")
            return
        }
    }

    @Test func localAudioBecomesReadyAndCompletesRecoverySeekWithoutPlaying() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "skyr-valid-audio-\(UUID()).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        // One second of mono PCM silence is sufficient to exercise AVFoundation's real loading and seek callbacks.
        var audio = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            var littleEndian = value.littleEndian
            withUnsafeBytes(of: &littleEndian) { audio.append(contentsOf: $0) }
        }
        append(UInt32(36 + 16_000))
        audio.append(Data("WAVEfmt ".utf8))
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(8_000))
        append(UInt32(16_000))
        append(UInt16(2))
        append(UInt16(16))
        audio.append(Data("data".utf8))
        append(UInt32(16_000))
        audio.append(Data(repeating: 0, count: 16_000))
        try audio.write(to: url)
        let transport = AVPlaybackTransport(url: url)
        defer { transport.invalidate() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(15))
        while transport.status == .loading, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(transport.status == .ready)
        #expect(abs((transport.duration ?? 0) - 1) < 0.01)
        var finished: Bool?
        transport.seek(to: 0.5) { finished = $0 }
        let seekDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while finished == nil, ContinuousClock.now < seekDeadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(finished == true)
    }

}
