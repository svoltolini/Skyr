import BackgroundTasks
import CarPlay
import SkyrCore
import SkyrShared
import CloudKit
import SwiftUI
import UIKit

/// Receives the wake-up for background downloads, silent pushes from iCloud, and hands scenes to
/// `SceneDelegate` so family invitation links reach the app.
final class AppDelegate: NSObject, UIApplicationDelegate {
    static var cloud: CloudSync?
    static var model: AppModel?
    /// The car's scene drives the same library, player and profiles as the phone's.
    static var library: LibraryStore?
    static var player: PlayerModel?
    static var profiles: ProfileStore?
    static let indexTaskID = "com.samuelvoltolini.skyr.index"

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Silent pushes only; no permission prompt.
        application.registerForRemoteNotifications()
        // A scan interrupted by the phone locking carries on here when the system gives the app time.
        // The scheduler calls this on its own queue: the closure must not be tied to the main actor,
        // and the task is handed across to it explicitly.
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.indexTaskID, using: nil) { @Sendable task in
            nonisolated(unsafe) let task = task
            Task { @MainActor in Self.continueScan(task) }
        }
        return true
    }

    /// Runs a background processing task: pick the scan up where it stopped, and finish cleanly on expiry.
    private static func continueScan(_ task: BGTask) {
        task.expirationHandler = { @Sendable in
            Task { @MainActor in
                Self.model?.indexer.cancel()
            }
        }
        Task { @MainActor in
            guard let model else { task.setTaskCompleted(success: false); return }
            await model.waitForDrive(upTo: .seconds(20))
            guard model.stage == .ready, model.isConnected, !model.isDemo else { task.setTaskCompleted(success: false); return }
            DiagnosticsLog.shared.record("Continuing the scan in the background")
            if !model.isScanning { model.refreshIfStale(olderThan: 0) }
            while model.isScanning { try? await Task.sleep(for: .seconds(2)) }
            task.setTaskCompleted(success: true)
        }
    }

    /// Asks for background time to finish a scan that was running when the app left the screen.
    static func scheduleScanContinuation() {
        let request = BGProcessingTaskRequest(identifier: indexTaskID)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        do {
            try BGTaskScheduler.shared.submit(request)
            DiagnosticsLog.shared.record("Asked to continue the scan in the background")
        } catch {
            DiagnosticsLog.shared.record("Background scan could not be scheduled: \(error.localizedDescription)")
        }
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if connectingSceneSession.role == .carTemplateApplication {
            let configuration = UISceneConfiguration(name: "CarPlay", sessionRole: connectingSceneSession.role)
            configuration.delegateClass = CarPlaySceneDelegate.self
            return configuration
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = SceneDelegate.self
        return configuration
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        DownloadManager.backgroundCompletionHandler = completionHandler
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return .noData }
        await Self.cloud?.refresh(reason: "iCloud push")
        return .newData
    }
}

/// Family invitation links open here, whether the app was running or not.
final class SceneDelegate: NSObject, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        if let metadata = connectionOptions.cloudKitShareMetadata {
            Task { await AppDelegate.cloud?.accept(metadata) }
        }
    }

    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { await AppDelegate.cloud?.accept(cloudKitShareMetadata) }
    }
}

