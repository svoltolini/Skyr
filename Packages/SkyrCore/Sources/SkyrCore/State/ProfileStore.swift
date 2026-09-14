import Foundation
import ImageIO
import UniformTypeIdentifiers
#if canImport(LocalAuthentication) && !os(tvOS) && !os(watchOS)
import LocalAuthentication
#endif

/// The people who use this app, which one is in front, and that person's saved data. Profiles and
/// their state documents live under Application Support/Skyr/profiles; the store hands the active
/// profile's data to the library, player and settings and writes changes back a moment later.
@Observable
public final class ProfileStore {
    public private(set) var profiles: [Profile] = []
    /// The profile in use; nil while "Who's listening?" is up.
    public private(set) var activeID: String?
    /// The active profile's document.
    public private(set) var state = ProfileState()
    /// The profile that was open last, highlighted in the picker.
    public private(set) var lastActiveID: String?

    /// Set by the app: load this profile's data into the stores.
    public var onActivate: ((Profile) -> Void)?
    /// Set by the app: stop playback before another profile takes over.
    public var onDeactivate: (() -> Void)?
    /// Set by the app: the active profile's document changed on another device; reload it.
    public var onRemoteState: (() -> Void)?
    /// Keeps these files in step with iCloud when there is an account.
    public var sync: CloudSync?

    private var saveTask: Task<Void, Never>?
    private var isApplyingRemote = false

    public var active: Profile? { profiles.first { $0.id == activeID } }
    public var isLocked: Bool { activeID == nil }
    public var owner: Profile? { profiles.first { $0.role == .owner } ?? profiles.first }
    public var canAddProfile: Bool { profiles.count < Profile.limit }

    public init() {
        profiles = Self.loadProfiles()
        if profiles.isEmpty {
            profiles = [Self.migrateLegacyData()]
            saveProfiles()
        }
        lastActiveID = UserDefaults.standard.string(forKey: "profiles.active")
    }

    /// Opens the profile bound to this iCloud user, or the only profile, when it has no PIN;
    /// anything else waits for the picker.
    public func openAutomaticallyIfPossible(boundTo userRecordName: String? = nil) {
        guard activeID == nil else { return }
        if let userRecordName, let mine = profiles.first(where: { $0.userRecordName == userRecordName }), !mine.isLocked {
            activate(mine)
            return
        }
        guard profiles.count == 1, let only = profiles.first, !only.isLocked else { return }
        activate(only)
    }

    // MARK: Switching

    public func activate(_ profile: Profile) {
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        if activeID != nil { flushSave() }
        state = Self.loadState(id: profile.id)
        activeID = profile.id
        lastActiveID = profile.id
        UserDefaults.standard.set(profile.id, forKey: "profiles.active")
        diagnostics("Profile “\(profile.name)” opened")
        onActivate?(profile)
    }

    /// Back to "Who's listening?": playback stops and the next person picks themselves.
    public func lock() {
        flushSave()
        onDeactivate?()
        activeID = nil
        state = ProfileState()
    }

    // MARK: Editing

