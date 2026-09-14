import SkyrCore
import SwiftUI

/// One shipped version: what it brought and what it fixed.
struct Release: Identifiable {
    let version: String
    let date: String
    let highlights: [String]
    let fixes: [String]
    var id: String { version }

    /// Newest first. Add an entry here with every release.
    static let all: [Release] = [
        Release(
            version: "1.0",
            date: "September 2026",
            highlights: platformHighlights,
            fixes: []
        ),
    ]

    /// Only describe features available on the device showing these notes.
    private static var platformHighlights: [String] {
        var items = ["Your whole music library, streamed straight from your Synology NAS."]
        #if os(tvOS)
        items.append("Profiles for everyone in the family, each with their own favourites, playlists, history and settings, protected by a PIN.")
        items.append("Shared family profiles and listening preferences through iCloud.")
        #elseif os(macOS)
        items.append("Profiles for everyone in the family, each with their own favourites, playlists, history and settings, protected by a PIN or Touch ID on supported Macs.")
        items.append("Family sharing through iCloud: invite up to five people and everything follows them to their devices.")
        items.append("Downloads per profile for offline listening on your Mac.")
        #else
        items.append("Profiles for everyone in the family, each with their own favourites, playlists, history and settings, protected by a PIN, Face ID or Touch ID on supported devices.")
        items.append("Family sharing through iCloud: invite up to five people and everything follows them to their devices.")
        items.append("Downloads per profile, with progress in the Dynamic Island on supported iPhones.")
        items.append("Home Screen widgets: Now Playing, Rediscover, Downloads and Playlists, with play buttons.")
        #endif
        items.append("Made for you playlists: Favourites, Favourites mix, Recently played and Library shuffle.")
        #if os(iOS)
        items.append("Lock screen, Control Center and AirPlay controls, shuffle and repeat.")
        #elseif os(macOS)
        items.append("Now Playing and AirPlay controls, shuffle and repeat.")
        #else
        items.append("Now Playing controls, shuffle and repeat.")
        #endif
        items.append("Genre clean-up: rename or merge genres tagged in different languages.")
        return items
    }

    static var current: Release? {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
        return all.first { $0.version == version } ?? all.first
    }

    /// Whether the person has opened the notes for the version they are running.
    static var hasUnseenNotes: Bool {
        guard let current else { return false }
        return UserDefaults.standard.string(forKey: "releaseNotes.seen") != current.version
    }

    static func markSeen() {
        if let current { UserDefaults.standard.set(current.version, forKey: "releaseNotes.seen") }
    }
}

/// What each version brought and fixed, newest first.
struct ReleaseNotesView: View {
    @Environment(PlayerModel.self) private var player

    #if os(tvOS)
    var body: some View {
        ScrollView {
            VStack(spacing: 28) {
                ForEach(Release.all) { release in
                    SettingsGroup(title: "Version \(release.version) · \(release.date)") {
                        VStack(alignment: .leading, spacing: 18) {
                            if !release.highlights.isEmpty {
                                notes(title: "What's new", symbol: "sparkles", items: release.highlights)
                            }
                            if !release.fixes.isEmpty {
                                notes(title: "Fixes", symbol: "wrench.and.screwdriver.fill", items: release.fixes)
                            }
                        }
                        .padding(16)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .skyrBackground(player.tint)
        .navigationTitle("What's New")
        .inlineTitle()
        .onAppear { Release.markSeen() }
    }
    #else
    var body: some View {
        List {
            ForEach(Release.all) { release in
                if !release.highlights.isEmpty {
                    Section {
                        ForEach(release.highlights, id: \.self) { item in
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                    } header: {
                        Text("Version \(release.version) · \(release.date)")
                    }
                }
                if !release.fixes.isEmpty {
                    Section(release.highlights.isEmpty ? "Version \(release.version) · \(release.date)" : "Fixes") {
                        ForEach(release.fixes, id: \.self) { item in
                            Text(item).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .groupedList()
        .navigationTitle("What's New")
        .inlineTitle()
        .onAppear { Release.markSeen() }
    }
    #endif

    private func notes(title: String, symbol: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(items, id: \.self) { item in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle()
                        .fill(Palette.ink.opacity(0.5))
                        .frame(width: 5, height: 5)
                        .offset(y: -3)
                    Text(item)
                        .font(.body)
                }
            }
        }
    }
}
