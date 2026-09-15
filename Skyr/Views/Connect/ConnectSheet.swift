import SkyrCore
import SwiftUI

/// Takes the NAS's address, finds where DSM answers, and offers it for sign-in.
struct ConnectSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var isResolving = false
    @State private var error: String?
    @State private var isReadingGuide = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address", text: $text)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .urlKeyboard()
                        .focused($isFocused)
                        .submitLabel(.go)
                        .onSubmit(submit)
                        .disabled(isResolving)
                } header: {
                    Text("Server")
                } footer: {
                    Text("Enter a NAS name, IP address, or full HTTPS address. Skyr uses HTTPS by default for security.\n\nFor remote access, enter your NAS's Tailscale IP (100.x.x.x) or full MagicDNS name (nas.tailnet.ts.net). Tailscale creates a secure connection without opening ports.\n\nHTTP sends credentials in cleartext — only use it on a trusted private network, and you will confirm this choice before signing in.")
                }
                Section {
                    Button {
                        isReadingGuide = true
                    } label: {
                        Label("How to reach your NAS from anywhere", systemImage: "book")
                    }
                    .disabled(isResolving)
                }
                if isResolving {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Checking the address…")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if let error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .groupedForm()
            .animation(.easeInOut(duration: 0.25), value: error)
            .animation(.easeInOut(duration: 0.25), value: isResolving)
            .navigationTitle("Connect")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .disabled(isResolving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Continue", action: submit)
                        .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || isResolving)
                }
            }
            .interactiveDismissDisabled(isResolving)
            .onAppear { isFocused = true }
            .sheet(isPresented: $isReadingGuide) {
                RemoteAccessGuide()
            }
        }
        .sheetDetents([.medium, .large])
    }

    private func submit() {
        let entry = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !entry.isEmpty, !isResolving else { return }
        isResolving = true
        error = nil
        Task {
            do {
                try await model.connect(to: entry)
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            isResolving = false
        }
    }
}

private struct ReauthenticationSheet: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        content.sheet(item: Binding(
            get: { model.stage == .ready ? model.pendingServer : nil },
            set: { if $0 == nil { model.cancelSignIn() } }
        )) { server in
            LoginSheet(server: server)
        }
    }
}

private struct DownloadErrorAlert: ViewModifier {
    @Environment(DownloadManager.self) private var downloads

    func body(content: Content) -> some View {
        content.alert("Download couldn't finish", isPresented: Binding(
            get: { downloads.lastError != nil },
            set: { if !$0 { downloads.clearError() } }
        )) {
            Button("OK") { downloads.clearError() }
        } message: {
            Text(downloads.lastError ?? "Reconnect to your NAS and try again.")
        }
    }
}

/// Reports a problem with a profile's files. Reading and writing fail differently: a document that
/// cannot be read keeps its profile closed, so that alert also offers the way past the picker.
private struct ProfileSaveErrorAlert: ViewModifier {
    @Environment(ProfileStore.self) private var profiles

    func body(content: Content) -> some View {
        content.alert(profiles.persistenceFailure?.title ?? "Profile couldn't be saved", isPresented: Binding(
            get: { profiles.persistenceFailure != nil },
            set: { if !$0 { profiles.dismissPersistenceError() } }
        )) {
            if profiles.canOpenWithoutSavedData {
                Button("Open Without Saved Data", role: .destructive) {
                    // After the alert has let go of its binding, so a failure here is reported.
                    Task { profiles.openWithoutSavedData() }
                }
                Button("Not Now", role: .cancel) { profiles.dismissPersistenceError() }
            } else {
                Button("OK") { profiles.dismissPersistenceError() }
            }
        } message: {
            Text(profiles.persistenceFailure?.message ?? "Check the available storage on this device and try again.")
        }
    }
}

extension View {
    func reauthenticationSheet() -> some View { modifier(ReauthenticationSheet()) }
    func downloadErrorAlert() -> some View { modifier(DownloadErrorAlert()) }
    func profileSaveErrorAlert() -> some View { modifier(ProfileSaveErrorAlert()) }
}
