# App Review notes for Skyr Music

This document provides App Store Review with the information needed to evaluate Skyr Music.

## What Skyr does

Skyr Music streams and downloads music from a personal Synology NAS (Network Attached Storage). It is not a music-streaming service with its own catalogue—users supply their own music files stored on their own NAS hardware.

## Testing without a NAS

Skyr includes a built-in **sample library** with 12 demonstration albums containing simulated track metadata. This allows full UI and navigation evaluation without real NAS hardware.

### Enabling the sample library

The sample library activates automatically when:
1. Launch the app on any platform (iPhone, iPad, Mac, Apple TV, or Apple Watch)
2. On the Welcome/connection screen, the sample library option is available
3. The UI displays fully rendered album art, track lists, playlists, and playback controls

**Note:** The sample library simulates playback (progress bar, time display, transport controls) but does not produce audio output because no actual audio files are bundled. This is expected behavior for review purposes.

### What can be tested with the sample library

| Feature | Testable |
|---------|----------|
| Library browsing (albums, artists, genres) | Yes |
| Search | Yes |
| Playlists (view, create, edit) | Yes |
| Simulated playback controls | Yes |
| Profile creation and switching | Yes |
| Settings and preferences | Yes |
| Widget configuration | Yes |
| CarPlay interface | Yes (simulator) |
| Watch app navigation | Yes |
| Audio output | No (no bundled audio) |
| Real downloads | No (requires NAS) |

## Testing with real NAS hardware

If App Review has access to a Synology NAS or wishes to test full functionality:

1. **NAS requirement:** Synology DiskStation running DSM 7.x or later with Audio Station installed
2. **Network:** The review device and NAS must be on the same local network, or accessible via Tailscale
3. **Credentials:** A standard DSM user account with read access to the music folder

The owner can provide temporary demo NAS credentials upon request. Contact information is in App Store Connect.

## Platform-specific notes

### iOS/iPadOS
- Standard library navigation and playback
- Widgets: Now Playing and Recently Played
- Live Activities during playback (simulated with sample library)

### macOS
- Native Mac app (not iPad-on-Mac)
- Standard window management and keyboard shortcuts

### tvOS
- Focus-based navigation with Apple TV remote
- Top Shelf displays recently played albums

### watchOS
- Companion app for the paired iPhone
- Can download playlists for offline Watch playback (requires real NAS)
- Sample library mode shows playlists without transfer capability

### CarPlay
- Audio playback interface (requires CarPlay-capable vehicle or simulator)
- Approved CarPlay audio entitlement is present

## Capabilities and entitlements

| Capability | Purpose |
|------------|---------|
| CloudKit | Sync profiles, favorites, and playlists across devices via user's iCloud |
| App Groups | Share data between main app and widgets |
| CarPlay Audio | Display playback controls on vehicle screen |
| Background Audio | Continue playback when app is backgrounded |
| Background Processing | Complete download and indexing tasks |
| Local Network | Discover and connect to NAS on LAN |
| Bonjour | Discover NAS services via mDNS |

## Privacy

- No analytics SDK or advertising framework
- No data sent to developer servers
- CloudKit data stored in user's private iCloud container
- NAS credentials stored in device Keychain
- See in-app Privacy Details for full disclosure

## Export compliance

`ITSAppUsesNonExemptEncryption` is set to `false` for all targets. Skyr uses only:
- Apple-provided HTTPS/TLS for NAS and iCloud connections
- Apple-provided CloudKit encryption
- Apple Keychain for credential storage

No custom or non-exempt encryption algorithms are implemented.

## Contact

For review questions or temporary NAS access, contact the developer through App Store Connect or the support URL provided in app metadata.
