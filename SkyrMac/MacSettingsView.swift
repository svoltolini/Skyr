import SwiftUI

/// A desktop Settings window: categories stay visible while each pane owns its drill-down pages.
struct MacSettingsView: View {
    @State private var selection: SettingsCategory? = .general
    @Namespace private var artworkNamespace

    var body: some View {
        NavigationSplitView {
            List(SettingsCategory.allCases, selection: $selection) { category in
                Label(category.rawValue, systemImage: category.symbol)
                    .tag(category)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 230)
            .navigationTitle("Settings")
        } detail: {
            NavigationStack {
                SettingsView(category: selection ?? .general)
                    .libraryDestinations()
            }
            // Selecting another category starts its own pane; resizing never changes this identity.
            .id(selection)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(\.artworkNamespace, artworkNamespace)
    }
}
