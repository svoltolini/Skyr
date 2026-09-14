import CloudKit
import SkyrCore
import SwiftUI
import UIKit

/// Silent iCloud pushes keep the television's profiles and playlists current.
final class TVAppDelegate: NSObject, UIApplicationDelegate {
    static var cloud: CloudSync?

    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didReceiveRemoteNotification userInfo: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return .noData }
        await Self.cloud?.refresh(reason: "iCloud push")
        return .newData
    }
}

@main
struct SkyrTVApp: App {
    @UIApplicationDelegateAdaptor(TVAppDelegate.self) private var appDelegate
    @State private var profiles: ProfileStore
    @State private var cloud: CloudSync
    @State private var library: LibraryStore
    @State private var model: AppModel
    @State private var player: PlayerModel
    @State private var downloads: DownloadManager
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let profiles = ProfileStore()
        let cloud = CloudSync()
        cloud.profiles = profiles
        profiles.sync = cloud
        TVAppDelegate.cloud = cloud
        let library = LibraryStore()
        library.profiles = profiles
        let model = AppModel(library: library)
        model.profiles = profiles
        let player = PlayerModel()
        // Nothing is kept on a television; the manager only exists so the shared screens have one.
        let downloads = DownloadManager()
        downloads.driveIDProvider = { [library] in library.catalogue.driveID }
        downloads.activeProfileID = profiles.lastActiveID ?? profiles.owner?.id ?? "default"
        player.streamURLProvider = { [library, model] track in library.streamURL(for: track, quality: model.quality) }
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
        profiles.onActivate = { [library, model, player, downloads] profile in
            downloads.activeProfileID = profile.id
            library.loadProfileState()
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
        }
        profiles.onDeactivate = { [player, library, downloads] in
            player.stop()
            downloads.activeProfileID = "locked"
            library.loadProfileState()
        }
        profiles.onRemoteState = { [library, model, player, profiles] in
            library.loadProfileState()
            model.applyProfileSettings()
            let settings = profiles.state.settings
            player.applySettings(repeatMode: PlayerModel.RepeatMode(rawValue: settings.repeatMode) ?? .off, shuffle: settings.shuffle)
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
        cloud.start()
        // Development shortcuts: the sample catalogue, a locked picker, and something playing.
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--sample-library") {
            model.useSampleLibrary()
            model.openLibrary()
        }
        if arguments.contains("--locked") { profiles.lock() }
    }

    var body: some Scene {
        WindowGroup {
            TVRootView()
                .reauthenticationSheet()
                .profileSaveErrorAlert()
                .environment(model)
                .environment(library)
                .environment(player)
                .environment(downloads)
                .environment(profiles)
                .environment(cloud)
                .preferredColorScheme(model.appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(phase)
                    if phase == .active { Task { await cloud.refresh(reason: "foreground") } }
                    if phase == .background { profiles.flushSave() }
                }
        }
    }
}
