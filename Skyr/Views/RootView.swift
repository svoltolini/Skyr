import SkyrCore
import SwiftUI

#if os(iOS)
/// Switches between the first-run connection flow and the main tabbed app.
struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(ProfileStore.self) private var profiles

    var body: some View {
        ZStack {
            if model.stage == .ready {
                MainTabView()
                    .transition(.blurReplace)
            } else {
                ConnectFlowView()
                    .transition(.blurReplace)
            }
            if model.stage == .ready, profiles.isLocked {
                ProfilePickerView()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        .animation(.easeInOut(duration: 0.5), value: model.stage == .ready)
        .animation(.easeInOut(duration: 0.35), value: profiles.isLocked)
    }
}
#endif

/// Welcome → server discovery → sign in → indexing, driven by the model's stage.
struct ConnectFlowView: View {
    @Environment(AppModel.self) private var model
    @State private var path: [AppModel.Stage] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            WelcomeView()
                .navigationDestination(for: AppModel.Stage.self) { stage in
                    switch stage {
                    case .indexing:
                        IndexingView()
                    case .chooseFolder:
                        FolderPickerView(mode: .onboarding)
                    default:
                        ServerDiscoveryView()
                    }
                }
        }
        .sheet(item: $model.pendingServer) { server in
            LoginSheet(server: server)
        }
        .onChange(of: model.stage, initial: true) { _, stage in
            let target: [AppModel.Stage] = switch stage {
            case .welcome: []
            case .discovering: [.discovering]
            case .chooseFolder: [.discovering, .chooseFolder]
            case .indexing: model.isDemo ? [.discovering, .indexing] : [.discovering, .chooseFolder, .indexing]
            case .ready: path
            }
            if path != target { path = target }
        }
        .onChange(of: path) { _, path in
            if path.isEmpty, model.stage == .discovering {
                model.stage = .welcome
                model.discovery.stop()
            } else if path == [.discovering], model.stage == .chooseFolder {
                model.cancelFolderChoice()
            }
        }
    }
}
