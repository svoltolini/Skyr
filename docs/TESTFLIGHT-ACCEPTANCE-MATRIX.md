# Skyr 1.0 — TestFlight Acceptance Matrix

This document defines the complete acceptance testing required before making Skyr 1.0 publicly available. It consolidates requirements from [#12](https://github.com/svoltolini/Skyr/issues/12) and the [release audit](RELEASE-AUDIT-2026-09-14.md).

**Current TestFlight build**: 1.0 (202609151421)  
**Audit baseline**: `73f85b74ab60a9707de2f744161b172d21ef5b4e`

## Testing Layers

| Layer | Scope | Runner |
| --- | --- | --- |
| Unit tests | Core logic, state management, persistence | `swift test` / CI |
| Preflight validation | Build settings, privacy manifests, signatures | `scripts/preflight-validation.sh` |
| Simulator smoke | UI rendering, basic flows | Xcode / CI |
| Device acceptance | Real hardware, NAS, network, accessories | Tester (manual) |
| Provider integration | DSM, CloudKit, Tailscale routes | Tester (manual) |

---

## Automated In-Repo Validation

These checks run without physical devices or TestFlight and are captured in `scripts/preflight-validation.sh`.

### Package Tests (190+ tests)

Run the full SkyrCore test suite:

```bash
cd Packages/SkyrCore && swift test
```

Coverage areas:
- Profile authorization and persistence
- Download state, restoration, and reliability
- Catalogue caching and migration
- CloudKit sync reliability
- Family access and authorization
- Widget authorization
- Playback recovery
- Connection and transport validation

### Build Validation

Verify all targets compile for Release:

```bash
xcodebuild -project Skyr.xcodeproj -scheme Skyr -configuration Release -destination 'generic/platform=iOS' build
xcodebuild -project Skyr.xcodeproj -scheme SkyrMac -configuration Release -destination 'generic/platform=macOS' build
xcodebuild -project Skyr.xcodeproj -scheme SkyrTV -configuration Release -destination 'generic/platform=tvOS' build
```

### Version Alignment

All targets must share the same version numbers:

| Target | MARKETING_VERSION | CURRENT_PROJECT_VERSION |
| --- | --- | --- |
| Skyr (iOS) | 1.0 | 202609151421 |
| SkyrWidgets | 1.0 | 202609151421 |
| SkyrWatch | 1.0 | 202609151421 |
| SkyrMac | 1.0 | 202609151421 |
| SkyrTV | 1.0 | 202609151421 |

### Privacy Manifest Validation

All five targets must include a PrivacyInfo.xcprivacy file with:
- `NSPrivacyTracking: false`
- `NSPrivacyCollectedDataTypes` declarations
- `NSPrivacyAccessedAPITypes` with reasons

Locations:
- `Skyr/PrivacyInfo.xcprivacy`
- `SkyrWidgets/PrivacyInfo.xcprivacy`
- `SkyrWatch/PrivacyInfo.xcprivacy`
- `SkyrMac/PrivacyInfo.xcprivacy`
- `SkyrTV/PrivacyInfo.xcprivacy`

### Entitlements Check

Verify required capabilities in signed binaries:
- **iOS**: App Groups, CloudKit, CarPlay (approved), Push Notifications
- **Mac**: Sandbox, Network Client, CloudKit, Push Notifications
- **TV**: CloudKit, Push Notifications
- **Watch**: Companion app bundle identifier

### Export Compliance

All Info.plist files must declare:
```
ITSAppUsesNonExemptEncryption: false
```

---

## Device Acceptance Matrix

These tests **require physical devices and a real Synology NAS**. Record build number, device/OS version, DSM version, account type, and result for each row.

### iPhone and iPad

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Setup** | Fresh DSM connection (standard account) | | | | |
| | Fresh DSM connection (OTP 2FA account) | | | | |
| | Connection with Tailscale route | | | | |
| | Public HTTPS connection (if supported) | | | | |
| **Library** | Initial full scan | | | | |
| | Partial failure during scan | | | | |
| | Refresh after NAS content change | | | | |
| | Folder structure change handling | | | | |
| **Playback** | Local streaming | | | | |
| | Seeking within track | | | | |
| | Next-track transitions | | | | |
| | AirPlay to external speaker | | | | |
| **Downloads** | Offline download (single track) | | | | |
| | Offline download (album) | | | | |
| | Background transfer completion | | | | |
| | Offline playback verification | | | | |
| **Widgets** | Widget action launches app | | | | |
| | Now Playing widget updates | | | | |
| **Live Activity** | Activity appears during playback | | | | |
| | Activity updates on track change | | | | |
| **Profiles** | Profile lock with PIN | | | | |
| | Profile switch | | | | |
| | Family owner invite | | | | |
| | Family member join | | | | |
| | Family member removal | | | | |
| **Interruptions** | Airplane mode during playback | | | | |
| | NAS restart recovery | | | | |
| | Session expiry and reauthentication | | | | |
| | App relaunch during download | | | | |
| | Account change (different Apple ID) | | | | |
| | Insufficient storage handling | | | | |
| | Incoming call during playback | | | | |
| | Headphone disconnect | | | | |

### Mac (Native)

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Setup** | Fresh DSM connection | | | | |
| | Connection with OTP account | | | | |
| **Navigation** | Window resize handling | | | | |
| | Multiple window sizes | | | | |
| | Keyboard navigation | | | | |
| **Playback** | Local streaming | | | | |
| | Downloads and offline playback | | | | |
| **CloudKit** | Convergence with iOS device | | | | |
| | Profile sync after edit | | | | |
| | Simultaneous offline changes | | | | |
| **Accessibility** | VoiceOver navigation | | | | |
| | Full keyboard access | | | | |

### Apple TV

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Setup** | Fresh DSM connection | | | | |
| | Connection reuse from iCloud | | | | |
| **Navigation** | Remote focus navigation | | | | |
| | Profile picker | | | | |
| **Playback** | Streaming playback | | | | |
| | Next/previous with remote | | | | |
| **Sync** | Family profile sync | | | | |
| | Profile updates from iOS | | | | |

### Apple Watch (Paired)

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Transfer** | Catalogue transfer from iPhone | | | | |
| | Nested-path download | | | | |
| **Download** | Download failure and retry | | | | |
| | Multiple track download | | | | |
| **Playback** | Offline independent playback | | | | |
| | Playback without iPhone | | | | |
| **Limitations** | Route limitation messaging | | | | |
| | OTP account limitation messaging | | | | |

### CarPlay

| Category | Test Case | Build | Device | Result | Notes |
| --- | --- | --- | --- | --- | --- |
| **Connection** | CarPlay session start | | | | |
| | Browse library via CarPlay | | | | |
| **Playback** | Start playback from CarPlay | | | | |
| | Playback controls | | | | |
| **UI** | Template rendering | | | | |
| | Now Playing screen | | | | |

---

## CloudKit Multi-Device Matrix

These tests require **two Apple devices signed into the same Apple Account** running the TestFlight build.

| Test Case | Device A | Device B | Result | Notes |
| --- | --- | --- | --- | --- |
| Profile created on A appears on B | | | | |
| Profile edit on A syncs to B | | | | |
| Simultaneous offline edits merge correctly | | | | |
| Profile deletion on A removes from B | | | | |
| Family member invite acceptance | | | | |
| Account change on A clears local B state | | | | |

---

## Accessibility Matrix

| Test Case | Platform | Result | Notes |
| --- | --- | --- | --- |
| Standard text size | iOS | | |
| Accessibility Extra Large text | iOS | | |
| VoiceOver navigation | iOS | | |
| VoiceOver navigation | Mac | | |
| Reduce Motion respected | iOS | | |
| Full keyboard access | Mac | | |
| Remote focus (no touch) | TV | | |
| Six profile limit UI | iOS | | |
| Long/Unicode profile names | iOS | | |

---

## Provider Configuration

### Required Synology DSM Setup

- DSM version: _______________
- Standard (non-2FA) test account: _______________
- OTP-enabled test account: _______________
- Least-privilege family test account: _______________
- Test library location: _______________
- Nested folder depth tested: _______________

### Network Routes Tested

| Route | Tested | Notes |
| --- | --- | --- |
| LAN (direct) | | |
| Tailscale (if offered) | | |
| Public HTTPS (if supported) | | |

---

## Sign-Off

All P1 device acceptance rows must pass before public release. Attach diagnostics for any failures.

| Sign-off | Name | Date | Build |
| --- | --- | --- | --- |
| iOS/iPad complete | | | |
| Mac complete | | | |
| Apple TV complete | | | |
| Apple Watch complete | | | |
| CarPlay complete | | | |
| CloudKit multi-device complete | | | |
| Accessibility complete | | | |

---

## References

- [Issue #12: Run the signed TestFlight acceptance matrix](https://github.com/svoltolini/Skyr/issues/12)
- [Release Audit](RELEASE-AUDIT-2026-09-14.md)
- [Remediation Batch 4](REMEDIATION-2026-09-14-BATCH-4.md)
- [Privacy Release Check](PRIVACY-RELEASE-CHECK.md)
