import SkyrCore
import SwiftUI

/// Four dots and a keypad. `submit` gets the four digits and returns false to shake and start over.
struct PINEntryView: View {
    let submit: (String) -> Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var digits = ""
    @State private var shakes = 0
    @State private var isBusy = false
    @State private var isInvalid = false

    private let keys: [String] = ["1", "2", "3", "4", "5", "6", "7", "8", "9", "", "0", "⌫"]

    var body: some View {
        let motionReduced = reduceMotion
        VStack(spacing: 30) {
            HStack(spacing: 18) {
                ForEach(0..<4, id: \.self) { index in
                    Circle()
                        .fill(index < digits.count ? Palette.ink : Color.clear)
                        .overlay(Circle().strokeBorder(Palette.ink.opacity(0.35), lineWidth: 1.5))
                        .frame(width: 16, height: 16)
                        .animation(.snappy(duration: 0.2), value: digits.count)
                }
            }
            .keyframeAnimator(initialValue: 0.0, trigger: shakes) { view, offset in
                view.offset(x: motionReduced ? 0 : offset)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-14, duration: 0.07)
                    CubicKeyframe(12, duration: 0.07)
                    CubicKeyframe(-8, duration: 0.06)
                    CubicKeyframe(5, duration: 0.05)
                    CubicKeyframe(0, duration: 0.05)
                }
            }
            if isInvalid {
                Text("That PIN didn’t match. Try again.")
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .accessibilityAddTraits(.updatesFrequently)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(76), spacing: 22), count: 3), spacing: 16) {
                ForEach(keys, id: \.self) { key in
                    if key.isEmpty {
                        Color.clear.frame(width: 76, height: 76)
                    } else {
                        Button {
                            tap(key)
                        } label: {
                            Group {
                                if key == "⌫" {
                                    Image(systemName: "delete.left")
                                        .font(.title3.weight(.medium))
                                } else {
                                    Text(key)
                                        .font(.system(size: 30, weight: .medium, design: .rounded))
                                }
                            }
                            .frame(width: 76, height: 76)
                            .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .glassEffect(.regular.interactive(), in: Circle())
                        .disabled(isBusy)
                        .accessibilityLabel(key == "⌫" ? "Delete" : key)
                    }
                }
            }
        }
        .sensoryFeedback(.selection, trigger: digits)
        .sensoryFeedback(.error, trigger: shakes)
        .pinKeyboard(tap)
    }

    private func tap(_ key: String) {
        guard !isBusy else { return }
        isInvalid = false
        if key == "⌫" {
            if !digits.isEmpty { digits.removeLast() }
            return
        }
        guard digits.count < 4 else { return }
        digits += key
        guard digits.count == 4 else { return }
        isBusy = true
        let entered = digits
        // Let the fourth dot fill before the answer.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            if !submit(entered) {
                isInvalid = true
                shakes += 1
                try? await Task.sleep(for: .milliseconds(350))
                digits = ""
            }
            isBusy = false
        }
    }
}

#if os(macOS)
/// Mac users enter and confirm a PIN using native secure text fields.
struct PINSetupSheet: View {
    let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var pin = ""
    @State private var confirmation = ""
    @FocusState private var focusedField: Field?

    private enum Field { case pin, confirmation }
    private var isValidPIN: Bool { pin.count == 4 && pin.allSatisfy { "0123456789".contains($0) } }
    private var canSet: Bool { isValidPIN && confirmation == pin }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SecureField("New PIN", text: $pin)
                        .focused($focusedField, equals: .pin)
                        .onSubmit { if isValidPIN { focusedField = .confirmation } }
                    SecureField("Confirm PIN", text: $confirmation)
                        .focused($focusedField, equals: .confirmation)
                        .onSubmit { setPIN() }
                    if pin.count >= 4, !isValidPIN {
                        Text("Use exactly four digits from 0 to 9.")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                    if confirmation.count >= 4, confirmation != pin {
                        Text("The PINs don't match.")
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                } footer: {
                    Text("Choose four digits from 0 to 9. The PIN is asked for before this profile opens and is saved when you save the profile.")
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Set a PIN")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use PIN") { setPIN() }.disabled(!canSet)
                }
            }
            .onAppear { focusedField = .pin }
        }
        .frame(minWidth: 400, idealWidth: 440, minHeight: 250, idealHeight: 300)
    }

    private func setPIN() {
        guard canSet else { return }
        onSet(pin)
        dismiss()
    }
}

