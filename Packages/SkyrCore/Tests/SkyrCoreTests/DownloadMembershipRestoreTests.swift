import Foundation
import Testing
@testable import SkyrCore

private func edited(_ base: ProfileState, time: TimeInterval, id: String, _ change: (inout ProfileState) -> Void) -> ProfileState {
    var result = base
    change(&result)
    result.recordChanges(from: base, at: Date(timeIntervalSince1970: time), operationID: id)
    return result
}

// MARK: - Download Membership in LibraryState

@Test func downloadMembershipStoredInLibraryState() {
    var state = LibraryState()
    state.downloadedAlbums = ["album-1", "album-2"]
    state.downloadedPlaylists = ["playlist-1"]
    
    #expect(state.downloadedAlbums == ["album-1", "album-2"])
    #expect(state.downloadedPlaylists == ["playlist-1"])
}

@Test func downloadMembershipEncodesAndDecodes() throws {
    var state = LibraryState()
    state.downloadedAlbums = ["album-1", "album-2"]
    state.downloadedPlaylists = ["playlist-1"]
    
    let encoder = JSONEncoder()
    let decoder = JSONDecoder()
    let data = try encoder.encode(state)
    let decoded = try decoder.decode(LibraryState.self, from: data)
    
    #expect(decoded.downloadedAlbums == ["album-1", "album-2"])
    #expect(decoded.downloadedPlaylists == ["playlist-1"])
}

@Test func downloadMembershipDefaultsToEmpty() throws {
    let json = #"{"favourites": ["song-1"]}"#
    let decoder = JSONDecoder()
    let state = try decoder.decode(LibraryState.self, from: Data(json.utf8))
    
    #expect(state.downloadedAlbums == [])
    #expect(state.downloadedPlaylists == [])
    #expect(state.favourites == ["song-1"])
}

// MARK: - Download Membership Merge via CloudKit Sync

@Test func downloadMembershipMergesFromMultipleDevices() {
    let base = ProfileState()
    
    let deviceA = edited(base, time: 10, id: "device-A") {
        $0.libraries["drive"] = LibraryState()
        $0.libraries["drive"]?.downloadedAlbums = ["album-1"]
        $0.libraries["drive"]?.downloadedPlaylists = ["playlist-1"]
    }
    
    let deviceB = edited(base, time: 20, id: "device-B") {
        $0.libraries["drive"] = LibraryState()
        $0.libraries["drive"]?.downloadedAlbums = ["album-2"]
        $0.libraries["drive"]?.downloadedPlaylists = ["playlist-2"]
    }
    
    let merged = deviceA.merged(with: deviceB)
    
    #expect(Set(merged.libraries["drive"]?.downloadedAlbums ?? []) == ["album-1", "album-2"])
    #expect(Set(merged.libraries["drive"]?.downloadedPlaylists ?? []) == ["playlist-1", "playlist-2"])
    #expect(merged == deviceB.merged(with: deviceA))
}

@Test func downloadMembershipRemovalSurvivesConcurrentEdits() {
    let base = edited(ProfileState(), time: 10, id: "base") {
        $0.libraries["drive"] = LibraryState()
        $0.libraries["drive"]?.downloadedAlbums = ["album-1", "album-2"]
    }
    
    let removed = edited(base, time: 20, id: "remove") {
        $0.libraries["drive"]?.downloadedAlbums = ["album-2"]
    }
    
    let unrelated = edited(base, time: 30, id: "unrelated") {
        $0.settings.shuffle = true
    }
    
    let merged = removed.merged(with: unrelated).merged(with: base)
    
    #expect(merged.libraries["drive"]?.downloadedAlbums == ["album-2"])
    #expect(merged.settings.shuffle)
}

@Test func downloadMembershipAdditionsFromDifferentDevicesAreCombined() {
    let base = edited(ProfileState(), time: 10, id: "base") {
        $0.libraries["drive"] = LibraryState()
        $0.libraries["drive"]?.downloadedAlbums = ["album-1"]
    }
    
    let deviceA = edited(base, time: 20, id: "A") {
        $0.libraries["drive"]?.downloadedAlbums.append("album-2")
    }
    
    let deviceB = edited(base, time: 21, id: "B") {
        $0.libraries["drive"]?.downloadedAlbums.append("album-3")
    }
    
    let merged = deviceA.merged(with: deviceB)
    
    #expect(Set(merged.libraries["drive"]?.downloadedAlbums ?? []) == ["album-1", "album-2", "album-3"])
    #expect(merged == deviceB.merged(with: deviceA))
}

// MARK: - Download Membership Recovery (Reinstall Scenario)

@Test func downloadMembershipRecoveryImportsMissingItems() {
    var state = ProfileState()
    state.updatedAt = Date(timeIntervalSince1970: 10)
    state.libraries["legacy-drive"] = LibraryState()
    state.libraries["legacy-drive"]?.downloadedAlbums = ["album-1", "album-2"]
    state.libraries["legacy-drive"]?.downloadedPlaylists = ["playlist-1"]
    
    let migrated = state.normalizedForSync()
    
    guard let recovered = migrated.recoveringLibrary(from: "legacy-drive", to: "new-drive") else {
        Issue.record("Recovery should succeed")
        return
    }
    
    #expect(recovered.libraries["new-drive"]?.downloadedAlbums == ["album-1", "album-2"])
    #expect(recovered.libraries["new-drive"]?.downloadedPlaylists == ["playlist-1"])
    #expect(recovered.hasRecoveredLibrary(from: "legacy-drive", to: "new-drive"))
}

