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
    /// Identifies this authenticated opening. Deferred work must still match it before acting.
    public private(set) var sessionID: UUID?
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
    private let storageDirectory: URL
    private let defaults: UserDefaults
    private let log: (String) -> Void
    private var authenticationGeneration = UUID()

    public var active: Profile? { profiles.first { $0.id == activeID } }
    public var isLocked: Bool { active == nil || sessionID == nil }
    public var owner: Profile? { profiles.first { $0.role == .owner } ?? profiles.first }
    public var canAddProfile: Bool { profiles.count < Profile.limit }

    /// Managing another person requires the family owner's profile to be open on their device.
    public var canManageProfiles: Bool { !isLocked && active?.role == .owner && (sync?.isOwner ?? true) }

    public func canEdit(_ profile: Profile) -> Bool {
        guard !isLocked, profiles.contains(where: { $0.id == profile.id }) else { return false }
        return profile.id == activeID || canManageProfiles
    }

    public convenience init() {
        self.init(directory: Self.directory, defaults: .standard, log: { diagnostics($0) })
    }

    /// Separate storage keeps policy tests away from the person's saved profiles and preferences.
    init(directory: URL, defaults: UserDefaults, log: @escaping (String) -> Void = { _ in }) {
        storageDirectory = directory
        self.defaults = defaults
        self.log = log
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let stored = loadProfiles() {
            profiles = stored.isEmpty ? [Self.recoveryProfile(isOwner: true, account: nil)] : stored
            if stored.isEmpty { saveProfiles() }
        } else {
            profiles = [migrateLegacyData()]
            saveProfiles()
        }
        lastActiveID = defaults.string(forKey: "profiles.active")
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

    @discardableResult
    public func activate(_ profile: Profile, pin: String? = nil) -> Bool {
        guard let current = profiles.first(where: { $0.id == profile.id }) else { return false }
        if current.id == activeID, sessionID != nil { return true }
        if let record = current.pin {
            guard let pin, record.matches(pin) else { return false }
        }
        openAuthenticated(current)
        return true
    }

    private func openAuthenticated(_ profile: Profile) {
        if activeID != nil { lock() }
        state = loadState(id: profile.id)
        activeID = profile.id
        sessionID = UUID()
        authenticationGeneration = UUID()
        lastActiveID = profile.id
        defaults.set(profile.id, forKey: "profiles.active")
        log("Profile “\(profile.name)” opened")
        onActivate?(profile)
    }

    /// Back to "Who's listening?": playback stops and the next person picks themselves.
    public func lock() {
        flushSave()
        authenticationGeneration = UUID()
        activeID = nil
        sessionID = nil
        state = ProfileState()
        onDeactivate?()
    }

    // MARK: Editing

    /// Editors belong to both a profile revision and the session that opened them.
    public func canEditDraft(_ profile: Profile, session: UUID?) -> Bool {
        guard let session, sessionID == session, canEdit(profile),
              let current = profiles.first(where: { $0.id == profile.id }) else { return false }
        return current.updatedAt == profile.updatedAt
    }

    @discardableResult
    public func create(name: String, avatar: ProfileAvatar, pin: String?) -> Profile? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, canAddProfile, canManageProfiles else { return nil }
        var profile = Profile(
            id: UUID().uuidString, name: trimmed, avatar: avatar, pin: pin.map(PINRecord.make),
            role: profiles.isEmpty ? .owner : .member, createdAt: .now, updatedAt: .now
        )
        profile.localOrigin = .created
        guard sync?.prepareProfileCreation(profile) != false else { return nil }
        var updated = profiles
        updated.append(profile)
        guard writeState(ProfileState(), id: profile.id), saveProfiles(updated) else { return nil }
        profiles = updated
        sync?.profileChanged(profile)
        return profile
    }

    @discardableResult
    public func update(_ profile: Profile) -> Bool {
        guard canEdit(profile), let current = profiles.first(where: { $0.id == profile.id }),
              current.updatedAt == profile.updatedAt,
              profile.role == current.role, profile.createdAt == current.createdAt,
              profile.localOrigin == current.localOrigin,
              profile.userRecordName == current.userRecordName else { return false }
        var updated = profile
        updated.name = updated.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !updated.name.isEmpty else { return false }
        // Roles and account ownership belong to the family sync flow, never a form draft.
        saveUpdated(updated)
        return true
    }

    private func saveUpdated(_ profile: Profile, echo: Bool = true) {
        guard let index = profiles.firstIndex(where: { $0.id == profile.id }) else { return }
        var updated = profile
        if updated.pin != profiles[index].pin {
            defaults.removeObject(forKey: Self.biometricsKey(profile.id))
            authenticationGeneration = UUID()
        }
        updated.updatedAt = .now
        profiles[index] = updated
        saveProfiles()
        if echo { sync?.profileChanged(updated) }
    }

    /// Removes the profile and its data; the last profile cannot go.
    @discardableResult
    public func delete(_ profile: Profile) -> Bool {
        guard canManageProfiles else { return false }
        return removeStoredProfile(id: profile.id)
    }

    @discardableResult
    private func removeStoredProfile(id: String, allowLast: Bool = false, replacementAccount: String? = nil, replacementIsOwner: Bool = true) -> Bool {
        guard (allowLast || profiles.count > 1), let index = profiles.firstIndex(where: { $0.id == id }) else { return false }
        let profile = profiles[index]
        if !isApplyingRemote, let sync, !sync.prepareProfileDeletion(id: profile.id) { return false }
        var remaining = profiles
        remaining.remove(at: index)
        if remaining.isEmpty, allowLast {
            remaining = [Self.recoveryProfile(isOwner: replacementIsOwner, account: replacementAccount)]
        }
        if !isApplyingRemote, !remaining.isEmpty, remaining.contains(where: { $0.role == .owner }) == false { remaining[0].role = .owner }
        guard saveProfiles(remaining) else { return false }
        if activeID == profile.id { lock() }
        profiles = remaining
        try? FileManager.default.removeItem(at: stateURL(id: profile.id))
        try? FileManager.default.removeItem(at: storageDirectory.appending(path: "\(profile.id)-photo.jpg"))
        defaults.removeObject(forKey: Self.biometricsKey(profile.id))
        if lastActiveID == profile.id {
            lastActiveID = nil
            defaults.removeObject(forKey: "profiles.active")
        }
        if !isApplyingRemote { sync?.profileDeleted(id: profile.id) }
        return true
    }

    /// The sync engine may discard only an untouched first-launch stand-in.
    @discardableResult
    func discardStandIn(_ profile: Profile) -> Bool {
        guard let current = profiles.first(where: { $0.id == profile.id }),
              current.userRecordName == nil, current.pin == nil, current.avatar.photoVersion == nil,
              abs(current.updatedAt.timeIntervalSince(current.createdAt)) < 2,
              storedState(id: current.id).isPristine else { return false }
        return removeStoredProfile(id: current.id)
    }

    @discardableResult
    public func bindToCurrentUser(_ profile: Profile) -> Bool {
        guard canEdit(profile), let user = sync?.currentUserRecordName,
              sync?.containsProfileInCurrentAccount(profile.id) == true,
              var current = profiles.first(where: { $0.id == profile.id }) else { return false }
        current.userRecordName = user
        saveUpdated(current)
        return true
    }

    /// Initial account binding during sync applies only to the authenticated active profile.
    func bindActiveProfile(to user: String) {
        guard !isLocked, var current = active else { return }
        current.userRecordName = user
        saveUpdated(current, echo: false)
    }

    // MARK: Photos

    /// The profile's photo on this device, when it has one.
    public static func photoURL(for id: String) -> URL? {
        let url = directory.appending(path: "\(id)-photo.jpg")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Keeps a picked picture as a small JPEG and bumps the version; nil removes the photo.
    @discardableResult
    public func setPhoto(_ data: Data?, for profile: Profile) -> Bool {
        guard canEdit(profile), var updated = profiles.first(where: { $0.id == profile.id }) else { return false }
        let url = storageDirectory.appending(path: "\(profile.id)-photo.jpg")
        if let data, let resized = Self.jpeg(from: data, maxPixels: 640) {
            try? resized.write(to: url, options: .atomic)
            updated.avatar.photoVersion = (updated.avatar.photoVersion ?? 0) + 1
        } else {
            try? FileManager.default.removeItem(at: url)
            updated.avatar.photoVersion = nil
        }
        saveUpdated(updated)
        return true
    }

    /// A photo that arrived from iCloud for a profile.
    @discardableResult
    public func storeRemotePhoto(at source: URL?, for id: String) -> Bool {
        let url = storageDirectory.appending(path: "\(id)-photo.jpg")
        do {
            if let source {
                // Atomic replacement keeps the prior photo when writing fails.
                try Data(contentsOf: source).write(to: url, options: .atomic)
            } else if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            return true
        } catch {
            return false
        }
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
    @discardableResult
    public func applyRemote(_ profile: Profile) -> Bool {
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        var updated = profiles
        var incoming = profile
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            guard profile.updatedAt > profiles[index].updatedAt else { return true }
            incoming.localOrigin = profiles[index].localOrigin
            updated[index] = incoming
        } else {
            // A real profile arriving from another device is never a local first-launch stand-in.
            incoming.localOrigin = .created
            updated.append(incoming)
        }
        guard saveProfiles(updated) else { return false }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            if profile.pin != profiles[index].pin {
                defaults.removeObject(forKey: Self.biometricsKey(profile.id))
                authenticationGeneration = UUID()
                if activeID == profile.id { lock() }
            }
        }
        profiles = updated
        return true
    }

    /// A profile's document as another device has it.
    @discardableResult
    public func applyRemote(_ remote: ProfileState, id: String) -> Bool {
        if id == activeID {
            guard remote.updatedAt > state.updatedAt else { return true }
            guard writeState(remote, id: id) else { return false }
            saveTask?.cancel()
            state = remote
            onRemoteState?()
        } else {
            guard remote.updatedAt > loadState(id: id).updatedAt else { return true }
            guard writeState(remote, id: id) else { return false }
        }
        return true
    }

    @discardableResult
    public func removeRemote(id: String, replacementAccount: String? = nil, replacementIsOwner: Bool = true) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }) else { return true }
        isApplyingRemote = true
        defer { isApplyingRemote = false }
        return removeStoredProfile(id: profile.id, allowLast: true, replacementAccount: replacementAccount, replacementIsOwner: replacementIsOwner)
    }

    /// A completed pull may legitimately remove the last local profile. Keep the picker usable
    /// without importing old legacy settings again or recreating the deleted record's identifier.
    func ensureProfileAfterSync(isOwner: Bool) -> Profile? {
        guard profiles.isEmpty else { return nil }
        let profile = Self.recoveryProfile(isOwner: isOwner, account: sync?.currentUserRecordName)
        guard saveProfiles([profile]) else { return nil }
        profiles = [profile]
        return profile
    }

    private static func recoveryProfile(isOwner: Bool, account: String?) -> Profile {
        var profile = Profile(id: UUID().uuidString, name: "Me", avatar: .random(), pin: nil,
                              role: isOwner ? .owner : .member, createdAt: .now, updatedAt: .now)
        profile.localOrigin = .recovery(account: account)
        return profile
    }

    /// Bind the local recovery marker once, durably, before any account snapshot adopts its ID.
    func bindUnassignedRecoveryProfile(id: String, to account: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }),
              profiles[index].localOrigin == .recovery(account: nil) else { return false }
        var updated = profiles
        updated[index].localOrigin = .recovery(account: account)
        guard saveProfiles(updated) else { return false }
        profiles = updated
        return true
    }

    /// Joining another family: nobody here is the owner any more.
    @discardableResult
    public func markAllAsMembers(in ids: Set<String>) -> Bool {
        var updated = profiles
        for index in updated.indices where ids.contains(updated[index].id) && updated[index].role == .owner {
            updated[index].role = .member
            updated[index].updatedAt = .now
        }
        guard saveProfiles(updated) else { return false }
        profiles = updated
        return true
    }

    /// A profile's document as saved on this device, for uploading.
    public func storedState(id: String) -> ProfileState {
        id == activeID ? state : loadState(id: id)
    }

    public func verify(pin: String, for profile: Profile) -> Bool {
        guard let current = profiles.first(where: { $0.id == profile.id }) else { return false }
        return current.pin?.matches(pin) ?? true
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
        guard profiles.first(where: { $0.id == profile.id })?.isLocked == true else { return false }
        return defaults.bool(forKey: Self.biometricsKey(profile.id))
    }

    @discardableResult
    public func setBiometrics(_ enabled: Bool, for profile: Profile) -> Bool {
        guard canEdit(profile), let current = profiles.first(where: { $0.id == profile.id }),
              !enabled || current.isLocked else { return false }
        defaults.set(enabled, forKey: Self.biometricsKey(profile.id))
        return true
    }

    /// Opens the current stored profile after its enrolled device biometrics succeed.
    public func unlockWithBiometrics(_ profile: Profile) async -> Bool {
        #if canImport(LocalAuthentication) && !os(tvOS) && !os(watchOS)
        guard let current = profiles.first(where: { $0.id == profile.id }), biometricsEnabled(for: current) else { return false }
        let generation = authenticationGeneration
        let context = LAContext()
        context.localizedCancelTitle = "Use PIN"
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return false }
        do {
            let accepted = try await context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: "Open the profile “\(current.name)”")
            guard accepted, authenticationGeneration == generation,
                  let stored = profiles.first(where: { $0.id == current.id }), stored.pin == current.pin,
                  biometricsEnabled(for: stored) else { return false }
            openAuthenticated(stored)
            return true
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
        writeState(state, id: activeID)
        if !isApplyingRemote { sync?.stateChanged(state, id: activeID) }
    }

    // MARK: Files

    static let directory: URL = {
        let base = AppDirectories.support
            .appending(path: "Skyr/profiles", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    private var profilesURL: URL { storageDirectory.appending(path: "profiles.json") }
    private func stateURL(id: String) -> URL { storageDirectory.appending(path: "\(id).json") }

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

    private func loadProfiles() -> [Profile]? {
        guard let data = try? Data(contentsOf: profilesURL) else { return nil }
        return try? Self.decoder.decode([Profile].self, from: data)
    }

    @discardableResult
    private func saveProfiles(_ value: [Profile]? = nil) -> Bool {
        do {
            try Self.encoder.encode(value ?? profiles).write(to: profilesURL, options: .atomic)
            return true
        } catch {
            log("The profiles could not be saved on this device.")
            return false
        }
    }

    private func loadState(id: String) -> ProfileState {
        guard let data = try? Data(contentsOf: stateURL(id: id)) else { return ProfileState() }
        return (try? Self.decoder.decode(ProfileState.self, from: data)) ?? ProfileState()
    }

    @discardableResult
    private func writeState(_ state: ProfileState, id: String) -> Bool {
        do {
            try Self.encoder.encode(state).write(to: stateURL(id: id), options: .atomic)
            return true
        } catch {
            log("The profile's library and settings could not be saved on this device.")
            return false
        }
    }

    // MARK: First run after the update

    /// Turns the favourites, playlists, history and settings saved by earlier versions into the first profile.
    private func migrateLegacyData() -> Profile {
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
        log("Made the first profile “\(name)” from the saved favourites, playlists and settings")
        return profile
    }
}
