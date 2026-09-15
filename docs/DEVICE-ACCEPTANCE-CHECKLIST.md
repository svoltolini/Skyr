# Skyr 1.0 — Device Acceptance Checklist

**For: Tester/Sam**  
**Build**: 1.0 (202609142150)  
**Date**: _______________

This is the manual testing checklist for TestFlight device acceptance. Complete this **after** running `scripts/preflight-validation.sh` which verifies all automated checks.

---

## Before You Start

### Prerequisites

1. **TestFlight build installed** on all test devices
2. **Synology NAS configured** with:
   - Standard (non-2FA) test account
   - OTP-enabled test account
   - Least-privilege family test account
   - Test music library with nested folders
3. **Two Apple devices** signed into the same Apple Account (for CloudKit tests)
4. **Tailscale configured** (if testing remote access)

### Test Environment Record

| Item | Value |
| --- | --- |
| TestFlight build | 1.0 (202609142150) |
| DSM version | |
| iPhone model / iOS version | |
| iPad model / iPadOS version | |
| Mac model / macOS version | |
| Apple TV model / tvOS version | |
| Apple Watch model / watchOS version | |
| Test NAS path | |
| Tester name | |
| Test date | |

---

## Quick Reference: Test Status Legend

- ✅ = Passed
- ❌ = Failed (attach diagnostics)
- ⏭️ = Skipped (note reason)
- 🔄 = Blocked by other failure

---

## Phase 1: Core iPhone/iPad Tests

These are the critical path tests. Complete these first.

### Setup and Connection

| # | Test | Status | Notes |
|---|------|--------|-------|
| 1.1 | Fresh install → connect to NAS (standard account) | | |
| 1.2 | Fresh install → connect to NAS (OTP 2FA account) | | |
| 1.3 | Reconnect after app restart | | |
| 1.4 | Session expiry → reauthentication prompt | | |

### Library Scanning

| # | Test | Status | Notes |
|---|------|--------|-------|
| 2.1 | Initial full library scan completes | | |
| 2.2 | Add tracks on NAS → refresh shows new content | | |
| 2.3 | Remove tracks on NAS → refresh reflects removal | | |
| 2.4 | Simulate partial scan failure → no data loss | | |

### Playback

| # | Test | Status | Notes |
|---|------|--------|-------|
| 3.1 | Stream track from start to finish | | |
| 3.2 | Seek within track (scrub timeline) | | |
| 3.3 | Next track transition (auto and manual) | | |
| 3.4 | Previous track transition | | |
| 3.5 | AirPlay to external speaker | | |

### Downloads and Offline

| # | Test | Status | Notes |
|---|------|--------|-------|
| 4.1 | Download single track | | |
| 4.2 | Download full album | | |
| 4.3 | Background download completes (minimize app) | | |
| 4.4 | Enable Airplane Mode → play downloaded track | | |
| 4.5 | Delete downloaded content | | |

### Profiles

| # | Test | Status | Notes |
|---|------|--------|-------|
| 5.1 | Create profile with PIN | | |
| 5.2 | Lock profile → PIN required to unlock | | |
| 5.3 | Switch between profiles | | |
| 5.4 | Edit profile name/avatar | | |

---

## Phase 2: Family and CloudKit

### Family Sharing (requires two Apple accounts)

| # | Test | Status | Notes |
|---|------|--------|-------|
| 6.1 | Owner sends family invitation | | |
| 6.2 | Member accepts invitation link | | |
| 6.3 | Member sees shared profiles | | |
| 6.4 | Owner removes family member | | |

### CloudKit Sync (requires two devices, same Apple Account)

| # | Test | Status | Notes |
|---|------|--------|-------|
| 7.1 | Create profile on Device A → appears on Device B | | |
| 7.2 | Edit profile on Device A → syncs to Device B | | |
| 7.3 | Delete profile on Device A → removed from Device B | | |
| 7.4 | Edit same profile offline on both → merge correctly | | |
| 7.5 | Change Apple Account → local state clears | | |

---

## Phase 3: Platform-Specific Tests

### Mac (Native App)

| # | Test | Status | Notes |
|---|------|--------|-------|
| 8.1 | Fresh connection to NAS | | |
| 8.2 | Window resize → UI adapts | | |
| 8.3 | Keyboard navigation (Tab, arrows) | | |
| 8.4 | Streaming playback | | |
| 8.5 | Download and offline playback | | |
| 8.6 | Profile sync from iOS appears | | |

