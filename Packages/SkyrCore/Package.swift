// swift-tools-version: 6.2
import PackageDescription

// The same concurrency defaults as the apps: main actor by default, async calls stay on the caller.
let settings: [SwiftSetting] = [
    .defaultIsolation(MainActor.self),
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    .enableUpcomingFeature("InferIsolatedConformances"),
]

let package = Package(
    name: "SkyrCore",
    platforms: [.iOS("26.1"), .tvOS("26.0"), .macOS("26.0"), .watchOS("26.0")],
    products: [
        .library(name: "SkyrCore", targets: ["SkyrCore"]),
        .library(name: "SkyrShared", targets: ["SkyrShared"]),
    ],
    targets: [
        // What the widget extension needs too: the snapshot, links and the Live Activity payload.
        .target(name: "SkyrShared", swiftSettings: settings),
        // Models, indexing, the server, playback, downloads, profiles and iCloud sync.
        .target(name: "SkyrCore", dependencies: ["SkyrShared"], swiftSettings: settings),
        .testTarget(name: "SkyrCoreTests", dependencies: ["SkyrCore"], swiftSettings: settings),
    ]
)
