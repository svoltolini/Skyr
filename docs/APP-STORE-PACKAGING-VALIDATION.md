# App Store Packaging Validation Checklist

Gumbo 1.0 — App Store distribution readiness

This checklist provides concrete validation steps for every App Store submission. It consolidates the acceptance criteria from [#13](https://github.com/svoltolini/gumbo/issues/13) and evidence from prior remediation batches.

## Quick Reference

| Platform | Bundle ID | Build |
| --- | --- | --- |
| iOS (iPhone/iPad) | `com.samuelvoltolini.skyr` | 1.0 (202609142150) |
| iOS Widgets | `com.samuelvoltolini.skyr.widgets` | 1.0 (202609142150) |
| watchOS | `com.samuelvoltolini.skyr.watchkitapp` | 1.0 (202609142150) |
| macOS | `com.samuelvoltolini.skyr` | 1.0 (202609142150) |
| tvOS | `com.samuelvoltolini.skyr` | 1.0 (202609142150) |

---

## 1. Archive Build Validation

Run for each target before every TestFlight upload.

### 1.1 iOS Archive (includes Watch and Widgets)

```bash
xcodebuild archive \
  -project Skyr.xcodeproj \
  -scheme Skyr \
  -destination "generic/platform=iOS" \
  -archivePath build/Skyr-iOS.xcarchive \
  -configuration Release
```

- [ ] Archive completes without error
- [ ] No unresolved asset catalog warnings
- [ ] Watch app embedded at `Products/Applications/Skyr.app/Watch/Skyr.app`
- [ ] Widgets extension embedded at `Products/Applications/Skyr.app/PlugIns/SkyrWidgets.appex`

### 1.2 macOS Archive

```bash
xcodebuild archive \
  -project Skyr.xcodeproj \
  -scheme SkyrMac \
  -destination "generic/platform=macOS" \
  -archivePath build/Skyr-macOS.xcarchive \
  -configuration Release
```

- [ ] Archive completes without error
- [ ] Universal binary includes arm64 and x86_64

### 1.3 tvOS Archive

```bash
xcodebuild archive \
  -project Skyr.xcodeproj \
  -scheme SkyrTV \
  -destination "generic/platform=tvOS" \
  -archivePath build/Skyr-tvOS.xcarchive \
  -configuration Release
```

- [ ] Archive completes without error
- [ ] Top Shelf assets present (1920×720, 2320×720 at required scales)
- [ ] Only expected notice: "Skipping AppIntents extraction" (expected)

---

## 2. App Store Export Validation

### 2.1 Export Archives

```bash
xcodebuild -exportArchive \
  -archivePath build/Skyr-iOS.xcarchive \
  -exportOptionsPlist ExportOptions-AppStore.plist \
  -exportPath build/export-ios
```

Repeat for macOS and tvOS archives.

- [ ] Export completes for all three platforms
- [ ] `.ipa` (iOS) or `.pkg` (macOS) generated
- [ ] No signing errors

### 2.2 Validate Exports

```bash
xcrun altool --validate-app -f build/export-ios/Skyr.ipa \
  --type ios -u "$APPLE_ID" -p "$APP_SPECIFIC_PASSWORD"
```

- [ ] iOS validation passes: "No errors validating archive"
- [ ] macOS validation passes
- [ ] tvOS validation passes

---

## 3. Entitlements Verification

### 3.1 iOS Entitlements

Extract and verify from the signed `.app`:

```bash
codesign -d --entitlements - build/Skyr-iOS.xcarchive/Products/Applications/Skyr.app
```

**Required entitlements:**

| Entitlement | Value | Status |
| --- | --- | --- |
| `com.apple.developer.carplay-audio` | `true` | ✅ Approved |
| `com.apple.security.application-groups` | `group.com.samuelvoltolini.skyr` | Required |
| `com.apple.developer.icloud-container-identifiers` | `iCloud.com.samuelvoltolini.skyr` | Required |
| `com.apple.developer.icloud-services` | `CloudKit` | Required |
| `aps-environment` | `production` (Release) | Required |

- [ ] CarPlay audio entitlement present in binary
- [ ] CarPlay audio entitlement present in provisioning profile
- [ ] App Groups entitlement matches widgets and Watch
- [ ] CloudKit entitlements present

### 3.2 macOS Entitlements

```bash
codesign -d --entitlements - build/Skyr-macOS.xcarchive/Products/Applications/Skyr.app
```

- [ ] `com.apple.security.app-sandbox` is `true`
- [ ] `com.apple.security.network.client` is `true`
- [ ] CloudKit entitlements present

### 3.3 tvOS Entitlements

```bash
codesign -d --entitlements - build/Skyr-tvOS.xcarchive/Products/Applications/Skyr.app
```

- [ ] CloudKit entitlements present
- [ ] No unexpected entitlements

---

## 4. Privacy Manifest Validation

Each app/extension must include a valid `PrivacyInfo.xcprivacy`.

### 4.1 Manifest Locations

| Target | Path |
| --- | --- |
| iOS | `Skyr/PrivacyInfo.xcprivacy` |
| Widgets | `SkyrWidgets/PrivacyInfo.xcprivacy` |
| Watch | `SkyrWatch/PrivacyInfo.xcprivacy` |
| Mac | `SkyrMac/PrivacyInfo.xcprivacy` |
| TV | `SkyrTV/PrivacyInfo.xcprivacy` |

### 4.2 Required Declarations

All manifests must declare:

```xml
<key>NSPrivacyTracking</key>
<false/>
<key>NSPrivacyCollectedDataTypes</key>
<array/>
<key>NSPrivacyAccessedAPITypes</key>
<array>
  <!-- UserDefaults and file timestamp reasons -->
</array>
```

- [ ] All five manifests present in archives
- [ ] `NSPrivacyTracking` is `false` in all manifests
- [ ] `NSPrivacyCollectedDataTypes` is empty array in all manifests
- [ ] Required-reason APIs documented with appropriate reasons

### 4.3 Verify in Archive

```bash
unzip -l build/export-ios/Skyr.ipa | grep PrivacyInfo
```

- [ ] `Payload/Skyr.app/PrivacyInfo.xcprivacy` present
- [ ] `Payload/Skyr.app/Watch/Skyr.app/PrivacyInfo.xcprivacy` present
- [ ] `Payload/Skyr.app/PlugIns/SkyrWidgets.appex/PrivacyInfo.xcprivacy` present

---

## 5. Asset Catalog Validation

### 5.1 iOS App Icons

- [ ] `AppIcon` iconset complete (all required sizes)
- [ ] No missing 1x/2x/3x variants warnings

### 5.2 Watch App Icons

- [ ] `WatchAppIcon` iconset complete
- [ ] Companion icon sizes included

### 5.3 TV Assets

- [ ] `TVIcon` complete with layered images
- [ ] Top Shelf images at required sizes:
  - `shelf-1920x720.png` (wide)
  - `shelf-2320x720.png` (wide, 4K)
- [ ] No "missing image" warnings in archive

### 5.4 Accent Colors

- [ ] `AccentColor` defined in asset catalog
- [ ] Renders correctly in Light and Dark modes

---

## 6. TestFlight Upload Validation

### 6.1 Upload Builds

```bash
xcrun altool --upload-app -f build/export-ios/Skyr.ipa \
  --type ios -u "$APPLE_ID" -p "$APP_SPECIFIC_PASSWORD"
```

- [ ] iOS upload accepted
- [ ] macOS upload accepted  
- [ ] tvOS upload accepted

### 6.2 App Store Connect Processing

After upload, verify in App Store Connect:

- [ ] Build status: "Processing" → "Ready to Submit" (allow 15-60 minutes)
- [ ] No "Missing Compliance" warning (ITSAppUsesNonExemptEncryption is false)
- [ ] No "Invalid Binary" rejection email

### 6.3 TestFlight Internal Testing

- [ ] Build available in internal Testers group
- [ ] Testing notes saved and visible
- [ ] Build installs on test devices

**Evidence from batch 4:** All three builds verified as `VALID / IN_BETA_TESTING` at 21:17 UTC on 14 September 2026.

---

## 7. Version Management

### 7.1 Version Numbers

| Key | Value | Notes |
| --- | --- | --- |
| `MARKETING_VERSION` | `1.0` | Keep at 1.0 for public release |
| `CURRENT_PROJECT_VERSION` | Increment per upload | Format: `YYYYMMDDHHMM` |

### 7.2 Consistent Across Targets

All five targets must use identical version numbers:

```bash
grep -E "MARKETING_VERSION|CURRENT_PROJECT_VERSION" project.yml
```

- [ ] All targets show same `MARKETING_VERSION`
- [ ] All targets show same `CURRENT_PROJECT_VERSION`

### 7.3 Before Upload

- [ ] Increment `CURRENT_PROJECT_VERSION` in `project.yml`
- [ ] Regenerate Xcode project: `xcodegen generate`
- [ ] Verify build numbers match in Xcode

---

## 8. App Store Metadata (Owner Action Required)

These items require owner action in App Store Connect before public submission.

### 8.1 App Information

| Field | Status | Notes |
| --- | --- | --- |
| App name | ⚠️ Required | "Gumbo Music" or "Gumbo" |
| Subtitle | ⚠️ Required | Short tagline |
| Category | ⚠️ Required | Music |
| Content rating | ⚠️ Required | Complete questionnaire |

### 8.2 Platform Descriptions

| Platform | Status |
| --- | --- |
| iOS description | ⚠️ Required |
| macOS description | ⚠️ Required |
| tvOS description | ⚠️ Required |

### 8.3 Screenshots

| Platform | Required Sizes |
| --- | --- |
| iPhone 6.9" | 1320 × 2868 or 1290 × 2796 |
| iPhone 6.5" | 1284 × 2778 or 1242 × 2688 |
| iPad 13" | 2064 × 2752 |
| Mac | 1280 × 800 minimum |
| Apple TV | 1920 × 1080 or 3840 × 2160 |

- [ ] At least 1 screenshot per platform
- [ ] Up to 10 screenshots per platform
- [ ] No placeholder or development screenshots

### 8.4 URLs (Owner Action Required)

| URL | Status | Current |
| --- | --- | --- |
| Privacy Policy URL | ⚠️ Required | Not published |
| Support URL | ⚠️ Required | Not published |

**Note:** Owner confirmed no public website or support contact exists yet. These must be published before public submission. See [PRIVACY-POLICY.md](PRIVACY-POLICY.md) for draft policy.

---

## 9. App Store Privacy Answers (Owner Action Required)

App Store Connect requires app-level privacy declarations separate from privacy manifests.

### 9.1 Data Types Declaration

Based on source review, Gumbo:
- Does not collect data for tracking
- Does not use third-party analytics SDKs
- Stores profile data in user's private CloudKit zone
- Does not transmit library data to developer servers

**Owner must confirm** any developer access outside the reviewed code (App Store analytics, TestFlight reports, support submissions) before publishing answers.

### 9.2 Apple TV Privacy Text

tvOS requires inline privacy policy text in App Store Connect. Copy the essential policy text for display.

- [ ] Privacy policy text entered in App Store Connect
- [ ] Text verified after save

---

## 10. App Review Preparation

### 10.1 Review Notes

Prepare notes explaining:
- How to access the sample library (if demo mode exists)
- NAS connection requirements
- Any special test account credentials

### 10.2 Demo Resources

| Option | Status |
| --- | --- |
| Demo mode with sample audio | Recommended |
| Test NAS account credentials | Alternative |
| Detailed review notes | Minimum |

### 10.3 Contact Information

- [ ] Review contact email set
- [ ] Phone number for expedited review (optional)

---

## Validation Evidence

### Completed Validations (Batch 4, 14 September 2026)

| Check | Result | Build |
| --- | --- | --- |
| iOS Release archive | ✅ Passed | 1.0 (202609142150) |
| macOS Release archive | ✅ Passed | 1.0 (202609142150) |
| tvOS Release archive | ✅ Passed | 1.0 (202609142150) |
| App Store export (all platforms) | ✅ Passed | 1.0 (202609142150) |
| Privacy manifests (all 5) | ✅ Present | 1.0 (202609142150) |
| CarPlay entitlement (binary) | ✅ Approved | 1.0 (202609142150) |
| CarPlay entitlement (profile) | ✅ Approved | 1.0 (202609142150) |
| TestFlight upload (iOS) | ✅ VALID | 1.0 (202609142150) |
| TestFlight upload (macOS) | ✅ VALID | 1.0 (202609142150) |
| TestFlight upload (tvOS) | ✅ VALID | 1.0 (202609142150) |
| Internal TestFlight group | ✅ IN_BETA_TESTING | All platforms |

Evidence: [REMEDIATION-2026-09-14-BATCH-4.md](REMEDIATION-2026-09-14-BATCH-4.md), [PR #36](https://github.com/svoltolini/gumbo/pull/36)

### Remaining for Public Release

| Item | Owner | Blocker |
| --- | --- | --- |
| Privacy policy URL | Owner | Yes |
| Support URL | Owner | Yes |
| App Store descriptions | Owner | Yes |
| Screenshots (all platforms) | Owner | Yes |
| App-level privacy answers | Owner | Yes |
| App Review demo/credentials | Owner | Yes |

---

## Automation Notes

### Pre-Upload Checklist Script

```bash
#!/bin/bash
# Run before every TestFlight upload

echo "=== Skyr Pre-Upload Validation ==="

# Check version consistency
echo "Checking version numbers..."
grep -E "CURRENT_PROJECT_VERSION:" project.yml | head -5

# Verify privacy manifests exist
echo "Checking privacy manifests..."
for manifest in Skyr/PrivacyInfo.xcprivacy \
                SkyrWidgets/PrivacyInfo.xcprivacy \
                SkyrWatch/PrivacyInfo.xcprivacy \
                SkyrMac/PrivacyInfo.xcprivacy \
                SkyrTV/PrivacyInfo.xcprivacy; do
  if [ -f "$manifest" ]; then
    echo "✅ $manifest"
  else
    echo "❌ $manifest MISSING"
  fi
done

echo "=== Validation Complete ==="
```

### CI Integration

For automated validation in CI:

1. Build all Release archives
2. Run `xcrun altool --validate-app` on exports
3. Verify entitlements with `codesign -d --entitlements`
4. Check privacy manifest presence in archives

---

## References

- [Apple: Distribute your app](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [Apple: App privacy details](https://developer.apple.com/app-store/app-privacy-details/)
- [Apple: Privacy manifest files](https://developer.apple.com/documentation/bundleresources/privacy_manifest_files)
- [Apple: App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Issue #13: Packaging validation](https://github.com/svoltolini/gumbo/issues/13)
- [Batch 4 evidence](REMEDIATION-2026-09-14-BATCH-4.md)
