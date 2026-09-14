import SkyrCore
import SwiftUI

/// Settings tab: its own navigation stack so Downloads and albums can be pushed from it.
struct SettingsTabView: View {
    @Namespace private var artworkNamespace

    var body: some View {
        NavigationStack {
            SettingsView()
                .libraryDestinations()
        }
        .environment(\.artworkNamespace, artworkNamespace)
    }
}

/// Profile, server, library, playback, downloads and appearance, as airy groups on the paper.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(PlayerModel.self) private var player
    @Environment(DownloadManager.self) private var downloads
    @Environment(ProfileStore.self) private var profiles
    @Environment(CloudSync.self) private var cloud
    @State private var isConfirmingSignOut = false
    @State private var versionTaps = 0
    @State private var isShowingDiagnostics = false
    @State private var hasUnseenNotes = Release.hasUnseenNotes
    @State private var isRecoveringLegacyLibrary = false

    private var permissions: Permissions { Permissions(profiles: profiles, cloud: cloud) }

    var body: some View {
        @Bindable var model = model
        @Bindable var library = library
        ScrollView {
            VStack(spacing: 28) {
                profileCard

                SettingsGroup(title: "iCloud") {
                    NavigationLink {
                        FamilyView()
                    } label: {
                        SettingsRow(symbol: "person.2.fill", tint: .blue, title: "Family", subtitle: cloud.status.text) {
                            if cloud.isActive, !cloud.participants.isEmpty {
                                SettingsValue("\(cloud.participants.count)")
                            }
                            DisclosureChevron()
                        }
                    }
                    .buttonStyle(RowPressStyle())
                }

                SettingsGroup(title: "Server") {
                    SettingsRow(symbol: library.isDemo ? "shippingbox.fill" : "externaldrive.fill", tint: .indigo, title: model.serverTitle) {
                        Circle()
                            .fill(model.isConnected ? Color.green : Color.gray.opacity(0.5))
                            .frame(width: 8, height: 8)
                            .accessibilityLabel(model.isConnected ? "Connected" : "Offline")
                    }
                    if model.connection != nil, permissions.canManageServer {
                        NavigationLink {
                            FolderPickerView(mode: .settings)
                        } label: {
                            SettingsRow(symbol: "folder.fill", tint: .orange, title: "Music folder") {
                                SettingsValue(model.musicFolderLabel)
                                DisclosureChevron()
                            }
                        }
                        .buttonStyle(RowPressStyle())
                        SettingsButtonRow(symbol: "arrow.clockwise", tint: .blue, title: model.isReconnecting ? "Reconnecting…" : "Reconnect") {
                            Task { await model.reconnect() }
                        }
                        .disabled(model.isReconnecting)
                        if let error = model.signInError, !model.isReconnecting {
                            Text(error)
                                .font(.footnote)
                                .foregroundStyle(.red)
                                .padding(.horizontal, 16)
                                .padding(.vertical, 10)
                        }
                    }
                }

                if !model.legacyLibraryRecoveries.isEmpty {
                    SettingsGroup(title: "Saved library", footer: "An earlier version kept favourites, playlists and history under the server name. Recover them into this connection after confirming the old server. Current edits are kept; older downloads need downloading again.") {
                        SettingsButtonRow(symbol: "clock.arrow.circlepath", tint: .blue, title: "Recover saved library") {
                            isRecoveringLegacyLibrary = true
                        }
                    }
                }

                SettingsGroup(title: "Library", footer: model.watchFolder
                    ? "New music is picked up when you come back to the app and about once an hour while it's open."
                    : "The library only updates when you scan.") {
                    SettingsRow(symbol: "clock.arrow.circlepath", tint: .gray, title: "Last scan") {
                        SettingsValue(model.lastScanText)
                    }
                    SettingsRow(symbol: "square.stack.fill", tint: .purple, title: "Library") {
                        SettingsValue(library.isDemo ? "3,412 albums · 1.9 TB" : library.catalogue.summary)
                    }
                    if model.indexer.isEnriching {
                        SettingsRow(symbol: "text.magnifyingglass", tint: .gray, title: "Album details") {
                            SettingsValue("\(model.indexer.enrichedCount.formatted()) of \(model.indexer.enrichTotal.formatted())")
                        }
                    }
                    SettingsRow(symbol: "eye.fill", tint: .green, title: "Watch for changes") {
                        Toggle("Watch for changes", isOn: $model.watchFolder).labelsHidden()
                    }
                    #if os(iOS)
                    SettingsRow(symbol: "sun.max.fill", tint: .yellow, title: "Stay awake to scan") {
                        Toggle("Stay awake to scan", isOn: $model.keepsScreenOnWhileScanning)
                            .labelsHidden()
                    }
                    #endif
                    SettingsButtonRow(symbol: "arrow.triangle.2.circlepath", tint: .blue, title: model.isScanning ? "Scanning…" : "Scan now") {
                        model.rescan()
                    }
                    .disabled(model.isScanning)
                    SettingsRow(symbol: "parentheses", tint: .brown, title: "Clean album names") {
                        Toggle("Clean album names", isOn: $library.hidesBracketedTitleParts).labelsHidden()
                    }
                    NavigationLink {
                        GenreNamesView()
                    } label: {
                        SettingsRow(symbol: "tag.fill", tint: .pink, title: "Genre names") {
                            SettingsValue(library.genreRenames.isEmpty ? "None" : library.genreRenames.count.formatted())
                            DisclosureChevron()
                        }
                    }
                    .buttonStyle(RowPressStyle())
                }

                SettingsGroup(title: "Playback") {
                    SettingsRow(symbol: "waveform", tint: .mint, title: "Gapless playback") {
                        Toggle("Gapless playback", isOn: $model.gapless).labelsHidden()
                    }
                }

                #if !os(tvOS)
                SettingsGroup(title: "Downloads") {
                    NavigationLink(value: LibraryRoute.downloads) {
                        SettingsRow(symbol: "arrow.down.circle.fill", tint: .green, title: "On this \(Device.noun)") {
                            SettingsValue(ByteText.format(downloads.totalBytes))
                            DisclosureChevron()
                        }
                    }
                    .buttonStyle(RowPressStyle())
                }
                #endif

                SettingsGroup(title: "Appearance") {
                    SettingsRow(symbol: "circle.lefthalf.filled", tint: .gray, title: "Look") {
                        Picker("Look", selection: $model.appearance) {
                            ForEach(Appearance.allCases) { appearance in
                                Text(appearance == .auto ? "Automatic" : appearance.rawValue).tag(appearance)
                            }
                        }
                        .menuPicker()
                        .labelsHidden()
                        .tint(.secondary)
                    }
                }

                SettingsGroup(title: "About") {
                    NavigationLink {
                        ReleaseNotesView()
                    } label: {
                        SettingsRow(symbol: "sparkles", tint: .purple, title: "What's New") {
                            if hasUnseenNotes {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 8, height: 8)
                                    .accessibilityLabel("Unread")
                            }
                            DisclosureChevron()
                        }
                    }
                    .buttonStyle(RowPressStyle())
                    // Five taps on the version open the diagnostics log, kept out of sight.
                    SettingsRow(symbol: "info.circle.fill", tint: .gray, title: "Version") {
                        SettingsValue(Self.versionText)
                    }
                    .onTapGesture {
                        versionTaps += 1
                        if versionTaps >= 5 {
                            versionTaps = 0
                            isShowingDiagnostics = true
                        }
                    }
                }

                if permissions.canLeave {
                    SettingsGroup(footer: signOutFooter) {
                        SettingsButtonRow(symbol: "rectangle.portrait.and.arrow.right", tint: .red, title: library.isDemo ? "Leave sample library" : "Sign out", role: .destructive) {
                            isConfirmingSignOut = true
                        }
                    }
                } else {
                    Text("Skyr Music \(Self.versionText)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 40)
        }
        .skyrBackground(player.tint)
        .navigationTitle("Settings")
        .largeTitle()
        .navigationDestination(isPresented: $isShowingDiagnostics) { DiagnosticsView() }
        .sheet(isPresented: $isRecoveringLegacyLibrary) { LegacyLibraryRecoverySheet() }
        .onAppear { hasUnseenNotes = Release.hasUnseenNotes }
        .animation(.default, value: model.isScanning)
        .animation(.default, value: model.indexer.isEnriching)
        .confirmationDialog(library.isDemo ? "Leave the sample library?" : "Sign out of \(model.serverTitle)?", isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
            Button(library.isDemo ? "Leave" : "Sign out", role: .destructive) {
                player.pause()
                Task { await model.signOut() }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    /// Who is listening, with a way to switch and a way to manage everyone.
    private var profileCard: some View {
        SettingsGroup {
            NavigationLink {
                ManageProfilesView()
            } label: {
                HStack(spacing: 14) {
                    if let profile = profiles.active {
                        ProfileAvatarView(profile: profile, size: 56, isLocked: profile.isLocked)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(profile.name)
                                .font(.title3.weight(.semibold))
                                .lineLimit(1)
                            Text(profile.role == .owner ? "Owner" : "Member")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Button("Switch") {
                        profiles.lock()
                    }
                    .buttonStyle(.glass)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
                .contentShape(Rectangle())
            }
            .buttonStyle(RowPressStyle())
        }
    }

    private var signOutFooter: String {
        var lines: [String] = []
        if let connection = model.connection {
            lines.append("Signed in as \(connection.account). Signing out forgets the saved password and clears the cached library.")
        }
        lines.append("Skyr Music \(Self.versionText)")
        return lines.joined(separator: "\n")
    }

    private static var versionText: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
    }

    /// "on your network" → "On your network".
    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return text }
        return String(first).uppercased() + text.dropFirst()
    }
}

/// Shared by iPhone, iPad, Mac and TV. Only listening data is copied after a named-source confirmation.
private struct LegacyLibraryRecoverySheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var selected: LegacyLibraryRecovery?
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Choose the old server whose favourites, playlists and history belong to this connection. Your current edits and the original saved library are kept. Older downloads must be downloaded again.")
                        .font(.callout)
                }
                if let current = model.legacyLibraryRecoveries.first {
                    Section("Current connection") {
                        LabeledContent("Address", value: current.address)
                        LabeledContent("Account", value: current.account)
                    }
                    Section("Earlier libraries") {
                        ForEach(model.legacyLibraryRecoveries) { choice in
                            Button {
                                selected = choice
                                problem = nil
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(choice.legacySourceID)
                                    Text("\(choice.favouritesCount) favourites · \(choice.playlistsCount) playlists · \(choice.historyCount) history entries")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                } else {
                    Section { Text("No earlier libraries are waiting to be recovered for this connection. Reconnect to your server and finish scanning if needed.") }
                }
                if let problem {
                    Section { Text(problem).foregroundStyle(.red).font(.footnote) }
                }
            }
            .groupedForm()
            .navigationTitle("Recover saved library")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
            }
            .confirmationDialog("Recover this saved library?", isPresented: Binding(
                get: { selected != nil },
                set: { if !$0 { selected = nil } }
            ), titleVisibility: .visible, presenting: selected) { choice in
                Button("Recover saved library") {
                    problem = model.recoverLegacyLibrary(choice)
                    selected = nil
                    if problem == nil { dismiss() }
                }
                Button("Cancel", role: .cancel) { selected = nil }
            } message: { choice in
                Text("Copy saved listening data from \(choice.legacySourceID) to \(choice.address), signed in as \(choice.account). Existing edits stay in place. This does not transfer passwords or downloaded audio.")
            }
        }
        .sheetDetents([.medium, .large])
    }
}

