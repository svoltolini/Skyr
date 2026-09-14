import SwiftUI
import WidgetKit

@main
struct SkyrWidgetsBundle: WidgetBundle {
    var body: some Widget {
        SkyrHomeWidget()
        RediscoverWidget()
        DownloadsWidget()
        PlaylistsWidget()
        DownloadLiveActivity()
    }
}