    @discardableResult
    public func create(name: String, avatar: ProfileAvatar, pin: String?) -> Profile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canAddProfile else { return nil }
        let profile = Profile(
            id: UUID().uuidString, name: trimmed, avatar: avatar, pin: pin.map(PINRecord.make),
            role: profiles.isEmpty ? .owner : .member, createdAt: .now, updatedAt: .now
        )
        profiles.append(profile)
        saveProfiles()
        Self.writeState(ProfileState(), id: profile.id)
        sync?.profileChanged(profile)
        return profile
    }

    public func update(_ profile: Profile, echo: Bool = true) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        updated.name = profile.name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.updatedAt = .now
        profiles[index] = updated
        saveProfiles()
        if echo { sync?.profileChanged(updated) }
    }

    /// Removes the profile and its data; the last profile cannot go.
    public func delete(_ profile: Profile) {
        guard profiles.count > 1, let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        if activeID == profile.id { lock() }
        profiles.remove(at: index)
        if profiles.contains(where: { $0.role == .owner }) == false { profiles[0].role = .owner }
        saveProfiles()
        try? FileManager.default.removeItem(at: Self.stateURL(id: profile.id))
        try? FileManager.default.removeItem(at: Self.directory.appending(path: "\(profile.id)-photo.jpg"))
        UserDefaults.standard.removeObject(forKey: Self.biometricsKey(profile.id))
        if lastActiveID == profile.id {
            lastActiveID = nil
            UserDefaults.standard.removeObject(forKey: "profiles.active")
        }
        if !isApplyingRemote { sync?.profileDeleted(id: profile.id) }
    }

    // MARK: Photos

    /// The profile's photo on this device, when it has one.
    public static func photoURL(for id: String) -> URL? {
        let url = directory.appending(path: "\(id)-photo.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps a picked picture as a small JPEG and bumps the version; nil removes the photo.
    public func setPhoto(_ data: Data?, for profile: Profile) {
        var updated = profile
        let url = Self.directory.appending(path: "\(profile.id)-photo.jpg")
        if let data, let resized = Self.jpeg(from: data, maxPixels: 640) {
            try? resized.write(to: url, options: .atomic)
            updated.avatar.photoVersion = (profile.avatar.photoVersion ?? 0) + 1
        } else {
            try? FileManager.default.removeItem(at: url)
            updated.avatar.photoVersion = nil
        }
        update(updated)
    }

    /// A photo that arrived from iCloud for a profile.
    public func storeRemotePhoto(at source: URL?, for id: String) {
        let url = Self.directory.appending(path: "\(id)-photo.jpg")
        guard let source else {
            try? FileManager.default.removeItem(at: url)
            return
        }
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.copyItem(at: source, to: url)
    }

    nonisolated private static func jpeg(from data: Data, maxPixels: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let sink = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(sink, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(sink) else { return nil }
        return output as Data
    }

    // MARK: Changes arriving from iCloud

    /// A profile as another device has it; the newer copy wins.
    public func applyRemote(_ profile: Profile) {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            guard profile.updatedAt > profiles[index].updatedAt else { return }
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        saveProfiles()
    }

    /// A profile's document as another device has it.
    public func applyRemote(_ remote: ProfileState, id: String) {
        if id == activeID {
            guard remote.updatedAt > state.updatedAt else { return }
            saveTask?.cancel()
            state = remote
            Self.writeState(remote, id: id)
            onRemoteState?()
        } else {
            guard remote.updatedAt > Self.loadState(id: id).updatedAt else { return }
            Self.writeState(remote, id: id)
        }
    }

    public func removeRemote(id: String) {
        guard let profile = profiles.first(where: { $0.id == id }), profiles.count > 1 else { return }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        delete(profile)
    }

    /// Joining another family: nobody here is the owner any more.
    public func markAllAsMembers() {
        for index in profiles.indices where profiles[index].role == .owner {
            profiles[index].role = .member
            profiles[index].updatedAt = .now
        }
        saveProfiles()
    }

    /// A profile's document as saved on this device, for uploading.
    public func storedState(id: String) -> ProfileState {
        id == activeID ? state : Self.loadState(id: id)
    }

    public func verify(pin: String, for profile: Profile) -> Bool {
        profile.pin?.matches(pin) ?? true
    }

    // MARK: Face ID, per device

    public var biometryName: String? {
        #if canImport(LocalAuthentication) && !os(tvOS) && !os(watchOS)
        let context = LAContext()
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        switch context.biometryType {
        case .faceID: return "Face ID"
        case .touchID: return "Touch ID"
        case .opticID: return "Optic ID"
        default: return nil
        }
        #else
        return nil
        #endif
    }

    public func biometricsEnabled(for profile: Profile) -> Bool {
        UserDefaults.standard.bool(forKey: Self.biometricsKey(profile.id))
    }

    public func setBiometrics(_ enabled: Bool, for profile: Profile) {
        UserDefaults.standard.set(enabled, forKey: Self.biometricsKey(profile.id))
    }

    /// Asks the device for its owner's face or finger; true means the profile may open.
    public func unlockWithBiometrics(_ profile: Profile) async -> Bool {
        #if canImport(LocalAuthentication) && !os(tvOS) && !os(watchOS)
        let context = LAContext()
        context.localizedCancelTitle = "Use PIN"
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        do {
            return try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Open the profile “\(profile.name)”")
        } catch {
            return false
        }
        #else
        return false
        #endif
    }

    private static func biometricsKey(_ id: String) -> String { "profiles.biometrics.\(id)" }

    // MARK: The active profile's data

    public func libraryState(for driveID: String) -> LibraryState {
        state.libraries[driveID] ?? LibraryState()
    }

    public func updateLibrary(_ driveID: String, _ change: (inout LibraryState) -> Void) {
        guard activeID != nil else { return }
        var library = state.libraries[driveID] ?? LibraryState()
        change(&library)
        state.libraries[driveID] = library
        touch()
    }

    public func updateSettings(_ change: (inout ProfileSettings) -> Void) {
        guard activeID != nil else { return }
        var settings = state.settings
        change(&settings)
        guard settings != state.settings else { return }
        state.settings = settings
        touch()
    }

    private func touch() {
        state.updatedAt = .now
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.flushSave()
        }
    }

    /// Writes the active profile's document right away.
    public func flushSave() {
        saveTask?.cancel()
        guard let activeID else { return }
        Self.writeState(state, id: activeID)
        sync?.stateChanged(state, id: activeID)
    }

    // MARK: Files

    static let directory: URL = {
        let base = AppDirectories.support
            .appending(path: "Skyr/profiles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private static var profilesURL: URL { directory.appending(path: "profiles.json") }
    private static func stateURL(id: String) -> URL { directory.appending(path: "\(id).json") }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private static func loadProfiles() -> [Profile] {
        guard let data = try? Data(contentsOf: profilesURL) else { return [] }
        return (try? decoder.decode([Profile].self, from: data)) ?? []
    }

    private func saveProfiles() {
        if let data = try? Self.encoder.encode(profiles) {
            try? data.write(to: Self.profilesURL, options: .atomic)
        }
    }

    private static func loadState(id: String) -> ProfileState {
        guard let data = try? Data(contentsOf: stateURL(id: id)) else { return ProfileState() }
        return (try? decoder.decode(ProfileState.self, from: data)) ?? ProfileState()
    }

    private static func writeState(_ state: ProfileState, id: String) {
        if let data = try? encoder.encode(state) {
            try? data.write(to: stateURL(id: id), options: .atomic)
        }
    }

    // MARK: First run after the update

    /// Turns the favourites, playlists, history and settings saved by earlier versions into the first profile.
    private static func migrateLegacyData() -> Profile {
        let defaults = UserDefaults.standard
        var name = "Me"
        if let data = defaults.data(forKey: "connection"), let saved = try? JSONDecoder().decode(ServerConnection.self, from: data),
           let first = saved.account.first {
            name = String(first).uppercased() + saved.account.dropFirst()
        }
        let profile = Profile(
            id: UUID().uuidString, name: name, avatar: ProfileAvatar(symbol: "music.note", colorHex: "#4a2fd6"),
            pin: nil, role: .owner, createdAt: .now, updatedAt: .now
        )
        var state = ProfileState()
        var driveIDs: Set<String> = []
        for key in defaults.dictionaryRepresentation().keys {
            for prefix in ["favourites.", "played.", "playlists."] where key.hasPrefix(prefix) {
                driveIDs.insert(String(key.dropFirst(prefix.count)))
            }
        }
        let recentAlbums = defaults.stringArray(forKey: "recentlyPlayed") ?? []
        let searches = defaults.stringArray(forKey: "recentSearches") ?? []
        for driveID in driveIDs {
            var library = LibraryState()
            library.favourites = defaults.stringArray(forKey: "favourites.\(driveID)") ?? []
            library.played = defaults.stringArray(forKey: "played.\(driveID)") ?? []
            if let data = defaults.data(forKey: "playlists.\(driveID)"), let lists = try? JSONDecoder().decode([LocalPlaylist].self, from: data) {
                library.playlists = lists
            }
            library.recentAlbums = recentAlbums
            library.searches = searches
            state.libraries[driveID] = library
        }
        var settings = ProfileSettings()
        if let quality = defaults.string(forKey: "quality") { settings.quality = quality }
        if let appearance = defaults.string(forKey: "appearance") { settings.appearance = appearance }
        if defaults.object(forKey: "gapless") != nil { settings.gapless = defaults.bool(forKey: "gapless") }
        settings.hidesBracketedTitleParts = defaults.bool(forKey: "hideBracketedTitleParts")
        if let repeatMode = defaults.string(forKey: "repeatMode") { settings.repeatMode = repeatMode }
        settings.shuffle = defaults.bool(forKey: "shuffle")
        state.settings = settings
        state.updatedAt = .now
        writeState(state, id: profile.id)
        diagnostics("Made the first profile “\(name)” from the saved favourites, playlists and settings")
        return profile
    }
}
