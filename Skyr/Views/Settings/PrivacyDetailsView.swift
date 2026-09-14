import SwiftUI

/// Available offline, including before a person connects their library.
struct PrivacyDetailsView: View {
    private let sections: [(title: String, paragraphs: [String])] = [
        ("Your music", [
            "Skyr reads music, tags and covers from the NAS you connect. Music streams directly from your NAS or plays from downloads on your device. Skyr does not upload your music files to a Skyr service.",
            "Your NAS receives the sign-in details and file requests needed to connect and play music. Its administrator controls the server and its logs. Skyr saves your personal NAS password in the device Keychain."
        ]),
        ("Optional Apple artwork", [
            "Online artwork lookup is off until you enable it on this device. When enabled, Skyr can send an album's artist and title to Apple's iTunes Search service to find a missing or replacement cover, then download the matching image from Apple's artwork service.",
            "Apple receives those search terms and the network information needed for the requests, including your IP address. The artwork request does not include your music files, NAS password, server address or Skyr profile name.",
            "You can turn lookup off in Settings → Privacy. Skyr cancels its active lookups and stops new ones; it cannot recall requests already received by Apple. Covers already saved on the device remain available. Embedded and NAS-folder covers continue to work."
        ]),
        ("iCloud and family sharing", [
            "When iCloud is available, Skyr syncs profile names, chosen profile photos, favourites, playlists, recent plays, searches and settings through Apple's CloudKit service. It also syncs the information needed to reconcile your changes between devices.",
            "People with your family invitation link can join and receive shared profiles and server details. Skyr shares the NAS credentials you choose for Family Access, with the password in an encrypted CloudKit field. Use a separate read-only NAS account for your family.",
            "A profile PIN or biometric unlock controls access inside Skyr. Family sharing and the permissions on your NAS determine who can receive the shared library information."
        ]),
        ("Your devices", [
            "Skyr stores its catalogue, preferences, covers and downloads on your devices. Downloads are copies: removing them in Skyr does not delete the original music on your NAS. Apple TV may clear cached data to recover space.",
            "The paired Watch can receive playlists, covers and your current NAS address, account and password from your iPhone, then download music from the NAS. The password is saved in the Watch Keychain. It does not perform its own online artwork search. Widgets, Now Playing, AirPlay and CarPlay use the information needed to show and control playback.",
            "Face ID and Touch ID are handled by the operating system. Skyr receives an authentication result, not your biometric data."
        ]),
        ("Diagnostics and choices", [
            "Skyr includes no advertising or third-party analytics SDK. Skyr does not automatically send its diagnostic log to the developer. It may be included in device backups or shared if you copy it. The log can contain profile names, server details and error information. You can clear it from Diagnostics.",
            "Apple handles App Store and TestFlight services under its own privacy terms and your Apple settings. TestFlight feedback or crash reports that you share through Apple may be available to the developer.",
            "You can remove downloads, edit or delete eligible profiles, clear local diagnostics and turn off online artwork in Skyr. Synced edits and deletions require a working iCloud connection. Copies already downloaded by another family device, and backups managed by Apple or your NAS, have their own retention."
        ])
    ]

    var body: some View {
        List {
            ForEach(sections, id: \.title) { section in
                Section(section.title) {
                    ForEach(section.paragraphs, id: \.self) { paragraph in
                        Text(paragraph)
                            .font(.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .selectableText()
                            #if os(tvOS)
                            .focusable()
                            #endif
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle("Privacy Details")
        .inlineTitle()
    }
}
