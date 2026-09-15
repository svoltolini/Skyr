# App Store Connect checklist for Skyr Music 1.0

This checklist documents the remaining App Store Connect (ASC) configuration steps required before public release. These items must be completed in the ASC web interface—they cannot be configured in the repository.

## In-repo packaging validation — COMPLETE

The following items are verified in the repository and signed builds:

- [x] **Privacy manifests** — All 5 targets (iOS, Widgets, Watch, Mac, TV) include `PrivacyInfo.xcprivacy`
- [x] **Export compliance** — `ITSAppUsesNonExemptEncryption: false` in all Info.plist configurations
- [x] **CarPlay entitlement** — Approved and present in signed iOS binary and provisioning profile
- [x] **tvOS Top Shelf assets** — 1x and 2x images for both standard (1920×720, 3840×1440) and wide (2320×720, 4640×1440)
- [x] **Watch app icons** — Complete set for all Watch sizes (38mm through 49mm)
- [x] **iOS/Mac app icons** — Present in asset catalogue
- [x] **tvOS brand assets** — App Icon stack layers present
- [x] **Build version alignment** — `CURRENT_PROJECT_VERSION` consistent across all 5 targets
- [x] **CloudKit entitlements** — Production environment configured
- [x] **App Groups** — Configured for widget data sharing
- [x] **Archive validation** — iOS/Watch/Widgets, Mac, and TV Release archives pass export validation
- [x] **TestFlight upload** — All platforms verified as VALID / IN_BETA_TESTING (build 202609142150)
- [x] **App Review demo mode** — Sample library available for testing without NAS hardware

## App Store Connect — REQUIRED BEFORE PUBLIC RELEASE

### App information (General)

| Item | Status | Notes |
|------|--------|-------|
| App name | ⬜ Verify | "Skyr Music" |
| Subtitle | ⬜ Set | e.g., "Play music from your Synology NAS" |
| Primary category | ⬜ Set | Music |
| Secondary category | ⬜ Optional | Entertainment or Utilities |
| Content rights | ⬜ Confirm | User-supplied music; no third-party content licensing |

### App privacy (Data collection)

| Item | Status | Notes |
|------|--------|-------|
| Privacy policy URL | ⬜ Set | Requires public HTTPS URL; see `PRIVACY-POLICY.md` for draft text |
| Privacy nutrition label | ⬜ Complete | Answer questions based on `PRIVACY-RELEASE-CHECK.md` rationale |
| Tracking disclosure | ⬜ Confirm | App does not track (ATT not used) |

Recommended privacy answers based on source review:
- **Data Not Collected** is supportable if the owner confirms no server-side analytics or retained support data
- If TestFlight crash reports or App Store analytics are used, classify appropriately
- See `PRIVACY-RELEASE-CHECK.md` for detailed reasoning

### App Review information

| Item | Status | Notes |
|------|--------|-------|
| Contact info | ⬜ Set | Name, phone, email for review team |
| Demo account | ⬜ Optional | Not required—sample library available |
| Review notes | ⬜ Set | Copy from `APP_REVIEW_NOTES.md` or link to this document |
| Attachment | ⬜ Optional | Consider short video showing sample library navigation |

### Pricing and availability

| Item | Status | Notes |
|------|--------|-------|
| Price | ⬜ Set | Free or paid tier |
| Availability | ⬜ Set | Countries/regions |
| Pre-order | ⬜ Decide | Optional |

### Platform-specific metadata

Each platform (iOS, macOS, tvOS) requires:

| Item | Status |
|------|--------|
| Screenshots (required sizes) | ⬜ Capture |
| App preview videos | ⬜ Optional |
| Promotional text | ⬜ Write |
| Description | ⬜ Write |
| Keywords | ⬜ Set |
| Support URL | ⬜ Set (requires public URL) |
| Marketing URL | ⬜ Optional |
| What's New text | ⬜ Write (for updates) |

#### Screenshot requirements

| Platform | Required sizes |
|----------|----------------|
| iPhone | 6.9" (1320×2868 or 1290×2796), 6.5" (1284×2778 or 1242×2688), 5.5" (1242×2208) |
| iPad | 13" (2064×2752), 12.9" (2048×2732) |
| Mac | 1280×800 minimum, 2880×1800 recommended |
| Apple TV | 1920×1080 or 3840×2160 |

### tvOS-specific

| Item | Status | Notes |
|------|--------|-------|
| Privacy policy text | ⬜ Set | tvOS requires inline text (no URL), 6000 char max |
| Top Shelf extension | ✅ | Assets verified in repo |

### Export compliance

| Item | Status | Notes |
|------|--------|-------|
| Uses encryption | ✅ Set | `ITSAppUsesNonExemptEncryption: false` in Info.plist |
| CCATS/ERN | ⬜ N/A | Not required; only Apple-provided encryption |

No additional export documentation is required. The app uses only:
- Apple HTTPS/TLS (exempt)
- Apple CloudKit (exempt)
- Apple Keychain (exempt)

### In-app purchases

| Item | Status | Notes |
|------|--------|-------|
| IAPs configured | ⬜ N/A | None planned for 1.0 |

### App clips

| Item | Status | Notes |
|------|--------|-------|
| App Clip configured | ⬜ N/A | None planned for 1.0 |

## Before external TestFlight / public submission

1. ⬜ Complete all "REQUIRED" items above
2. ⬜ Host privacy policy at public HTTPS URL
3. ⬜ Capture final screenshots on shipping build
4. ⬜ Set App Review notes (see `APP_REVIEW_NOTES.md`)
5. ⬜ Submit for external beta review (if using external testers)
6. ⬜ Address any review feedback
7. ⬜ Submit for App Store review

## References

- [App Store Connect Help](https://developer.apple.com/help/app-store-connect/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [App Privacy Details](https://developer.apple.com/app-store/app-privacy-details/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/screenshot-specifications/)
- [Export compliance](https://developer.apple.com/documentation/security/complying_with_encryption_export_regulations)
