import SwiftUI

/// Connection flow, browsing state and settings for the whole app.
@Observable
public final class AppModel {
    public enum Stage: Hashable {
        case welcome, discovering, chooseFolder, indexing, ready
    }

    public let library: LibraryStore
    public let discovery = ServerDiscovery()
    public let indexer = LibraryIndexer()

    // MARK: Connection

    public var stage: Stage = .welcome
    /// Server chosen from discovery or typed manually; presents the sign-in sheet while set.
    public var pendingServer: DiscoveredServer?
    public private(set) var isSigningIn = false
    public var signInError: String?
    public private(set) var needsOTP = false
    public private(set) var connection: ServerConnection?
    public private(set) var isRestoring = false
    public private(set) var isReconnecting = false
    private var session: DSMSession?
    private var connectionGeneration = UUID()
    private let defaults: UserDefaults
    private let services: ConnectionServices

    public var isDemo: Bool { library.isDemo }
    public var isConnected: Bool { session != nil }
    public var serverTitle: String { connection?.name ?? library.catalogue.serverName }

    public convenience init(library: LibraryStore) {
        self.init(library: library, defaults: .standard, services: ConnectionServices(), restoresSession: true)
    }

    init(library: LibraryStore, defaults: UserDefaults, services: ConnectionServices, restoresSession: Bool) {
        self.library = library
        self.defaults = defaults
        self.services = services
        loadSettings()
        // Covers cached by earlier builds could belong to the wrong album; fetch them again once.
        if restoresSession, defaults.integer(forKey: "coverCacheVersion") < 3 {
            CoverStore.clear()
            defaults.set(3, forKey: "coverCacheVersion")
        }
        if restoresSession { restoreSession() }
    }

    /// Invalidate every suspended connection operation before a new intent takes over.
    @discardableResult
    private func beginConnectionChange() -> UUID {
        connectionGeneration = UUID()
        isSigningIn = false
        isRestoring = false
        isReconnecting = false
        isJoiningFamily = false
        indexer.cancel()
        return connectionGeneration
    }

    private func isCurrent(_ generation: UUID) -> Bool {
        generation == connectionGeneration && !Task.isCancelled
    }

    public func findServers() {
        beginConnectionChange()
        stage = .discovering
        discovery.start()
    }

    public func select(_ server: DiscoveredServer) {
        beginConnectionChange()
        signInError = nil
        needsOTP = false
        pendingServer = server
    }

    /// Accepts a host, host:port or full URL typed by the user.
    @discardableResult
    public func enterAddress(_ text: String) -> Bool {
        guard let url = SynologyClient.baseURL(from: text), let host = url.host() else { return false }
        if stage == .welcome { stage = .discovering; discovery.start() }
        select(DiscoveredServer(name: host, baseURL: url, model: nil))
        return true
    }

    /// Takes an address, finds where DSM answers, and offers that server for sign-in.
    public func connect(to entry: String) async throws {
        let generation = beginConnectionChange()
        let url = try await SynologyClient.reachableBaseURL(for: entry.trimmingCharacters(in: .whitespacesAndNewlines))
        guard isCurrent(generation) else { throw CancellationError() }
        guard enterAddress(url.absoluteString) else { throw SynologyError.invalidAddress }
    }

    public func cancelSignIn() {
        beginConnectionChange()
        pendingServer = nil
        needsOTP = false
    }