@Test func downloadMembershipRecoveryPreservesExistingTargetItems() {
    var state = ProfileState()
    state.updatedAt = Date(timeIntervalSince1970: 10)
    state.libraries["legacy-drive"] = LibraryState()
    state.libraries["legacy-drive"]?.downloadedAlbums = ["album-1", "album-2"]
    state.libraries["new-drive"] = LibraryState()
    state.libraries["new-drive"]?.downloadedAlbums = ["album-3"]
    
    let migrated = state.normalizedForSync()
    
    let edited = ProfileStateMergeTests_edited(migrated, time: 20, id: "edit") {
        $0.libraries["new-drive"]?.downloadedAlbums = ["album-3"]
    }
    
    guard let recovered = edited.recoveringLibrary(from: "legacy-drive", to: "new-drive") else {
        Issue.record("Recovery should succeed")
        return
    }
    
    #expect(Set(recovered.libraries["new-drive"]?.downloadedAlbums ?? []) == ["album-1", "album-2", "album-3"])
}

private func ProfileStateMergeTests_edited(_ base: ProfileState, time: TimeInterval, id: String, _ change: (inout ProfileState) -> Void) -> ProfileState {
    var result = base
    change(&result)
    result.recordChanges(from: base, at: Date(timeIntervalSince1970: time), operationID: id)
    return result
}

// MARK: - Download Membership in ProfileStateEdit

@Test func downloadMembershipPatchAppliesCorrectly() {
    var library = LibraryState()
    library.downloadedAlbums = ["album-1"]
    library.downloadedPlaylists = []
    
    var newLibrary = library
    newLibrary.downloadedAlbums = ["album-1", "album-2"]
    newLibrary.downloadedPlaylists = ["playlist-1"]
    
    let patch = ProfileStateEdit.LibraryPatch(from: library, to: newLibrary, recordingHistory: nil)
    
    #expect(patch.downloadedAlbums == ["album-1", "album-2"])
    #expect(patch.downloadedPlaylists == ["playlist-1"])
    
    var applied = library
    patch.apply(to: &applied)
    
    #expect(applied.downloadedAlbums == ["album-1", "album-2"])
    #expect(applied.downloadedPlaylists == ["playlist-1"])
}

@Test func downloadMembershipPatchIsNilWhenUnchanged() {
    var library = LibraryState()
    library.downloadedAlbums = ["album-1"]
    library.downloadedPlaylists = ["playlist-1"]
    
    let patch = ProfileStateEdit.LibraryPatch(from: library, to: library, recordingHistory: nil)
    
    #expect(patch.downloadedAlbums == nil)
    #expect(patch.downloadedPlaylists == nil)
}

// MARK: - Download Membership Survives Reinstall via Cloud Sync

@Test func downloadMembershipSurvivesFullProfileStateRoundTrip() throws {
    var state = ProfileState()
    state.libraries["drive"] = LibraryState()
    state.libraries["drive"]?.downloadedAlbums = ["album-1", "album-2"]
    state.libraries["drive"]?.downloadedPlaylists = ["playlist-1"]
    state.libraries["drive"]?.favourites = ["song-1"]
    
    let normalized = state.normalizedForSync()
    
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(normalized)
    
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let decoded = try decoder.decode(ProfileState.self, from: data)
    
    #expect(decoded.libraries["drive"]?.downloadedAlbums == ["album-1", "album-2"])
    #expect(decoded.libraries["drive"]?.downloadedPlaylists == ["playlist-1"])
    #expect(decoded.libraries["drive"]?.favourites == ["song-1"])
}

@Test func downloadMembershipInCloudDocumentPreservesData() throws {
    var state = ProfileState()
    state.libraries["drive"] = LibraryState()
    state.libraries["drive"]?.downloadedAlbums = ["album-1", "album-2", "album-3"]
    state.libraries["drive"]?.downloadedPlaylists = ["playlist-1", "playlist-2"]
    
    let normalized = state.normalizedForSync()
    
    let bytes = try ProfileCloudDocument.encode(normalized)
    let decoded = try ProfileCloudDocument.decode(bytes)
    
    #expect(decoded.libraries["drive"]?.downloadedAlbums == ["album-1", "album-2", "album-3"])
    #expect(decoded.libraries["drive"]?.downloadedPlaylists == ["playlist-1", "playlist-2"])
}

// MARK: - Download Membership with Multiple Libraries

@Test func downloadMembershipIsPerLibraryIsolated() {
    let base = ProfileState()
    
    let state = edited(base, time: 10, id: "setup") {
        $0.libraries["drive-a"] = LibraryState()
        $0.libraries["drive-a"]?.downloadedAlbums = ["album-1"]
        $0.libraries["drive-b"] = LibraryState()
        $0.libraries["drive-b"]?.downloadedAlbums = ["album-2"]
    }
    
    #expect(state.libraries["drive-a"]?.downloadedAlbums == ["album-1"])
    #expect(state.libraries["drive-b"]?.downloadedAlbums == ["album-2"])
    
    let edited = ProfileStateMergeTests_edited(state, time: 20, id: "edit-a") {
        $0.libraries["drive-a"]?.downloadedAlbums = []
    }
    
    #expect(edited.libraries["drive-a"]?.downloadedAlbums == [])
    #expect(edited.libraries["drive-b"]?.downloadedAlbums == ["album-2"])
}
