import SkyrCore
import SwiftUI

/// Opens the same offline privacy information from setup and TV Settings.
struct PrivacyDetailsButton: View {
    @State private var showsPrivacyDetails = false

    var body: some View {
        Button("Privacy Details") { showsPrivacyDetails = true }
            .buttonStyle(.borderless)
            .font(.callout)
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
        #if os(tvOS)
        .skyrBackground(Palette.neutralTint)
        #elseif os(macOS)
        .frame(minWidth: 480, idealWidth: 560, minHeight: 440, idealHeight: 640)
        #endif
        .sheetDetents([.large])
    }
}