// MARK: - Settings building blocks

/// A titled card of rows with hairlines between them, and an optional line of help under it.
struct SettingsGroup<Content: View>: View {
    var title: String? = nil
    var footer: String? = nil
    @ViewBuilder let content: () -> Content

    init(title: String? = nil, footer: String? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let title {
                Text(title.uppercased())
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .kerning(0.5)
                    .padding(.leading, 12)
            }
            Group(subviews: content()) { rows in
                VStack(spacing: 0) {
                    ForEach(rows.indices, id: \.self) { index in
                        rows[index]
                        if index < rows.count - 1 {
                            Divider().padding(.leading, 62)
                        }
                    }
                }
            }
            .background(Color.groupedCard, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            if let footer {
                Text(footer)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
            }
        }
    }
}

/// The coloured symbol tile at the start of a row.
struct SettingsIcon: View {
    let symbol: String
    let tint: Color

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 32, height: 32)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Icon, title, an optional second line, and whatever sits at the trailing edge.
struct SettingsRow<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let trailing: () -> Trailing

    init(symbol: String, tint: Color, title: String, subtitle: String? = nil, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: symbol, tint: tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) { trailing() }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
        .frame(minHeight: 58)
        .contentShape(Rectangle())
    }
}

/// A row that is a button, tinted or destructive.
struct SettingsButtonRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var role: ButtonRole? = nil
    let action: () -> Void

    init(symbol: String, tint: Color, title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.symbol = symbol
        self.tint = tint
        self.title = title
        self.role = role
        self.action = action
    }

    var body: some View {
        Button(role: role, action: action) {
            HStack(spacing: 14) {
                SettingsIcon(symbol: symbol, tint: tint)
                Text(title)
                    .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)
            .frame(minHeight: 58)
            .contentShape(Rectangle())
        }
        .buttonStyle(RowPressStyle())
    }
}

/// Secondary text at the trailing edge of a row.
struct SettingsValue: View {
    let text: String

    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}
