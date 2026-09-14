# Skyr

Skyr is a native Apple-platform music app for a personal Synology NAS library. It talks directly to DSM File Station, builds a local catalogue, streams or downloads audio, and synchronizes family profiles through CloudKit.

The repository contains the iPhone/iPad app, native Mac app, Apple TV app, Apple Watch companion, widgets, Live Activities, CarPlay scene, and the shared Swift package.

## Project map

| Area | Location | Responsibility |
| --- | --- | --- |
| Shared core | `Packages/SkyrCore/Sources/SkyrCore` | Synology networking, indexing, library state, playback, downloads, profiles, and CloudKit |
| Shared widget models | `Packages/SkyrCore/Sources/SkyrShared` | Widget snapshots, deep links, and Live Activity state |
| iPhone and iPad | `Skyr` | Main SwiftUI app, setup, library, player, settings, CarPlay bridge, and Watch bridge |
| Mac | `SkyrMac` | Native Mac shell, setup assistant, navigation, and player bar |
| Apple TV | `SkyrTV` | TV navigation, focus-based UI, setup, and playback |
| Apple Watch | `SkyrWatch` | Received catalogue, playlist downloads, and independent local playback |
| Widgets | `SkyrWidgets` | Home, downloads, playlists, rediscovery, and download Live Activity |
| Project definition | `project.yml` | XcodeGen targets, capabilities, deployment targets, and versions |

The only supported server provider in the current implementation is Synology DSM/File Station. Bonjour discovers HTTP and SMB-advertising devices, but Skyr is not an SMB client.

## Local checks

```sh
swift test -c release --package-path Packages/SkyrCore
xcodebuild -project Skyr.xcodeproj -scheme Skyr -configuration Release -destination 'generic/platform=iOS Simulator' build
xcodebuild -project Skyr.xcodeproj -scheme SkyrMac -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -project Skyr.xcodeproj -scheme SkyrTV -configuration Release -destination 'generic/platform=tvOS Simulator' build
```

Use XcodeGen after changing `project.yml`, and treat `project.yml` as the source of truth for generated project settings.

## Release version policy

The first public version remains `1.0`. For TestFlight iterations, increment `CURRENT_PROJECT_VERSION` across every target and keep `MARKETING_VERSION` at `1.0`.

Passing a build or local simulator check is not sufficient release evidence. Provider-backed flows must be tested with a signed build on the intended devices, including a controlled Synology account, CloudKit owner/member accounts, and offline/reconnect cases.

## Current audit

The release-readiness review from 14 September 2026 is in [docs/RELEASE-AUDIT-2026-09-14.md](docs/RELEASE-AUDIT-2026-09-14.md). The tracked backlog is in [GitHub Issues](https://github.com/svoltolini/Skyr/issues).
