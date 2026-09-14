import SkyrCore
import SwiftUI

struct WelcomeView: View {
    @Environment(AppModel.self) private var model
    /// The privacy introduction is read once; after that the welcome goes straight to finding servers.
    @AppStorage("onboarding.seen") private var hasSeenOnboarding = false
    @State private var isShowingOnboarding = false
    @State private var onboardingStart = 0

    var body: some View {
        ZStack {
            SetupPage(step: .welcome) {
                WelcomeContent(hasSeenOnboarding: hasSeenOnboarding) {
                    onboardingStart = 0
                    withAnimation(.easeInOut(duration: 0.4)) { isShowingOnboarding = true }
                }
            }
            if isShowingOnboarding {
                OnboardingView(initialIndex: onboardingStart) {
                    hasSeenOnboarding = true
                    model.findServers()
                    // The server page slides over; the introduction leaves quietly underneath it.
                    Task {
                        try? await Task.sleep(for: .seconds(0.7))
                        var transaction = Transaction()
                        transaction.disablesAnimations = true
                        withTransaction(transaction) { isShowingOnboarding = false }
                    }
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
                .zIndex(1)
            }
        }
        .skyrBackground(Palette.neutralTint)
        .hidesNavigationBar()
        .bareWindow()
        .task {
            // Development shortcut: `--onboarding 2` opens the introduction at a page.
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "--onboarding") {
                onboardingStart = flag + 1 < arguments.count ? Int(arguments[flag + 1]) ?? 0 : 0
                isShowingOnboarding = true
            }
        }
    }
}

/// The welcome step's own content: headline and actions on a phone; on a wide iPad the story pane
/// has the headline, so a wall of covers takes its place above the actions.
private struct WelcomeContent: View {
    let hasSeenOnboarding: Bool
    let startOnboarding: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(CloudSync.self) private var cloud
    @Environment(\.hasSetupStory) private var hasStory
    @State private var isJoiningWithLink = false

    /// First time through, the button opens the introduction; afterwards it looks for servers.
    private func findServers() {
        if hasSeenOnboarding {
            model.findServers()
        } else {
            startOnboarding()
        }
    }

    private var findServersTitle: String { hasSeenOnboarding ? "Find servers" : "Continue" }

    var body: some View {
        if hasStory {
            #if os(iOS)
            VStack(spacing: 0) {
                CoverWall()
                    .padding(.horizontal, 24)
                    .padding(.top, 8)
                actions
                    .frame(maxWidth: 380)
                    .padding(.top, 8)
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 40)
            #endif
        } else {
            VStack(alignment: .leading, spacing: 0) {
                Spacer()
                // The television reads from across a room: the same words, twice the size.
                Text("Your library,\nfrom your NAS.")
                    .font(.system(size: 38 * Metrics.scale, weight: .semibold))
                    .lineSpacing(-2)
                    .kerning(-0.8 * Metrics.scale)
                Text("Connect the server you already own. Nothing leaves your network.")
                    .font(Metrics.scale > 1 ? .title3 : .body)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 300 * Metrics.scale, alignment: .leading)
                    .padding(.top, 16 * Metrics.scale)
                Spacer()
                actions
            }
            .padding(.horizontal, 28)
            .padding(.bottom, 12)
            .connectColumn(alignment: .leading, width: 460)
        }
    }

    @ViewBuilder private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let family = cloud.family, family.isReachable {
                if family.familyAccount != nil {
                    // The family account signs this device in by itself.
                    HStack(spacing: 10) {
                        if model.isJoiningFamily { ProgressView() }
                        Text(model.isJoiningFamily ? "Joining \(family.serverName)…" : "Ready to join \(family.serverName)")
                            .font(.headline)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    if let error = model.signInError, !model.isJoiningFamily {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.bottom, 8)
                        Button {
                            Task { await model.connectWithFamilyAccess(family) }
                        } label: {
                            Text("Try again")
                                .font(.headline)
                                .foregroundStyle(Palette.onInk)
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.extraLarge)
                        .tint(Palette.ink)
                        .padding(.bottom, 14)
                    }
                } else {
                    Button {
                        Task { await model.joinFamilyServer(family) }
                    } label: {
                        Text("Join \(family.serverName)")
                            .font(.headline)
                            .foregroundStyle(Palette.onInk)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                    .controlSize(.extraLarge)
                    .tint(Palette.ink)
                    Text("Your family's server, shared with you through iCloud.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .padding(.bottom, 14)
                    if let error = model.signInError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding(.bottom, 8)
                    }
                }
            }
            if cloud.family?.isReachable != true {
                Button(action: findServers) {
                    Text(findServersTitle)
                        .font(.headline)
                        .foregroundStyle(Palette.onInk)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.extraLarge)
                .tint(Palette.ink)
            } else {
                Button(action: findServers) {
                    Text(findServersTitle)
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                .controlSize(.extraLarge)
            }
            #if !os(tvOS)
            if cloud.family?.isReachable != true {
                // Invited people whose link opened in a browser paste it here instead.
                Button("Have an invitation link?") { isJoiningWithLink = true }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
            }
            #endif
        }
        .sheet(isPresented: $isJoiningWithLink) {
            JoinWithLinkSheet()
        }
    }
}
