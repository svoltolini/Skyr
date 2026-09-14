import SkyrCore
import SwiftUI
import WatchKit

@main
struct SkyrWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) private var delegate
    @State private var store = WatchStore()
    @State private var player = WatchPlayer()

    var body: some Scene {
        WindowGroup {
            WatchRootView()
                .environment(store)
                .environment(WatchDownloads.shared)
                .environment(player)
                .task {
                    // Development shortcut: `--sample-library` shows the demo playlists without a phone.
                    if ProcessInfo.processInfo.arguments.contains("--sample-library") {
                        store.loadSample()
                    }
                }
        }
    }
}

/// Wakes the download session back up when the system relaunches the app for finished transfers.
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let refresh = task as? WKURLSessionRefreshBackgroundTask {
                WatchDownloads.shared.reconnect(identifier: refresh.sessionIdentifier) {
                    refresh.setTaskCompletedWithSnapshot(false)
                }
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
    }
}