### Apple TV

| # | Test | Status | Notes |
|---|------|--------|-------|
| 9.1 | Fresh connection to NAS | | |
| 9.2 | Remote focus navigation | | |
| 9.3 | Profile picker works | | |
| 9.4 | Streaming playback | | |
| 9.5 | Profile changes sync from iOS | | |

### Apple Watch (Paired to iPhone)

| # | Test | Status | Notes |
|---|------|--------|-------|
| 10.1 | Catalogue syncs from iPhone | | |
| 10.2 | Download track with nested path | | |
| 10.3 | Download failure → retry works | | |
| 10.4 | Play downloaded track (Watch only, no iPhone) | | |
| 10.5 | OTP limitation message shown | | |

### CarPlay

| # | Test | Status | Notes |
|---|------|--------|-------|
| 11.1 | CarPlay session connects | | |
| 11.2 | Browse library in CarPlay | | |
| 11.3 | Start playback from CarPlay | | |
| 11.4 | Now Playing screen updates | | |

---

## Phase 4: Widgets and Live Activity

### Widgets (iOS)

| # | Test | Status | Notes |
|---|------|--------|-------|
| 12.1 | Add widget to Home Screen | | |
| 12.2 | Widget tap launches app | | |
| 12.3 | Now Playing widget shows current track | | |

### Live Activity

| # | Test | Status | Notes |
|---|------|--------|-------|
| 13.1 | Live Activity appears during playback | | |
| 13.2 | Live Activity updates on track change | | |
| 13.3 | Live Activity controls work | | |

---

## Phase 5: Interruptions and Edge Cases

| # | Test | Status | Notes |
|---|------|--------|-------|
| 14.1 | Airplane mode during stream → graceful handling | | |
| 14.2 | NAS restart → reconnection after | | |
| 14.3 | App killed during download → resumes on relaunch | | |
| 14.4 | Insufficient storage → clear error message | | |
| 14.5 | Incoming phone call → playback pauses/resumes | | |
| 14.6 | Headphone disconnect → playback pauses | | |

---

## Phase 6: Accessibility

| # | Test | Status | Notes |
|---|------|--------|-------|
| 15.1 | Standard text size renders correctly (iOS) | | |
| 15.2 | Accessibility Extra Large text (iOS) | | |
| 15.3 | VoiceOver navigation (iOS) | | |
| 15.4 | VoiceOver navigation (Mac) | | |
| 15.5 | Reduce Motion: no decorative animations | | |
| 15.6 | Full keyboard navigation (Mac) | | |
| 15.7 | Remote-only navigation (TV) | | |
| 15.8 | Six profiles display correctly | | |
| 15.9 | Long/Unicode profile names display | | |

---

## Phase 7: Network Routes (if applicable)

| # | Test | Status | Notes |
|---|------|--------|-------|
| 16.1 | LAN (direct local network) | | |
| 16.2 | Tailscale route (100.x.x.x) | | |
| 16.3 | Public HTTPS (if supported) | | |

---

## Sign-Off

### Blocker Issues Found

List any P1 issues that block public release:

1. _______________________________________________
2. _______________________________________________
3. _______________________________________________

### Non-Blocking Issues Found

List issues to fix post-release or in next build:

1. _______________________________________________
2. _______________________________________________
3. _______________________________________________

### Final Sign-Off

| Platform | Tester | Date | Status |
| --- | --- | --- | --- |
| iPhone/iPad | | | ☐ Approved ☐ Blocked |
| Mac | | | ☐ Approved ☐ Blocked |
| Apple TV | | | ☐ Approved ☐ Blocked |
| Apple Watch | | | ☐ Approved ☐ Blocked |
| CarPlay | | | ☐ Approved ☐ Blocked |
| CloudKit | | | ☐ Approved ☐ Blocked |
| Accessibility | | | ☐ Approved ☐ Blocked |

---

## Diagnostics Attachment

For any failed tests, attach:
- Console logs (Settings → Privacy → Analytics → Skyr)
- Screenshot of error state
- Steps to reproduce
- Device/OS/build details

Upload to: _______________________________________________
