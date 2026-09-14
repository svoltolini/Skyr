import AppKit
import SkyrCore
import SwiftUI

/// The first run on the Mac, laid out the way a macOS assistant reads: a window of fixed size,
/// the steps down the left, the current step on the right, Back and the default action in the
/// lower corner. Every step drives the same model as the phone's flow; only the layout is the Mac's.
struct MacSetupView: View {
    static let size = CGSize(width: 840, height: 580)

    @Environment(AppModel.self) private var model

    enum Step: Int, CaseIterable, Identifiable {
        case welcome, server, signIn, folder, library

        var id: Int { rawValue }

        var title: String {
            switch self {
            case .welcome: "Welcome"
            case .server: "Server"
            case .signIn: "Sign In"
            case .folder: "Music Folder"
            case .library: "Library"
            }
        }
    }

    private var step: Step {
        switch model.stage {
        case .welcome: .welcome
        case .discovering: model.pendingServer == nil ? .server : .signIn
        case .chooseFolder: .folder
        case .indexing, .ready: .library
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SetupRail(current: step)
                .frame(width: 236)
            Divider()
            Group {
                switch step {
                case .welcome: MacWelcomeStep()
                case .server: MacServerStep()
                case .signIn: MacSignInStep()
                case .folder: MacFolderStep()
                case .library: MacLibraryStep()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .id(step)
            .transition(.opacity)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Palette.paper)
        .animation(.easeInOut(duration: 0.22), value: step)
        .bareWindow()
    }
}

// MARK: - Rail

/// Brand mark, the five steps with their state, and a line about privacy at the foot.
private struct SetupRail: View {
    let current: MacSetupView.Step
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandTile(size: 34)
                Text("Skyr")
                    .font(.title2.weight(.semibold))
            }
            .padding(.horizontal, 24)
            .padding(.top, 30)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(MacSetupView.Step.allCases) { step in
                    row(step)
                }
            }
            .padding(.horizontal, 14)
            .padding(.top, 34)
            Spacer()
            Text("Your music streams straight from your NAS.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.paper.mix(with: Palette.neutralTint, by: colorScheme == .dark ? 0.26 : 0.16))
    }

    private func row(_ step: MacSetupView.Step) -> some View {
        let isCurrent = step == current
        let isDone = step.rawValue < current.rawValue
        return HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(isCurrent || isDone ? Palette.ink : Palette.ink.opacity(0.1))
                    .frame(width: 22, height: 22)
                if isDone {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Palette.onInk)
                } else {
                    Text("\(step.rawValue + 1)")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(isCurrent ? Palette.onInk : .secondary)
                }
            }
            Text(step.title)
                .font(.body.weight(isCurrent ? .semibold : .regular))
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isCurrent ? Palette.ink.opacity(0.07) : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(step.title)\(isDone ? ", done" : isCurrent ? ", current step" : "")")
    }
}

/// The app icon's note on a white tile.
private struct BrandTile: View {
    var size: CGFloat = 34

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(.white)
            .frame(width: size, height: size)
            .shadow(color: .black.opacity(0.12), radius: 6, y: 3)
            .overlay {
                Image(systemName: "music.note")
                    .font(.system(size: size * 0.5, weight: .semibold))
                    .foregroundStyle(Palette.brand)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Page scaffold

/// A step's page: title, a line under it, the content, and the button row along the bottom.
private struct StepPage<Content: View, Buttons: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let content: () -> Content
    @ViewBuilder let buttons: () -> Buttons

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 26, weight: .semibold))
                .kerning(-0.5)
            if let subtitle {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 6)
            }
            content()
                .padding(.top, 24)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            HStack(spacing: 10) {
                buttons()
            }
            .controlSize(.large)
            .padding(.top, 16)
        }
        .padding(.horizontal, 34)
        .padding(.top, 34)
        .padding(.bottom, 22)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - Welcome

private struct MacWelcomeStep: View {
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    @State private var isJoiningWithLink = false

