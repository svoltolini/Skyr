import SkyrCore
import SwiftUI

/// The one-time DSM setup that lets every device, at home or away, reach the NAS at one name.
struct RemoteAccessGuide: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    Text("Done once in DSM, this gives your NAS a name that works from anywhere. Every device you own, and everyone in your family, then connects to that one name without any further setup.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)

                    SettingsGroup(title: "1. Give the NAS a name", footer: "Synology's own DDNS is free and needs no account beyond the one you already have.") {
                        InstructionRow(number: 1, text: "In DSM, open Control Panel, then External Access, then the DDNS tab, and choose Add.")
                        InstructionRow(number: 2, text: "Pick Synology as the provider and choose a hostname, for example myds.synology.me.")
                        InstructionRow(number: 3, text: "Tick “Get a certificate from Let's Encrypt and set it as default”, then OK.")
                    }

                    SettingsGroup(title: "2. Open the door", footer: "Only port 5001 is needed. It carries DSM's encrypted connection and nothing else.") {
                        InstructionRow(number: 1, text: "Still under External Access, open the Router Configuration tab and choose Create.")
                        InstructionRow(number: 2, text: "Pick Built-in application, tick DSM with HTTPS on port 5001, and save. DSM asks your router to forward the port.")
                        InstructionRow(number: 3, text: "If your router refuses, add the rule in its own settings: TCP 5001 to the NAS's local address.")
                    }

                    SettingsGroup(title: "3. Check the certificate", footer: "Without a valid certificate the app refuses the connection, as a browser would.") {
                        InstructionRow(number: 1, text: "Open Control Panel, then Security, then the Certificate tab.")
                        InstructionRow(number: 2, text: "Your new name should be listed with a Let's Encrypt certificate marked as default. If not, choose Add and request one for it.")
                    }

                    SettingsGroup(title: "4. Connect", footer: "If it cannot connect, the app says whether the port or the certificate is the problem.") {
                        InstructionRow(number: 1, text: "Back in Skyr, enter the name, for example myds.synology.me, and sign in with your DSM account.")
                        InstructionRow(number: 2, text: "Your family and your other devices pick the name up through iCloud on their own.")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.top, 8)
                .padding(.bottom, 40)
            }
            .background(Palette.paper)
            .navigationTitle("Reach your NAS from anywhere")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .sheetDetents([.large])
    }
}