#else
/// Choose a PIN, then type it once more.
struct PINSetupSheet: View {
    let onSet: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var first: String?
    @State private var attempt = 0

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                Text(first == nil ? "Choose a PIN" : "Confirm the PIN")
                    .font(.title2.weight(.semibold))
                Text(first == nil ? "Four digits, asked for before this profile opens." : "Type the same four digits again.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.bottom, 24)
                PINEntryView { pin in
                    guard let first else {
                        self.first = pin
                        attempt += 1
                        return true
                    }
                    guard pin == first else {
                        self.first = nil
                        return false
                    }
                    onSet(pin)
                    dismiss()
                    return true
                }
                .id(attempt)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheetDetents([.large])
    }
}

#endif

/// Verify the current PIN before allowing changes to PIN settings.
struct PINVerificationSheet: View {
    let profile: Profile
    let onVerified: (Bool) -> Void
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                ProfileAvatarView(profile: profile, size: 72)
                Text("Verify PIN")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 6)
                Text("Enter your current PIN to continue.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 22)
                PINEntryView { pin in
                    guard profiles.verify(pin: pin, for: profile) else { return false }
                    onVerified(true)
                    dismiss()
                    return true
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onVerified(false)
                        dismiss()
                    }
                }
            }
        }
        .sheetDetents([.large])
    }
}

/// A locked profile: its PIN, or the device's own biometrics when the profile allows them here.
struct UnlockSheet: View {
    let profile: Profile
    @Environment(ProfileStore.self) private var profiles
    @Environment(\.dismiss) private var dismiss
    /// Switched on here, the PIN entered now is the last one this device asks for.
    @State private var enableBiometrics = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Spacer(minLength: 0)
                ProfileAvatarView(profile: profile, size: 72)
                Text(profile.name)
                    .font(.title2.weight(.semibold))
                    .padding(.top, 6)
                Text("Enter the PIN")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 22)
                PINEntryView { pin in
                    guard profiles.activate(profile, pin: pin) else { return false }
                    if enableBiometrics { profiles.setBiometrics(true, for: profile) }
                    dismiss()
                    return true
                }
                if let biometry = profiles.biometryName {
                    if profiles.biometricsEnabled(for: profile) {
                        Button("Use \(biometry)", systemImage: biometry == "Face ID" ? "faceid" : "touchid") {
                            Task {
                                if await profiles.unlockWithBiometrics(profile) {
                                    dismiss()
                                }
                            }
                        }
                        .buttonStyle(.glass)
                        .padding(.top, 20)
                    } else {
                        Toggle(isOn: $enableBiometrics) {
                            Label("Open with \(biometry) on this \(Device.noun) from now on", systemImage: biometry == "Face ID" ? "faceid" : "touchid")
                                .font(.subheadline)
                        }
                        .toggleStyle(.switch)
                        .padding(.horizontal, 8)
                        .padding(.top, 20)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 24)
            .inlineTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .sheetDetents([.large])
    }
}

private extension View {
    /// On a Mac the digits can simply be typed; the keypad stays for the mouse.
    @ViewBuilder func pinKeyboard(_ tap: @escaping (String) -> Void) -> some View {
        #if os(macOS)
        modifier(PINKeyboard(tap: tap))
        #else
        self
        #endif
    }
}

#if os(macOS)
private struct PINKeyboard: ViewModifier {
    let tap: (String) -> Void
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .focused($isFocused)
            .onAppear { isFocused = true }
            .onKeyPress(characters: .decimalDigits) { press in
                tap(String(press.characters))
                return .handled
            }
            .onKeyPress(.delete) {
                tap("⌫")
                return .handled
            }
    }
}
#endif