@main
struct SkyrApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var profiles: ProfileStore
    @State private var cloud: CloudSync
    @State private var library: LibraryStore
    @State private var model: AppModel
    @State private var player: PlayerModel
    @State private var downloads: DownloadManager
    private let widgetFeed = WidgetFeed()
    private let watchBridge = WatchBridge()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let profiles = ProfileStore()
        let cloud = CloudSync()
        cloud.profiles = profiles
        profiles.sync = cloud
        AppDelegate.cloud = cloud
        let library = LibraryStore()
        library.profiles = profiles
        let model = AppModel(library: library)
        model.profiles = profiles
        AppDelegate.model = model
        AppDelegate.library = library
        AppDelegate.profiles = profiles
        let player = PlayerModel()
        AppDelegate.player = player
        let downloads = DownloadManager()
        downloads.driveIDProvider = { [library] in library.catalogue.driveID }
        // Downloads from before profiles existed belong to the first profile.
        if !UserDefaults.standard.bool(forKey: "downloads.ownersScoped"), let owner = profiles.owner {
            downloads.adoptLegacyOwners(into: owner.id)
            UserDefaults.standard.set(true, forKey: "downloads.ownersScoped")
        }
        downloads.activeProfileID = profiles.lastActiveID ?? profiles.owner?.id ?? "default"
        // Persist download membership changes to iCloud via the profile state.
        downloads.onMembershipChanged = { [profiles] driveID, albumIDs, playlistIDs in
            profiles.updateLibrary(driveID) { library in
                library.downloadedAlbums = albumIDs
                library.downloadedPlaylists = playlistIDs
            }
        }
        // A song on this iPhone plays from disk, whether or not the server is reachable.
        player.streamURLProvider = { [library, model, downloads] track in
            downloads.localURL(for: track) ?? library.streamURL(for: track, quality: model.quality)
        }
        player.albumProvider = { [library] track in library.album(for: track) }
        player.allowsSimulation = { [library] in library.isDemo }
        player.didStartAlbum = { [library] album in library.notePlayed(album) }
        player.didStartTrack = { [library] track in library.notePlayed(track) }
        _profiles = State(initialValue: profiles)
        _cloud = State(initialValue: cloud)
        _library = State(initialValue: library)
        _model = State(initialValue: model)
        _player = State(initialValue: player)
        _downloads = State(initialValue: downloads)
        // A profile opening loads its data everywhere; switching away stops the music first.
        profiles.onActivate = { [library, model, player, downloads, widgetFeed, profiles] profile in
            downloads.activeProfileID = profile.id
            library.loadProfileState()
            // Restore download membership from iCloud sync state (files will re-fetch from NAS if needed).
            let driveID = library.catalogue.driveID
            let state = profiles.libraryState(for: driveID)
            downloads.restoreDownloadMembership(albums: state.downloadedAlbums, playlists: state.downloadedPlaylists, driveID: driveID)
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
            widgetFeed.refresh()
        }
        profiles.onDeactivate = { [player, library, downloads, widgetFeed, watchBridge] in
            player.stop()
            downloads.activeProfileID = "locked"
            library.loadProfileState()
            widgetFeed.refresh()
            watchBridge.revoke()
        }
        // The document changed on another device: show it.
        profiles.onRemoteState = { [library, model, player, profiles, downloads, widgetFeed] in
            library.loadProfileState()
            // Restore download membership that may have synced from another device.
            let driveID = library.catalogue.driveID
            let state = profiles.libraryState(for: driveID)
            downloads.restoreDownloadMembership(albums: state.downloadedAlbums, playlists: state.downloadedPlaylists, driveID: driveID)
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
            widgetFeed.refresh()
        }
        cloud.familyInfoProvider = { [model] in model.familyInfo }
        cloud.onFamilyInfo = { [model] info in model.familyArrived(info) }
        model.onFamilyAccessChanged = { [cloud] in Task { await cloud.refresh(reason: "family access changed") } }
        player.settingsChanged = { [profiles] repeatMode, shuffle in
            profiles.updateSettings {
                $0.repeatMode = repeatMode.rawValue
                $0.shuffle = shuffle
            }
        }
        profiles.openAutomaticallyIfPossible()
        widgetFeed.start(library: library, player: player, downloads: downloads, profiles: profiles)
        cloud.start()
        // A paired Apple Watch gets the active profile's playlists and its own way into the server.
        watchBridge.provider = { [library, model, profiles] in
            guard model.stage == .ready, let active = profiles.active else { return nil }
            let profileName = active.name
            let catalogue = library.watchCatalogue(serverName: model.connection?.name ?? "Skyr", profileName: profileName)
            return (catalogue, model.watchCredentials())
        }
        // Play tapped on a widget cover: the system performs the intent inside the app, in the
        // background when it has to launch it for that.
        PlaybackIntentBridge.handler = { [library, player, model, downloads, widgetFeed, profiles] albumID in
            guard let sessionID = profiles.sessionID, let album = library.album(id: albumID) else { return }
            let driveID = library.catalogue.driveID
            let command = player.beginDeferredPlaybackCommand()
            if downloads.state(for: downloads.owner(for: album)) != .downloaded {
                await model.waitForDrive(upTo: .seconds(8))
            }
            guard !Task.isCancelled, profiles.sessionID == sessionID, library.catalogue.driveID == driveID,
                  player.commandRevision == command else { return }
            if player.album?.id == album.id, player.hasTrack {
                player.togglePlayPause()
            } else {
                player.play(album: album)
            }
            widgetFeed.refresh()
        }
        // Development shortcut: `--sample-library` opens the built-in catalogue without a server.
        if ProcessInfo.processInfo.arguments.contains("--sample-library") {
            model.useSampleLibrary()
            model.openLibrary()
        }
    }

    @State private var scanAliveTask: UIBackgroundTaskIdentifier = .invalid

    /// The half minute iOS grants after the app leaves the screen, spent finishing the current batch.
    private func keepScanAlive() {
        guard scanAliveTask == .invalid else { return }
        scanAliveTask = UIApplication.shared.beginBackgroundTask(withName: "scan") { endScanAliveTask() }
    }

    private func endScanAliveTask() {
        guard scanAliveTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(scanAliveTask)
        scanAliveTask = .invalid
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .reauthenticationSheet()
                .downloadErrorAlert()
                .profileSaveErrorAlert()
                .scrollIndicators(.hidden)
                .onOpenURL { url in
                    // Something tapped on a Home Screen widget.
                    switch WidgetLink.destination(from: url) {
                    case .album(let id):
                        if let album = library.album(id: id) { model.showAlbum(album) }
                    case .playlist(let id):
                        if let playlist = library.playlist(id: id) { model.showPlaylist(playlist) }
                    case .tab(let name):
                        model.showTab(named: name)
                    case nil:
                        break
                    }
                }
                .environment(model)
                .environment(library)
                .environment(player)
                .environment(downloads)
                .environment(profiles)
                .environment(cloud)
                .preferredColorScheme(model.appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(phase)
                    if phase == .active || phase == .background { watchBridge.sync() }
                    if phase == .active { Task { await cloud.refresh(reason: "foreground") } }
                    if phase == .background {
                        profiles.flushSave()
                        if model.isScanning {
                            keepScanAlive()
                            AppDelegate.scheduleScanContinuation()
                        }
                    }
                }
                // A long scan would stop the moment the phone locked; the screen stays on until it is done.
                .onChange(of: model.isScanning, initial: true) { _, scanning in
                    UIApplication.shared.isIdleTimerDisabled = scanning && model.keepsScreenOnWhileScanning
                    if !scanning { endScanAliveTask() }
                }
                .onChange(of: model.keepsScreenOnWhileScanning) { _, keeps in
                    UIApplication.shared.isIdleTimerDisabled = keeps && model.isScanning
                }
                .onChange(of: library.playlists) { watchBridge.sync() }
                .onChange(of: model.stage) { watchBridge.sync() }
        }
    }
}
