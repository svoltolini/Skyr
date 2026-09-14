import Foundation
import Testing
@testable import SkyrCore

@Test @MainActor func profileHistoryPersistencePerformanceSamples() async throws {
    for count in [5_000, 15_000] {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-profile-performance-\(UUID().uuidString)")
        let suite = "skyr.profile.performance.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let profiles = ProfileStore(directory: directory, defaults: defaults)
        #expect(profiles.activate(try #require(profiles.owner)))
        profiles.updateLibrary("performance") {
            $0.playlists = [.init(id: "all", name: "All songs", trackIDs: (0..<count).map { "/Music/Artist/Album/Track-\($0).m4a" }, created: Date(timeIntervalSince1970: 1))]
        }
        var samples: [Double] = []
        for index in 0..<20 {
            let start = ContinuousClock.now
            profiles.updateLibrary("performance", recordingHistory: .played) { $0.played = ["play-\(index)"] }
            let duration = start.duration(to: .now).components
            samples.append(Double(duration.seconds) * 1_000 + Double(duration.attoseconds) / 1e15)
        }
        samples.sort()
        print("PROFILE_PERSISTENCE songs=\(count) samples=\(samples.count) median_ms=\(samples[samples.count / 2]) p95_ms=\(samples[18]) max_ms=\(samples.last!)")
        profiles.lock()
        await profiles.drainPersistence()
        defaults.removePersistentDomain(forName: suite)
        try FileManager.default.removeItem(at: directory)
    }
}
