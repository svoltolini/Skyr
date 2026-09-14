import CloudKit
import SkyrCore
import SwiftUI

/// Inviting the family: the owner in person, and the link that lets people in. Replaces the
/// system sharing sheet, which showed a document icon and an anonymous "(Owner)".
struct InviteSheet: View {
    let share: CKShare
    @Environment(ProfileStore.self) private var profiles
    @Environment(CloudSync.self) private var cloud
    @Environment(\.dismiss) private var dismiss
    @State private var copied = false

    private var title: String { cloud.familyTitle }

    var body: some View {
        NavigationStack {
            Group {
                #if os(tvOS)
                ScrollView {
                    VStack(spacing: 28) {
                        VStack(spacing: 14) {
                            if let owner = profiles.owner {
                                ProfileAvatarView(profile: owner, size: 96)
                            }
                            Text(title)
                                .font(.title2.weight(.bold))
                                .kerning(-0.3)
                            Text("Everyone who joins gets their own profile, favourites and playlists, and listens from your music folder.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12)
                        }
                        .padding(.top, 16)

                        #if os(tvOS)
                        SettingsGroup(footer: "Invitations are sent from your iPhone or Mac, where the link can be shared.") {
                            SettingsRow(symbol: "iphone", tint: .blue, title: "Invite from your iPhone or Mac") {
                                EmptyView()
                            }
                        }
                        #else
                        if let url = share.url {
                            SettingsGroup(footer: "Anyone with the link joins from their own Apple Account, in any country; they don't need to be in your Family Sharing group. They install Skyr first, then open the link. If it opens in their browser instead, they paste it into Skyr under Have an invitation link. Up to five people can join, and you can stop sharing at any time from Family.") {
                                ShareLink(
                                    item: url,
                                    subject: Text("Join \(title) on Skyr"),
                                    message: Text("Install Skyr on your iPhone, iPad or Mac, then open this link to join \(title) and listen to our music. If it opens in your browser, paste it into Skyr under “Have an invitation link?”.")
                                ) {
                                    HStack(spacing: 14) {
                                        SettingsIcon(symbol: "square.and.arrow.up", tint: .blue)
                                        Text("Send Invitation")
                                            .foregroundStyle(Color.accentColor)
                                        Spacer(minLength: 0)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 13)
                                    .frame(minHeight: 58)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(RowPressStyle())
                                SettingsButtonRow(symbol: copied ? "checkmark" : "link", tint: .gray, title: copied ? "Link Copied" : "Copy Link") {
                                    Clipboard.copy(url)
                                    withAnimation(.snappy) { copied = true }
                                }
                            }
                        } else {
                            SettingsGroup(footer: "The invitation link is still being prepared. Close this and try again in a moment.") {
                                SettingsRow(symbol: "link", tint: .gray, title: "Preparing link…") {
                                    ProgressView()
                                }
                            }
                        }
                        #endif
                    }
                    .padding(.horizontal, 20)
                    .padding(.bottom, 40)
                }
                .background(Palette.paper)
                #else
                Form {
                    Section {
                        HStack {
                            if let owner = profiles.owner { ProfileAvatarView(profile: owner, size: 44) }
                            Text(title).font(.headline)
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("Your family")
                    } footer: {
                        Text("Everyone who joins gets their own profile, favourites and playlists, and listens from your music folder.")
                    }
                    if let url = share.url {
                        Section {
                            ShareLink(
                                item: url,
                                subject: Text("Join \(title) on Skyr"),
                                message: Text("Install Skyr on your iPhone, iPad or Mac, then open this link to join \(title) and listen to our music. If it opens in your browser, paste it into Skyr under “Have an invitation link?”.")
                            ) {
                                Label("Send Invitation", systemImage: "square.and.arrow.up")
                            }
                            Button(copied ? "Link Copied" : "Copy Link", systemImage: copied ? "checkmark" : "link") {
                                Clipboard.copy(url)
                                copied = true
                            }
                        } header: {
                            Text("Invitation link")
                        } footer: {
                            Text("Anyone with the link joins from their own Apple Account, in any country; they don't need to be in your Family Sharing group. They install Skyr first, then open the link. If it opens in their browser instead, they paste it into Skyr under Have an invitation link. Up to five people can join, and you can stop sharing at any time from Family.")
                        }
                    } else {
                        Section {
                            ProgressView("Preparing link…")
                        } footer: {
                            Text("The invitation link is still being prepared. Close this and try again in a moment.")
                        }
                    }
                }
                .groupedForm()
                #endif
            }
            .navigationTitle("Invite")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 500, minHeight: 420, idealHeight: 520)
        #endif
    }
}
