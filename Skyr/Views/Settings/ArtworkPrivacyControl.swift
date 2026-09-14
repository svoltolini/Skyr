import SkyrCore
import SwiftUI

/// The same explicit device choice in setup and Settings; no profile permission can enable it.
struct ArtworkPrivacyControl: View {
    @Environment(AppModel.self) private var model
    @State private var showsPrivacyDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Look up artwork with Apple", isOn: Binding(
                get: { model.artworkLookup.isEnabled },
                set: { model.artworkLookup.setEnabled($0) }
            ))
            .accessibilityHint("Optional. Sends artist and album names to Apple from this device.")
            if let error = model.artworkLookup.preferenceError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("Privacy details") { showsPrivacyDetails = true }
                .buttonStyle(.borderless)
                .font(.callout)
        }
        .multilineTextAlignment(.leading)
        #if os(tvOS)
        .fullScreenCover(isPresented: $showsPrivacyDetails) { privacyDetails }
        #else
        .sheet(isPresented: $showsPrivacyDetails) {
            privacyDetails
        }
        #endif
    }

    private var privacyDetails: some View {
        NavigationStack {
            PrivacyDetailsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { showsPrivacyDetails = false }
                    }
                }
        }
        .multilineTextAlignment(.leading)
        .skyrBackground(Palette.neutralTint)
        .sheetDetents([.large])
    }
}