    public func signIn(account: String, password: String, otpCode: String, remember: Bool) async {
        guard let server = pendingServer else { return }
        let generation = beginConnectionChange()
        isSigningIn = true
        signInError = nil
        defer { if generation == connectionGeneration { isSigningIn = false } }
        do {
            let session = try await services.login(server.baseURL, account, password, otpCode.isEmpty ? nil : otpCode)
            guard isCurrent(generation) else { await services.logout(session); return }
            let info = await services.info(session)
            guard isCurrent(generation) else { await services.logout(session); return }
            let name = (info?.model ?? server.model).map { "Synology \($0)" } ?? server.name
            var connection = ServerConnection(
                name: name, baseURL: server.baseURL, account: account,
                musicPath: nil
            )
            if let previous = self.connection, previous.host == server.host, previous.account == account {
                connection.musicPath = previous.musicPath
            }
            if connection.musicPath == nil, let family = joiningFamily, family.address.flatMap({ URL(string: $0)?.host() }) == server.host {
                connection.musicPath = family.musicPath
            }
            self.connection = connection
            saveConnection()
            if remember {
                services.savePassword(password, connection.keychainAccount)
            } else {
                services.deletePassword(connection.keychainAccount)
            }
            self.session = session
            let drive = SynologyDrive(session: session, displayName: name)
            services.log("Signed in to \(name) at \(server.address)")
            pendingServer = nil
            needsOTP = false
            discovery.stop()
            if library.catalogue.belongs(to: connection), !library.isEmpty {
                library.drive = drive
                stage = .ready
                startAutoRefresh()
            } else {
                library.replace(with: .empty, drive: drive)
                if connection.musicPath != nil { startIndexing(showsProgress: true) }
                else { stage = .chooseFolder }
            }
        } catch SynologyError.twoFactorRequired {
            guard isCurrent(generation) else { return }
            needsOTP = true
            signInError = "Enter the code from your authenticator app."
        } catch {
            guard isCurrent(generation) else { return }
            services.log("Sign-in failed at \(server.address): \(error.localizedDescription)")
            signInError = error.localizedDescription
        }
    }

    /// Back to the folder picker, keeping the session.
    public func chooseAnotherFolder() {
        beginConnectionChange()
        stage = .chooseFolder
    }

    /// Signs in again at the saved address, keeping the current library.
    public func reconnect() async {
        guard let saved = connection else { return }
        let generation = beginConnectionChange()
        guard let password = storedPassword(for: saved) else {
            requestReauthentication(saved, needsOTP: false)
            return
        }
        isReconnecting = true
        defer { if generation == connectionGeneration { isReconnecting = false } }
        let connection = saved
        do {
            let session = try await services.login(connection.baseURL, connection.account, password, nil)
            guard isCurrent(generation) else { await services.logout(session); return }
            self.session = session
            self.connection = connection
            saveConnection()
            library.drive = SynologyDrive(session: session, displayName: connection.name)
            signInError = nil
        } catch SynologyError.twoFactorRequired {
            guard isCurrent(generation) else { return }
            requestReauthentication(connection, needsOTP: true)
        } catch {
            guard isCurrent(generation) else { return }
            signInError = error.localizedDescription
        }
    }

    private func requestReauthentication(_ saved: ServerConnection, needsOTP: Bool) {
        if stage != .ready { stage = .discovering }
        pendingServer = DiscoveredServer(name: saved.name, baseURL: saved.baseURL, model: nil)
        self.needsOTP = needsOTP
        signInError = needsOTP ? "Enter your password and the code from your authenticator app to reconnect." : "Sign in again to reconnect to your server."
    }

    // MARK: Music folder

    public var musicPath: String? { connection?.musicPath }
    public var musicFolderLabel: String {
        guard let path = musicPath else { return "Not chosen" }
        return path.split(separator: "/").last.map(String.init) ?? path
    }

    /// Lists folders on the drive; nil lists the shared folders.
    public func loadFolders(in parent: String?) async throws -> [RemoteEntry] {
        guard let drive = library.drive else { throw SynologyError.notSignedIn }
        guard let parent else {
            let roots = try await drive.roots()
            services.log("Shares: \(roots.map(\.path).joined(separator: ", "))")
            return roots
        }
        let entries = try await drive.list(parent)
        services.log("Picker listed \(parent): \(entries.count) entries, \(entries.filter(\.isAudio).count) audio files")
        return entries.filter { $0.isDirectory && !$0.name.hasPrefix(".") && $0.name != "@eaDir" && $0.name != "#recycle" }
    }

