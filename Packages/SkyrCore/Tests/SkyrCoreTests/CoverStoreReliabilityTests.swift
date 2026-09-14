import Foundation
import Testing
@testable import SkyrCore

@Suite struct CoverStoreReliabilityTests {
    @Test func clearAllowsImmediateArtworkAndMarkerWrites() throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-cover-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try CoverStore.$directoryOverride.withValue(directory) {
            CoverStore.save(Data([1, 2, 3]), for: "old")
            CoverStore.clear()
            #expect(!CoverStore.hasCover(for: "old"))
            #expect(FileManager.default.fileExists(atPath: directory.path))
            CoverStore.save(Data([4, 5, 6]), for: "new")
            CoverStore.noteMissingCover(for: "missing")
            CoverStore.saveTrackCover(Data([7, 8, 9]), for: "track")
            CoverStore.adoptTrackCover(from: "track", for: "adopted")
            let saved = try Data(contentsOf: CoverStore.fileURL(for: "new"))
            #expect(saved == Data([4, 5, 6]))
            #expect(CoverStore.missingCoverDate(for: "missing") != nil)
            #expect(CoverStore.hasTrackCover(for: "track"))
            #expect(CoverStore.hasCover(for: "adopted"))
        }
    }

    @Test func cancelledRunCannotMutateCoversFromDetachedWork() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-cover-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await CoverStore.$directoryOverride.withValue(directory) {
            CoverStore.save(Data([1]), for: "existing")
            let run = IndexingRun()
            run.cancel()
            await Task.detached {
                CoverStore.$directoryOverride.withValue(directory) {
                    CoverStore.$indexingRun.withValue(run) {
                        CoverStore.save(Data([2]), for: "new")
                        CoverStore.copy(from: "existing", to: "copy")
                        CoverStore.noteMissingCover(for: "missing")
                        CoverStore.saveTrackCover(Data([3]), for: "track")
                        CoverStore.remove(for: "existing")
                        CoverStore.clear()
                    }
                }
            }.value
            let saved = try Data(contentsOf: CoverStore.fileURL(for: "existing"))
            #expect(saved == Data([1]))
            #expect(!CoverStore.hasCover(for: "new"))
            #expect(!CoverStore.hasCover(for: "copy"))
            #expect(CoverStore.missingCoverDate(for: "missing") == nil)
            #expect(!CoverStore.hasTrackCover(for: "track"))
        }
    }

    @Test func concurrentArtworkWritesAfterClearAreRetained() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: "skyr-cover-test-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try await CoverStore.$directoryOverride.withValue(directory) {
            CoverStore.clear()
            _ = await parallelResults(Array(0..<24)) { index in
                CoverStore.$directoryOverride.withValue(directory) {
                    CoverStore.save(Data([UInt8(index)]), for: "album-\(index)")
                }
            }
            for index in 0..<24 {
                let saved = try Data(contentsOf: CoverStore.fileURL(for: "album-\(index)"))
                #expect(saved == Data([UInt8(index)]))
            }
        }
    }
}
