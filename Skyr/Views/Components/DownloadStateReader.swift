import SkyrCore
import SwiftUI

/// Shows fresh offline status without filesystem work in the view body. A visible reader checks
/// again after foregrounding and periodically, so externally removed files are not cached forever.
struct DownloadStateReader<Content: View>: View {
    let owner: DownloadOwner
    @ViewBuilder let content: (DownloadState?) -> Content
    @Environment(DownloadManager.self) private var downloads
    @Environment(LibraryStore.self) private var library
    @Environment(\.scenePhase) private var scenePhase
    @State private var result: Result?

    private struct Request: Equatable {
        let owner: DownloadOwner
        let revision: UInt64
        let sourceID: String
        let profileID: String
        let contentRevision: Int
        let isReady: Bool
        let isActive: Bool
    }

    private struct Result {
        let request: Request
        let state: DownloadState
    }

    var body: some View {
        let request = Request(owner: owner, revision: downloads.stateRevision,
                              sourceID: library.catalogue.driveID, profileID: downloads.activeProfileID,
                              contentRevision: library.contentRevision,
                              isReady: library.contentSourceID == library.catalogue.driveID,
                              isActive: scenePhase == .active)
        // Keep progress visible while a newer revision is checked, but never carry it into another
        // profile, source, or collection. Playback and download actions still validate live inputs.
        let previous = result?.request
        let canDisplay = previous?.owner == request.owner && previous?.sourceID == request.sourceID
            && previous?.profileID == request.profileID && previous?.contentRevision == request.contentRevision
            && request.isReady
        content(canDisplay ? result?.state : nil)
            .task(id: request) {
                guard request.isReady, request.isActive else { return }
                do {
                    repeat {
                        let state = try await downloads.readState(for: request.owner)
                        try Task.checkCancellation()
                        guard library.contentRevision == request.contentRevision,
                              library.contentSourceID == request.sourceID,
                              library.catalogue.driveID == request.sourceID,
                              downloads.activeProfileID == request.profileID else { return }
                        result = Result(request: request, state: state)
                        // Byte callbacks can arrive faster than a large file scan. Sampling progress
                        // after each completed scan avoids cancellation starvation while downloading.
                        try await Task.sleep(for: state.isDownloading ? .milliseconds(250) : .seconds(5))
                    } while !Task.isCancelled
                } catch is CancellationError {
                    // The replacement task owns the current source, collection, and download state.
                } catch {
                    result = nil
                }
            }
    }
}