    /// Records the folder to index and starts indexing.
    public func chooseMusicFolder(path: String, showsProgress: Bool) {
        guard var connection, let drive = library.drive else { return }
        beginConnectionChange()
        let changed = connection.musicPath != path
        connection.musicPath = path
        self.connection = connection
        saveConnection()
        if changed {
            indexer.cancel()
            library.replace(with: .empty, drive: drive)
        }
        startIndexing(showsProgress: showsProgress)
    }

    /// Back from the folder picker to pick another server.
    public func cancelFolderChoice() {
        beginConnectionChange()
        if let session { Task { await SynologyClient.logout(session) } }
        session = nil
        library.replace(with: .empty, drive: nil)
        connection = nil
        saveConnection()
        stage = .discovering
        discovery.start()
    }

    // MARK: Indexing

    public private(set) var demoCount = 0
    private var demoTask: Task<Void, Never>?

    public var indexedCount: Int { isDemo ? demoCount : indexer.tracksFound }
    public var indexingFailure: LibraryIndexer.Failure? {
        if case .failed(let failure) = indexer.phase { return failure }
        return nil
    }
    public var isIndexed: Bool {
        isDemo ? demoCount >= SampleLibrary.displayedTrackTotal : indexer.structureReady && !library.isEmpty
    }
    public var isScanning: Bool { isDemo ? demoScanning : indexer.isRunning }
    private var demoScanning = false

    private func startIndexing(showsProgress: Bool) {
        guard let drive = library.drive, let connection, let path = connection.musicPath else { return }
        if showsProgress { stage = .indexing }
        let existing = library.catalogue.isEmpty ? nil : library.catalogue
        let generation = connectionGeneration
        indexer.start(drive: drive, rootPath: path, serverName: connection.name, existing: existing) { [weak self] catalogue in
            guard let self, generation == connectionGeneration,
                  self.connection == connection, library.drive?.id == drive.id else { return }
            library.replace(with: catalogue, drive: drive)
            library.saveCatalogue()
        }
    }

    public func useSampleLibrary() {
        beginConnectionChange()
        pendingServer = nil
        connection = nil
        saveConnection()
        session = nil
        indexer.cancel()
        library.replace(with: SampleLibrary.catalogue, drive: nil)
        library.seedDemoHistory()
        discovery.stop()
        startDemoIndexing()
    }

    public func openLibrary() {
        demoTask?.cancel()
        demoTask = nil
        demoScanning = false
        stage = .ready
        startAutoRefresh()
    }

    // MARK: Automatic refresh

    private var autoRefreshTask: Task<Void, Never>?

    /// Re-indexes in the background when the app comes to the foreground and periodically while it runs.
    public func scenePhaseChanged(_ phase: ScenePhase) {
        guard phase == .active else { return }
        refreshIfStale(olderThan: 30 * 60)
    }

    public func refreshIfStale(olderThan age: TimeInterval) {
        guard watchFolder, stage == .ready, isConnected, !isDemo, !isScanning else { return }
        guard Date.now.timeIntervalSince(library.catalogue.indexedAt) > age else { return }
        services.log("Automatic refresh started")
        startIndexing(showsProgress: false)
    }

