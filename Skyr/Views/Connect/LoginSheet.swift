import SkyrCore
import SwiftUI

/// DSM account sign-in for a chosen server.
struct LoginSheet: View {
    let server: DiscoveredServer
    @Environment(AppModel.self) private var model
    @State private var account = ""
    @State private var password = ""
    @State private var otpCode = ""
    @State private var remember = true
    @State private var httpAllowed = false
    @FocusState private var focus: Field?

    private enum Field { case account, password, otp }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: server.name)
                    LabeledContent("Address", value: server.address)
                    NASTransportChoice(url: server.baseURL, httpAllowed: $httpAllowed) {
                        guard let url = NASTransportSecurity.httpsAlternative(for: server.baseURL) else { return }
                        model.select(DiscoveredServer(name: server.name, baseURL: url, model: server.model))
                    }
                    .disabled(model.isSigningIn)
                }
                Section {
                    TextField("Account", text: $account)
                        .textContentType(.username)
                        .noAutocapitalization()
                        .autocorrectionDisabled()
                        .focused($focus, equals: .account)
                        .submitLabel(.next)
                        .onSubmit { focus = .password }
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .focused($focus, equals: .password)
                        .submitLabel(model.needsOTP ? .next : .go)
                        .onSubmit { model.needsOTP ? focus = .otp : submit() }
                    if model.needsOTP {
                        TextField("Two-factor code", text: $otpCode)
                            .textContentType(.oneTimeCode)
                            .numberKeyboard()
                            .focused($focus, equals: .otp)
                    }
                    Toggle("Remember me", isOn: $remember)
                } header: {
                    Text("DSM account")
                } footer: {
                    Text("Signs in with your DiskStation account. Your music is read through File Station, so nothing needs to be installed on the NAS.")
                }
                if let error = model.signInError {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .font(.footnote)
                    }
                }
            }
            .groupedForm()
            .animation(.easeInOut(duration: 0.25), value: model.signInError)
            .animation(.easeInOut(duration: 0.25), value: model.needsOTP)
            .navigationTitle("Sign in")
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { model.cancelSignIn() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if model.isSigningIn {
                        ProgressView()
                    } else {
                        Button("Sign in", action: submit)
                            .disabled(account.isEmpty || password.isEmpty || !transportAllowed)
                    }
                }
            }
            .interactiveDismissDisabled(model.isSigningIn)
            .onAppear {
                httpAllowed = NASTransportSecurity.isAllowed(server.baseURL)
                if let familyAccount = model.pendingFamilyAccount {
                    account = familyAccount
                    password = model.pendingFamilyPassword ?? ""
                } else if let connection = model.connection, NASOrigin(url: connection.baseURL) == NASOrigin(url: server.baseURL) {
                    account = connection.account
                }
                focus = account.isEmpty ? .account : .password
            }
            .onChange(of: server.id) {
                account = model.pendingFamilyAccount ?? ""
                password = model.pendingFamilyPassword ?? ""
                otpCode = ""
                httpAllowed = NASTransportSecurity.isAllowed(server.baseURL)
            }
        }
        .sheetDetents([.medium, .large])
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty, transportAllowed else { return }
        Task {
            await model.signIn(account: account, password: password, otpCode: otpCode, remember: remember)
        }
    }

    private var transportAllowed: Bool {
        NASOrigin(url: server.baseURL)?.isHTTPS == true || httpAllowed
    }
}

/// A local choice made before credentials are sent. Merely displaying an HTTP address grants nothing.
struct NASTransportChoice: View {
    let url: URL
    @Binding var httpAllowed: Bool
    let useHTTPS: () -> Void

    var body: some View {
        if NASOrigin(url: url)?.isHTTPS == false {
            VStack(alignment: .leading, spacing: 8) {
                Label("HTTP is not encrypted", systemImage: "lock.open")
                    .foregroundStyle(.orange)
                Text("Your password and music can be read on this connection. Allow it only on a network you trust. Permission applies to this exact address on this device.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Toggle("Allow HTTP for this address", isOn: Binding(
                    get: { httpAllowed },
                    set: { allowed in
                        if allowed { NASTransportSecurity.allowHTTP(url) }
                        else { NASTransportSecurity.revokeHTTP(url) }
                        httpAllowed = allowed
                    }
                ))
                Button("Use HTTPS", action: useHTTPS)
            }
        } else {
            Label("HTTPS selected", systemImage: "lock")
                .foregroundStyle(.secondary)
                .font(.footnote)
        }
    }
}