    var body: some View {
        StepPage(title: "Your library, from your NAS.", subtitle: "Skyr plays the music on the Synology you already own, straight from the server, on every screen in the house.") {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    ForEach(OnboardingPage.privacy) { page in
                        HStack(alignment: .top, spacing: 14) {
                            Image(systemName: symbol(for: page.id))
                                .font(.title3.weight(.medium))
                                .foregroundStyle(Palette.brand)
                                .frame(width: 26)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(page.title.replacingOccurrences(of: "\n", with: " "))
                                    .font(.headline)
                                Text(page.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                if page.id == 3 {
                                    ArtworkPrivacyControl()
                                        .padding(.top, 8)
                                }
                            }
                        }
                    }
                    if let family = cloud.family, family.isReachable {
                        familyNote(family)
                            .padding(.top, 6)
                    }
                }
                .frame(maxWidth: 500, alignment: .leading)
            }
        } buttons: {
            if cloud.family?.isReachable != true {
                Button("Join with a Link…") { isJoiningWithLink = true }
            }
            Spacer()
            if let family = cloud.family, family.isReachable {
                Button("Find Servers") { model.findServers() }
                if family.familyAccount != nil {
                    if model.signInError != nil, !model.isJoiningFamily {
                        Button("Try Again") { Task { await model.connectWithFamilyAccess(family) } }
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                    }
                } else {
                    Button("Join \(family.serverName)") { Task { await model.joinFamilyServer(family) } }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                Button("Continue") { model.findServers() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .sheet(isPresented: $isJoiningWithLink) {
            JoinWithLinkSheet()
        }
    }

    private func symbol(for page: Int) -> String {
        switch page {
        case 0: "externaldrive.fill"
        case 1: "key.fill"
        case 3: "photo"
        default: "person.2.fill"
        }
    }

    /// A family invitation reached this Mac through iCloud.
    private func familyNote(_ family: FamilyInfo) -> some View {
        HStack(spacing: 10) {
            if model.isJoiningFamily {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "person.2.fill").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(model.isJoiningFamily ? "Joining \(family.serverName)…" : "Your family's server, \(family.serverName), is shared with you.")
                    .font(.callout.weight(.medium))
                if let error = model.signInError, !model.isJoiningFamily {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .padding(12)
        .background(Palette.ink.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Server

private struct MacServerStep: View {
    @Environment(AppModel.self) private var model
    @State private var selection: DiscoveredServer.ID?
    @State private var address = ""
    @State private var isResolving = false
    @State private var error: String?
    @State private var isReadingGuide = false

    private var servers: [DiscoveredServer] { model.discovery.servers }

    var body: some View {
        StepPage(title: "Find your server", subtitle: "Synology servers on this network appear here. Away from home, enter the address you set up in DSM.") {
            VStack(alignment: .leading, spacing: 14) {
                List(servers, selection: $selection) { server in
                    HStack(spacing: 12) {
                        Image(systemName: "externaldrive.fill")
                            .foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(server.name).font(.body.weight(.medium))
                            Text(server.address).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .frame(height: 170)
                .overlay {
                    if servers.isEmpty {
                        HStack(spacing: 8) {
                            if model.discovery.isBrowsing { ProgressView().controlSize(.small) }
                            Text(model.discovery.isBrowsing ? "Looking for music servers…" : "No servers found on this network")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                HStack(spacing: 8) {
                    TextField("Address, such as myds.synology.me or 192.168.1.40", text: $address)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(connect)
                        .disabled(isResolving)
                    Button("Connect", action: connect)
                        .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
                    if isResolving { ProgressView().controlSize(.small) }
                }
                Text("HTTPS is the default. Tailscale addresses work when reachable from this Mac. For a NAS that only supports HTTP, enter its full http:// address and port, then review the connection before signing in.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                }
                Button("How to reach your NAS from anywhere…") { isReadingGuide = true }
                    .buttonStyle(.link)
                    .font(.callout)
            }
        } buttons: {
            Button("Back") {
                model.stage = .welcome
                model.discovery.stop()
            }
            Spacer()
            Button("Continue") {
                if let server = servers.first(where: { $0.id == selection }) { model.select(server) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(selection == nil)
        }
        .sheet(isPresented: $isReadingGuide) {
            RemoteAccessGuide()
        }
    }

    private func connect() {
        let entry = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, !isResolving else { return }
        isResolving = true
        error = nil
        Task {
            do {
                try await model.connect(to: entry)
            } catch {
                self.error = error.localizedDescription
            }
            isResolving = false
        }
    }
}

// MARK: - Sign in

private struct MacSignInStep: View {
    @Environment(AppModel.self) private var model
    @State private var account = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var remember = true
    @State private var httpAllowed = false
    @FocusState private var focus: Field?

    private enum Field { case account, password, otp }

    var body: some View {
        let server = model.pendingServer
        StepPage(title: "Sign in to \(server?.name ?? "your NAS")", subtitle: "Your DSM account. It is kept in this Mac's Keychain and sent only to your server; your music is read through File Station, so nothing is installed on the NAS.") {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 14) {
                GridRow {
                    label("Server")
                    Text(server.map { "\($0.name)  ·  \($0.address)" } ?? "")
                        .foregroundStyle(.secondary)
                }
                if let server {
                    GridRow {
                        Text("")
                        NASTransportChoice(url: server.baseURL, httpAllowed: $httpAllowed) {
                            guard let url = NASTransportSecurity.httpsAlternative(for: server.baseURL) else { return }
                            password = ""
                            otpCode = ""
                            model.select(DiscoveredServer(name: server.name, baseURL: url, model: server.model))
                        }
                        .disabled(model.isSigningIn)
                    }
                }
                GridRow {
                    label("Account")
                    TextField("", text: $account)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .focused($focus, equals: .account)
                        .onSubmit { focus = .password }
                }
                GridRow {
                    label("Password")
                    SecureField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 280)
                        .focused($focus, equals: .password)
                        .onSubmit { model.needsOTP ? focus = .otp : submit() }
                }
                if model.needsOTP {
                    GridRow {
                        label("Code")
                        TextField("Two-factor code", text: $otpCode)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 160)
                            .focused($focus, equals: .otp)
                            .onSubmit(submit)
                    }
                }
                GridRow {
                    Text("")
                    Toggle("Remember me on this Mac", isOn: $remember)
                }
                if let error = model.signInError {
                    GridRow {
                        Text("")
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        } buttons: {
            Button("Back") { model.cancelSignIn() }
                .disabled(model.isSigningIn)
            Spacer()
            if model.isSigningIn {
                ProgressView().controlSize(.small)
                    .padding(.trailing, 6)
            }
            Button("Sign In", action: submit)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(account.isEmpty || password.isEmpty || model.isSigningIn || !transportAllowed)
        }
        .animation(.easeInOut(duration: 0.2), value: model.needsOTP)
        .onAppear {
            httpAllowed = server.map { NASTransportSecurity.isAllowed($0.baseURL) } ?? false
            if let familyAccount = model.pendingFamilyAccount {
                account = familyAccount
                password = model.pendingFamilyPassword ?? ""
            } else if let connection = model.connection, let server, NASOrigin(url: connection.baseURL) == NASOrigin(url: server.baseURL) {
                account = connection.account
            }
            focus = account.isEmpty ? .account : .password
        }
        .onChange(of: server?.id) {
            account = model.pendingFamilyAccount ?? ""
            password = model.pendingFamilyPassword ?? ""
            otpCode = ""
            httpAllowed = model.pendingServer.map { NASTransportSecurity.isAllowed($0.baseURL) } ?? false
        }
    }

    private func label(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .gridColumnAlignment(.trailing)
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, transportAllowed else { return }
        Task { await model.signIn(account: account, password: password, otpCode: otpCode, remember: remember) }
    }

    private var transportAllowed: Bool {
        model.pendingServer.map { NASOrigin(url: $0.baseURL)?.isHTTPS == true || httpAllowed } ?? false
    }
}

// MARK: - Folder

/// A Finder-like browser: shared folders first, then folders inside the one opened. Double-click
/// or Open goes in; the default button chooses the folder currently open.
private struct MacFolderStep: View {
    @Environment(AppModel.self) private var model
    @State private var trail: [RemoteEntry] = []
    @State private var entries: [RemoteEntry] = []
    @State private var selection: RemoteEntry.ID?
    @State private var isLoading = true
    @State private var error: String?

    var body: some View {
        StepPage(title: "Choose your music folder", subtitle: "Open the shared folder that holds your music and choose it, or a folder inside it if the share also holds other media. Everything inside is indexed.") {
            VStack(alignment: .leading, spacing: 10) {
                pathBar
                List(entries, selection: $selection) { entry in
                    HStack(spacing: 10) {
                        Image(systemName: trail.isEmpty ? "externaldrive.fill" : "folder.fill")
                            .foregroundStyle(trail.isEmpty ? .secondary : Color.accentColor)
                        Text(entry.name)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { open(entry) }
                }
                .listStyle(.bordered(alternatesRowBackgrounds: true))
                .overlay {
                    if isLoading {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Loading folders…").foregroundStyle(.secondary)
                        }
                    } else if let error {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .padding()
                    } else if entries.isEmpty {
                        Text(trail.isEmpty ? "No shared folders are visible to this account." : "No folders inside")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } buttons: {
            Button("Back") {
                if trail.isEmpty {
                    model.cancelFolderChoice()
                } else {
                    trail.removeLast()
                    selection = nil
                }
            }
            Button("Open") {
                if let entry = entries.first(where: { $0.id == selection }) { open(entry) }
            }
            .disabled(selection == nil)
            Spacer()
            Button(trail.last.map { "Use “\($0.name)”" } ?? "Use This Folder") {
                if let current = trail.last { model.chooseMusicFolder(path: current.path, showsProgress: true) }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(trail.isEmpty)
        }
        .task(id: trail.last?.path) { await load() }
    }

    /// Where the browser is: the shares, then each folder opened.
    private var pathBar: some View {
        HStack(spacing: 4) {
            Image(systemName: "externaldrive")
                .foregroundStyle(.secondary)
            Text("Shared folders")
                .foregroundStyle(trail.isEmpty ? .primary : .secondary)
            ForEach(trail) { folder in
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tertiary)
                Text(folder.name)
                    .foregroundStyle(folder.id == trail.last?.id ? .primary : .secondary)
                    .lineLimit(1)
            }
        }
        .font(.callout)
    }

    private func open(_ entry: RemoteEntry) {
        trail.append(entry)
        selection = nil
    }

    private func load() async {
        isLoading = true
        error = nil
        do {
            entries = try await model.loadFolders(in: trail.last?.path)
        } catch {
            entries = []
            self.error = error.localizedDescription
        }
        isLoading = false
    }
}

// MARK: - Library

private struct MacLibraryStep: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library

    private var indexer: LibraryIndexer { model.indexer }

    var body: some View {
        StepPage(title: title, subtitle: subtitle) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(model.indexedCount, format: .number)
                        .font(.system(size: 54, weight: .light))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(model.indexedCount)))
                        .animation(.default, value: model.indexedCount)
                    Text("songs")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                }
                Group {
                    if model.isDemo {
                        ProgressView(value: Double(model.demoCount) / Double(SampleLibrary.displayedTrackTotal))
                    } else if indexer.isScanning {
                        ProgressView()
                    } else if model.indexingFailure != nil {
                        ProgressView(value: 0)
                    } else {
                        ProgressView(value: indexer.enrichProgress)
                    }
                }
                .frame(width: 280)
                .animation(.easeOut(duration: 0.25), value: indexer.enrichProgress)
            }
        } buttons: {
            if model.indexingFailure != nil {
                Button("Choose Another Folder") { model.chooseAnotherFolder() }
                Spacer()
                Button("Try Again") { model.retryIndexing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            } else {
                Spacer()
                Button("Open Library") { model.openLibrary() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.isIndexed)
            }
        }
    }

    private var title: String {
        if let failure = model.indexingFailure { return failure.title }
        return model.isIndexed ? "Your library is ready" : "Building your library"
    }

    private var subtitle: String? {
        if let failure = model.indexingFailure { return failure.detail }
        if model.isDemo {
            return model.isIndexed ? library.catalogue.detail : "Reading tags, artwork and folder structure…"
        }
        switch indexer.phase {
        case .scanning: return "\(indexer.foldersScanned.formatted()) folders scanned"
        case .enriching: return "\(library.catalogue.detail). Tags and covers keep arriving in the background."
        case .done: return library.catalogue.detail
        default: return "Reading tags, artwork and folder structure…"
        }
    }
}

// MARK: - Snapshots

/// Development aid: `--snapshot <directory>` renders every setup step to a PNG and quits, so the
/// layout can be checked without screen recording rights. The window draws its own contents.
@MainActor
enum MacSetupSnapshots {
    static func runIfRequested(model: AppModel) {
        // The app is sandboxed, so the images land in its own temporary folder.
        guard ProcessInfo.processInfo.arguments.contains("--snapshot") else { return }
        let directory = FileManager.default.temporaryDirectory.appending(path: "setup-snapshots", directoryHint: .isDirectory)
        NSLog("Skyr setup snapshots: %@", directory.path)
        Task { await run(model: model, into: directory) }
    }

    private static func run(model: AppModel, into directory: URL) async {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Only the stage and the pending server are touched, and both are put back at the end.
        let originalStage = model.stage
        let steps: [(String, () -> Void)] = [
            ("1-welcome", { model.stage = .welcome }),
            ("2-server", { model.pendingServer = nil; model.stage = .discovering }),
            ("3-signin", { model.stage = .discovering; model.pendingServer = DiscoveredServer(name: "Synology DS224+", host: "192.168.1.40", port: 5001, model: "DS224+") }),
            ("4-folder", { model.pendingServer = nil; model.stage = .chooseFolder }),
            ("5-library", { model.stage = .indexing }),
        ]
        try? await Task.sleep(for: .seconds(1.5))
        for (name, apply) in steps {
            apply()
            try? await Task.sleep(for: .seconds(1.4))
            guard let window = NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            if let data = rep.representation(using: .png, properties: [:]) {
                try? data.write(to: directory.appending(path: "\(name).png"))
            }
        }
        model.pendingServer = nil
        model.stage = originalStage
        try? await Task.sleep(for: .seconds(0.5))
        NSApp.terminate(nil)
    }
}
