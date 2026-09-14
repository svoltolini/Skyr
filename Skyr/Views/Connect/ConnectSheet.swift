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
                    Text("From anywhere, the DDNS name you gave your NAS in DSM, such as myds.synology.me. At home, its local address such as 192.168.1.40 works too. No port or https:// needed.")
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
