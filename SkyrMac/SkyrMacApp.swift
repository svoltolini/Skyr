import AppKit
import CloudKit
import SkyrCore
import SwiftUI

/// Silent iCloud pushes and family invitation links. Playback keys stay in the library views.
final class MacAppDelegate: NSObject, NSApplicationDelegate {
    static var cloud: CloudSync?
    static var player: PlayerModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Silent pushes only; no permission prompt.
        NSApplication.shared.registerForRemoteNotifications()
    }

    /// Closing the window leaves the music playing; the Dock icon brings the window back.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func application(_ application: NSApplication, userDidAcceptCloudKitShareWith metadata: CKShare.Metadata) {
        Task { await Self.cloud?.accept(metadata) }
    }

    func application(_ application: NSApplication, didReceiveRemoteNotification userInfo: [String: Any]) {
        guard CKNotification(fromRemoteNotificationDictionary: userInfo) != nil else { return }
        Task { await Self.cloud?.refresh(reason: "iCloud push") }
    }
}

@main
struct SkyrMacApp: App {
    @NSApplicationDelegateAdaptor(MacAppDelegate.self) private var appDelegate
    @State private var profiles: ProfileStore
    @State private var cloud: CloudSync
    @State private var library: LibraryStore
    @State private var model: AppModel
    @State private var player: PlayerModel
    @State private var downloads: DownloadManager
    @State private var navigation = MacNavigation()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let profiles = ProfileStore()
        let cloud = CloudSync()
        cloud.profiles = profiles
        profiles.sync = cloud
        MacAppDelegate.cloud = cloud
        let library = LibraryStore()
        library.profiles = profiles
        let model = AppModel(library: library)
        model.profiles = profiles
        let player = PlayerModel()
        MacAppDelegate.player = player
        let downloads = DownloadManager()
        downloads.driveIDProvider = { [library] in library.catalogue.driveID }
        if !UserDefaults.standard.bool(forKey: "downloads.ownersScoped"), let owner = profiles.owner {
            downloads.adoptLegacyOwners(into: owner.id)
            UserDefaults.standard.set(true, forKey: "downloads.ownersScoped")
        }
        downloads.activeProfileID = profiles.lastActiveID ?? profiles.owner?.id ?? "default"
        // A song on this Mac plays from disk, whether or not the server is reachable.
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
        // Development shortcut: `--sample-library` opens the built-in catalogue without a server.
        if ProcessInfo.processInfo.arguments.contains("--sample-library") {
            model.useSampleLibrary()
            model.openLibrary()
        }
    }

    var body: some Scene {
        Window("Skyr", id: "main") {
            wired(MacRootView().reauthenticationSheet().downloadErrorAlert().profileSaveErrorAlert())
                .onAppear { MacSetupSnapshots.runIfRequested(model: model) }
                .onChange(of: MacNavigationScope(profileID: profiles.activeID, sessionID: profiles.sessionID, sourceID: library.catalogue.driveID), initial: true) { _, scope in
                    navigation.synchronizeScope(profileID: scope.profileID, sessionID: scope.sessionID, sourceID: scope.sourceID)
                    model.albumToOpen = nil
                    model.playlistToOpen = nil
                }
                .onChange(of: scenePhase) { _, phase in
                    model.scenePhaseChanged(phase)
                    if phase == .active { Task { await cloud.refresh(reason: "foreground") } }
                    if phase == .background { profiles.flushSave() }
                }
        }
        .defaultSize(width: 1240, height: 800)
        // The window follows its content: fixed while the setup assistant is up, free afterwards.
        .windowResizability(.contentMinSize)
        .windowToolbarStyle(.unified)
        .commands {
            MacCommands(navigation: navigation, player: player, model: model)
        }

        Settings {
            wired(MacSettingsView().profileSaveErrorAlert())
                .frame(minWidth: 760, idealWidth: 820, minHeight: 560, idealHeight: 620)
        }
    }

    /// Every scene sees the same stores.
    private func wired<Content: View>(_ content: Content) -> some View {
        content
            .environment(model)
            .environment(library)
            .environment(player)
            .environment(downloads)
            .environment(profiles)
            .environment(cloud)
            .environment(navigation)
            .preferredColorScheme(model.appearance.colorScheme)
    }
}
