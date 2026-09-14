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
    @FocusState private var focus: Field?

    private enum Field { case account, password, otp }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Server", value: server.name)
                    LabeledContent("Address", value: server.address)
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
                            .disabled(account.isEmpty || password.isEmpty)
                    }
                }
            }
            .interactiveDismissDisabled(model.isSigningIn)
            .onAppear {
                if let connection = model.connection, connection.host == server.host {
                    account = connection.account
                }
                focus = account.isEmpty ? .account : .password
            }
        }
        .sheetDetents([.medium, .large])
    }

    private func submit() {
        guard !account.isEmpty, !password.isEmpty else { return }
        Task {
            await model.signIn(account: account, password: password, otpCode: otpCode, remember: remember)
        }
    }
}