    private func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60 * 60))
                guard let self, !Task.isCancelled else { return }
                refreshIfStale(olderThan: 55 * 60)
            }
        }
    }

    public func retryIndexing() {
        startIndexing(showsProgress: true)
    }

    public func backToServers() {
        beginConnectionChange()
        stage = .discovering
        discovery.start()
    }

    public func rescan() {
        if isDemo {
            demoScanning = true
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(2.4))
                self?.demoScanning = false
            }
        } else {
            startIndexing(showsProgress: false)
        }
    }

    public func signOut() async {
        beginConnectionChange()
        pendingServer = nil
        needsOTP = false
        demoTask?.cancel()
        autoRefreshTask?.cancel()
        let oldSession = session
        session = nil
        if let connection {
            services.deletePassword(connection.keychainAccount)
            services.deletePassword(connection.legacyKeychainAccount)
        }
        connection = nil
        saveConnection()
        services.deleteCatalogue()
        library.replace(with: .empty, drive: nil)
        selectedTab = .library
        facet = .recentlyAdded
        stage = .welcome
        if let oldSession { await services.logout(oldSession) }
    }

    /// Demo mode counts up to the design's library size before opening.
    private func startDemoIndexing() {
        demoTask?.cancel()
        demoCount = 0
        demoScanning = true
        stage = .indexing
        demoTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                let total = SampleLibrary.displayedTrackTotal
                let remaining = total - demoCount
                demoCount = min(total, demoCount + Int((Double(remaining) / 14).rounded(.up)) + 37)
                if demoCount >= total {
                    demoScanning = false
                    return
                }
            }
        }
    }

    /// The remembered password for a connection. Older builds keyed it by the resolved address,
    /// which changes between home and away routes; such entries move to the stable key on first use.
    /// What a paired Apple Watch needs to reach the server on its own: the same address and account
    /// this device uses, with the password the Keychain holds for it. Nothing for the sample library.
    public func watchCredentials() -> WatchCredentials? {
        guard profiles?.sessionID != nil, let connection, !isDemo, let password = storedPassword(for: connection) else { return nil }
        return WatchCredentials(baseURL: connection.baseURL, account: connection.account, password: password, driveID: library.catalogue.driveID)
    }

    private func storedPassword(for connection: ServerConnection) -> String? {
        if let password = services.password(connection.keychainAccount) { return password }
        guard let legacy = services.password(connection.legacyKeychainAccount) else { return nil }
        services.savePassword(legacy, connection.keychainAccount)
        services.deletePassword(connection.legacyKeychainAccount)
        return legacy
    }

    // MARK: Session restore

    private func restoreSession() {
        guard let data = defaults.data(forKey: "connection"),
              let saved = try? JSONDecoder().decode(ServerConnection.self, from: data)
        else { return }
        connection = saved
        if let cached = services.loadCatalogue(), cached.belongs(to: saved), !cached.isEmpty {
            library.replace(with: cached, drive: nil)
            stage = .ready
        }
        guard let password = storedPassword(for: saved) else {
            requestReauthentication(saved, needsOTP: false)
            return
        }
        let generation = connectionGeneration
        isRestoring = true
        Task { [weak self] in
            guard let self else { return }
            defer { if generation == connectionGeneration { isRestoring = false } }
            let connection = saved
            do {
                let session = try await services.login(connection.baseURL, saved.account, password, nil)
                guard isCurrent(generation) else { await services.logout(session); return }
                self.session = session
                let drive = SynologyDrive(session: session, displayName: connection.name)
                if library.isEmpty {
                    library.replace(with: .empty, drive: drive)
                    if connection.musicPath != nil {
                        startIndexing(showsProgress: true)
                    } else {
                        stage = .chooseFolder
                    }
                } else {
                    library.drive = drive
                    // The cached library is used as is; a scan only runs when it has gone stale.
                    refreshIfStale(olderThan: 30 * 60)
                    startAutoRefresh()
                }
            } catch SynologyError.twoFactorRequired {
                guard isCurrent(generation) else { return }
                requestReauthentication(saved, needsOTP: true)
            } catch {
                guard isCurrent(generation) else { return }
                if library.isEmpty {
                    stage = .discovering
                    discovery.start()
                    requestReauthentication(saved, needsOTP: false)
                }
                signInError = error.localizedDescription
            }
        }
    }

    private func saveConnection() {
        if let connection, let data = try? JSONEncoder().encode(connection) {
            defaults.set(data, forKey: "connection")
        } else {
            defaults.removeObject(forKey: "connection")
        }
    }

    // MARK: Browsing

    public var selectedTab: AppTab = .library
    public var facet: LibraryFacet = .recentlyAdded
    /// Set to push an album onto the Library tab from outside it, for example from the player sheet.
    public var albumToOpen: Album?
    public private(set) var albumNavigationRequest = 0

    /// Closes whatever is in front, switches to the Library tab and opens the album there.
    public func showAlbum(_ album: Album) {
        albumNavigationRequest += 1
        selectedTab = .library
        Task { [weak self] in
            // Let the sheet finish dismissing before the page pushes underneath it.
            try? await Task.sleep(for: .milliseconds(350))
            self?.albumToOpen = album
        }
    }

    public var playlistToOpen: Playlist?

    /// Switches to the Playlists tab and opens the playlist there.
    public func showPlaylist(_ playlist: Playlist) {
        selectedTab = .playlists
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            self?.playlistToOpen = playlist
        }
    }

    /// A tab by the name a widget link carries.
    public func showTab(named name: String) {
        switch name {
        case "library": selectedTab = .library
        case "playlists": selectedTab = .playlists
        case "downloads": selectedTab = .downloads
        default: break
        }
    }

    /// Waits for the server sign-in that starts at launch, so a song can stream, or gives up after the limit.
    public func waitForDrive(upTo limit: Duration) async {
        let deadline = ContinuousClock.now + limit
        while library.drive == nil, !isDemo, ContinuousClock.now < deadline {
            guard !Task.isCancelled else { return }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
    public var searchQuery = ""

    public func browse(_ entry: BrowseEntry) {
        facet = entry.facet
        selectedTab = .library
    }

    // MARK: Settings

    /// Scans stop when the phone locks; leaving the screen on is the one reliable way to finish a long one.
    public var keepsScreenOnWhileScanning: Bool = UserDefaults.standard.object(forKey: "scan.keepAwake") as? Bool ?? true {
        didSet { UserDefaults.standard.set(keepsScreenOnWhileScanning, forKey: "scan.keepAwake") }
    }

    public var watchFolder = true {
        didSet {
            defaults.set(watchFolder, forKey: "watchFolder")
            if watchFolder { refreshIfStale(olderThan: 10 * 60) }
        }
    }
    public var profiles: ProfileStore?
    public var quality: StreamQuality = .lossless { didSet { profiles?.updateSettings { $0.quality = quality.rawValue } } }
    public var appearance: Appearance = .auto { didSet { profiles?.updateSettings { $0.appearance = appearance.rawValue } } }
    public var gapless = true { didSet { profiles?.updateSettings { $0.gapless = gapless } } }

    /// What the family record says about this server, once a folder is chosen.
    public var familyInfo: FamilyInfo? {
        guard let connection, connection.musicPath != nil else { return nil }
        return FamilyInfo(
            name: "\(connection.name) family", serverName: connection.name,
            serverAccount: connection.account, musicPath: connection.musicPath, updatedAt: .distantPast,
            familyAccount: familyAccess?.account, familyPassword: familyAccess?.password,
            address: connection.baseURL.absoluteString
        )
    }

    // MARK: Family access

    /// The read-only NAS account made for the family, on the owner's device.
    public private(set) var familyAccess: FamilyAccess? = {
        guard let account = UserDefaults.standard.string(forKey: "family.account"), let password = KeychainStore.password(for: "family|\(account)") else { return nil }
        return FamilyAccess(account: account, password: password)
    }()
    /// Set by the app: the family record needs pushing.
    public var onFamilyAccessChanged: (() -> Void)?
    /// A member's device is signing in with the family account.
    public private(set) var isJoiningFamily = false

    private func store(_ access: FamilyAccess?) {
        if let previous = familyAccess, previous.account != access?.account {
            KeychainStore.delete(account: "family|\(previous.account)")
        }
        familyAccess = access
        if let access {
            UserDefaults.standard.set(access.account, forKey: "family.account")
            KeychainStore.save(password: access.password, for: "family|\(access.account)")
        } else {
            UserDefaults.standard.removeObject(forKey: "family.account")
        }
        onFamilyAccessChanged?()
    }

    private var musicShareName: String? {
        connection?.musicPath?.split(separator: "/").first.map(String.init)
    }

    /// Makes the family account on the NAS with a long random password and read-only access to the
    /// music share. Returns what went wrong, if anything; the owner's account must be an administrator.
    public func setUpFamilyAccess() async -> String? {
        guard session != nil, let connection else { return "Not connected to the server." }
        guard let share = musicShareName else { return "Choose the music folder first." }
        let account = "skyr-" + Self.randomToken(length: 6, from: "abcdefghijkmnpqrstuvwxyz23456789")
        let password = Self.randomPassword()
        do {
            try await withAdministrator { admin, confirm in
                try await SynologyClient.createFamilyUser(admin, name: account, password: password, shareName: share, confirm: confirm)
            }
            store(FamilyAccess(account: account, password: password))
            services.log("Family account \(account) ready with read-only access to “\(share)” on \(connection.name)")
            return nil
        } catch {
            services.log("Family account could not be created: \(error.localizedDescription)")
            return "Your NAS wouldn't let the app create the account. DSM blocks account management from outside its own web interface, especially with two-factor authentication on. Use “Add an account yourself” below; it takes a minute and works everywhere."
        }
    }

    /// Runs a change that DSM treats as privileged. Two things can stand in the way: DSM wants a
    /// fresh confirmation of the host's own password, and over a public route it only accepts these
    /// calls from a session that did the full sign-in handshake. The work is tried on the session
    /// that is already open, then on a dedicated DSM session that has both.
    private func withAdministrator(_ body: (DSMSession, String?) async throws -> Void) async throws {
        guard let session, let connection else { throw SynologyError.notSignedIn }
        // Only the session that is already open is used. Signing in again to gain more rights fails
        // on any account with two-factor authentication, and repeated tries make DSM mail its owner
        // emergency codes and eventually block the device, so the app never does that on its own.
        guard await SynologyClient.canManageUsers(session) == true else {
            services.log("\(connection.account) may not manage users through this connection")
            throw SynologyError.api(code: 105, api: "SYNO.Core.User")
        }
        var confirm: String?
        if let password = storedPassword(for: connection) {
            confirm = await SynologyClient.confirmToken(session, password: password)
        }
        try await body(session, confirm)
    }

    /// An account the owner made by hand; checked with a sign-in before it is kept.
    public func useFamilyAccess(account: String, password: String) async -> String? {
        guard let connection else { return "Not connected to the server." }
        do {
            let probe = try await SynologyClient.login(baseURL: connection.baseURL, account: account, password: password, otpCode: nil)
            await SynologyClient.logout(probe)
            store(FamilyAccess(account: account, password: password))
            services.log("Family account \(account) set by hand")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// A new password for the family account, so devices that left stop working.
    public func rotateFamilyAccess() async -> String? {
        guard session != nil, let access = familyAccess else { return nil }
        let password = Self.randomPassword()
        do {
            try await withAdministrator { admin, confirm in
                try await SynologyClient.setPassword(admin, user: access.account, password: password, confirm: confirm)
            }
            store(FamilyAccess(account: access.account, password: password))
            services.log("Family account password rotated")
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    /// Deletes the family account from the NAS when the owner can, and forgets it either way.
    public func removeFamilyAccess() async {
        if session != nil, let access = familyAccess {
            do {
                try await withAdministrator { admin, confirm in
                    try await SynologyClient.deleteUser(admin, name: access.account, confirm: confirm)
                }
                services.log("Family account \(access.account) deleted from the server")
            } catch {
                services.log("Family account could not be deleted: \(error.localizedDescription)")
            }
        }
        store(nil)
    }

    /// The family record arrived: a member's device connects with the family account on its own,
    /// and picks up a rotated password.
    public func familyArrived(_ info: FamilyInfo) {
        guard let account = info.familyAccount, let password = info.familyPassword else { return }
        if let connection {
            if connection.account == account, info.address.flatMap({ URL(string: $0)?.host() }) == connection.host,
               storedPassword(for: connection) != password {
                KeychainStore.save(password: password, for: connection.keychainAccount)
                Task { await reconnect() }
            }
            return
        }
        guard familyAccess == nil else { return }
        Task { await connectWithFamilyAccess(info) }
    }

    /// Signs in with the family account and indexes the family's folder; no password asked.
    public func connectWithFamilyAccess(_ info: FamilyInfo) async {
        guard info.isReachable, let account = info.familyAccount, let password = info.familyPassword, !isJoiningFamily else { return }
        let generation = beginConnectionChange()
        isJoiningFamily = true
        signInError = nil
        defer { if generation == connectionGeneration { isJoiningFamily = false } }
        do {
            let url = try familyURL(info)
            let session = try await services.login(url, account, password, nil)
            guard isCurrent(generation) else { await services.logout(session); return }
            let dsm = await services.info(session)
            guard isCurrent(generation) else { await services.logout(session); return }
            let name = dsm?.model.map { "Synology \($0)" } ?? info.serverName
            let connection = ServerConnection(name: name, baseURL: url, account: account, musicPath: info.musicPath)
            self.connection = connection
            saveConnection()
            services.savePassword(password, connection.keychainAccount)
            self.session = session
            discovery.stop()
            library.replace(with: .empty, drive: SynologyDrive(session: session, displayName: name))
            services.log("Connected to \(name) with the family account at \(url.host() ?? "its address")")
            if connection.musicPath != nil {
                startIndexing(showsProgress: true)
            } else {
                stage = .chooseFolder
            }
        } catch {
            guard isCurrent(generation) else { return }
            services.log("Family sign-in failed: \(error.localizedDescription)")
            signInError = error.localizedDescription
        }
    }

    private static func randomToken(length: Int, from alphabet: String) -> String {
        String((0..<length).compactMap { _ in alphabet.randomElement() })
    }

    /// Twenty-four characters with letters of both cases, digits and symbols, for any DSM password policy.
    private static func randomPassword() -> String {
        let sets = ["ABCDEFGHJKLMNPQRSTUVWXYZ", "abcdefghijkmnpqrstuvwxyz", "23456789", "!#*@_-"]
        var characters = sets.map { $0.randomElement()! }
        let all = sets.joined()
        characters += (0..<20).map { _ in all.randomElement()! }
        return String(characters.shuffled())
    }

    /// The family this device is joining; its music folder is used instead of asking.
    private var joiningFamily: FamilyInfo?

    /// A member's device: reach the family's server and ask for the password.
    public func joinFamilyServer(_ info: FamilyInfo) async {
        guard info.isReachable else { return }
        joiningFamily = info
        do {
            select(DiscoveredServer(name: info.serverName, baseURL: try familyURL(info), model: nil))
        } catch {
            signInError = error.localizedDescription
        }
    }

    /// The family's server as the owner reaches it.
    private func familyURL(_ info: FamilyInfo) throws -> URL {
        guard let address = info.address, let url = URL(string: address) else { throw SynologyError.invalidAddress }
        return url
    }

    /// Reads the active profile's preferences.
    public func applyProfileSettings() {
        guard let settings = profiles?.state.settings else { return }
        if let value = StreamQuality(rawValue: settings.quality), value != quality { quality = value }
        if let value = Appearance(rawValue: settings.appearance), value != appearance { appearance = value }
        if settings.gapless != gapless { gapless = settings.gapless }
    }

    /// Subtitle under the Library title: scan progress while indexing, otherwise when the folder was last read.
    public var librarySubtitle: String {
        if isScanning { return isDemo ? "Updating…" : (indexer.statusText ?? "Updating…") }
        guard library.catalogue.indexedAt > .distantPast else { return "" }
        let date = library.catalogue.indexedAt
        if Date.now.timeIntervalSince(date) < 60 { return "Updated just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return "Updated \(formatter.localizedString(for: date, relativeTo: .now))"
    }

    /// When the folder was last read: the time today or yesterday, otherwise the date and time.
    public var lastScanText: String {
        if isScanning { return isDemo ? "Scanning…" : (indexer.statusText ?? "Scanning…") }
        let date = library.catalogue.indexedAt
        guard date > .distantPast else { return "Never" }
        let time = date.formatted(date: .omitted, time: .shortened)
        let calendar = Calendar.current
        if calendar.isDateInToday(date) { return "Today at \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday at \(time)" }
        return date.formatted(.dateTime.day().month(.abbreviated)) + " at " + time
    }

    private func loadSettings() {
        if defaults.object(forKey: "watchFolder") != nil { watchFolder = defaults.bool(forKey: "watchFolder") }
    }
}
