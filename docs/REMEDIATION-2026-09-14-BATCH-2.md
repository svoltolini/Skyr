# Gumbo 1.0 — second remediation batch

Date: 14 September 2026

Base: `e7510e9519761ef4f7cc282c141592a6a5d6b6af`

Branch: `codex/release-blockers`; [draft PR #32](https://github.com/svoltolini/gumbo/pull/32).

This continues the [first batch](REMEDIATION-2026-09-14.md). Related issues remain open for review, merging, and the outstanding device/provider acceptance. This is not public-release approval.

## Changes

| Issues | Candidate behavior | Remaining acceptance |
| --- | --- | --- |
| #7 | Sync metadata is stored atomically per verified Apple Account, with separate family-zone tokens, record tags, timestamps, deletion intents, and account subscription state. Account changes invalidate pending work and lock active profile access. Local profile provenance prevents a second account from uploading, rebinding, or changing the first account's profile roles. Offline creation persists its known account association. Unassigned recovery profiles bind durably to one account before adoption. | Live A → signed out → B and A → B journeys, owner/member roles, offline relaunch, two devices. Local profile files remain on the device; this is not a complete migration into separate account data directories. |
| #8 | Profile deletion first persists intent for both CloudKit records. Partial acknowledgements and pending deletions survive relaunch; retained tombstones suppress returned records and reconcile local removal after an interrupted save. Previously verified context permits offline deletion without asserting a currently signed-in identity. Last-profile removal saves a fresh replacement without reimporting legacy settings. | Offline deletion and eventual convergence against real CloudKit, including disk pressure and shared-zone removal. |
| #9 | A failed page entry or local application failure retains the preceding cursor. Successful entries replay idempotently, and later pages wait for the current page to succeed. | Real multi-page change delivery and recovery after connectivity changes. Whole-document conflict reconciliation remains #10. |
| #17 | Every transfer has a durable attempt ID and isolated incoming file. Cancellation retires the attempt immediately; late callbacks cannot affect its retry. Ownership and attempt intent are one atomic document. Explicit retry replaces a saved attempt absent from restored tasks. | Physical background-session termination/relaunch, force quit, overlapping profiles/playlists, storage exhaustion. |
| #19 | Downloads distinguish completed, failed, partial, and cancelled requests. Retained errors and retry actions preserve already saved songs. Live Activities count saved files and serialize progress before truthful terminal messages; failed activity creation can be retried. | All-success, partial/complete failure, cancellation and activity handoff on an actual iPhone. |
| #27 | Native Mac sliders identify playback position and volume, expose time/percentage values, avoid duplicate decorative announcements, and seek for keyboard/VoiceOver changes outside a mouse drag. | Actual VoiceOver speech and keyboard behavior. |
| #28, #26 follow-up | A single profile grid adapts to available width, scrolls when needed, wraps long names, and preserves button identity. Scaled dimensions accommodate larger text. Hover and track transitions respect Reduce Motion. | Narrow/wide iPad and Mac windows, TV focus/remote navigation, accessibility sizes, and physical-device motion/performance. |

## Media safety fixes

The MP4/ID3 changes check spans before arithmetic, integer conversion, and slicing. They reject incomplete declared regions, validate optional frame/descriptor prefixes, cap complete tag regions, and avoid reintroducing unsafe bitrate arithmetic in the indexer's fallback. Valid MP4 box widths and EOF-sized atoms, versioned duration headers, AAC/ALAC details, text tags, and artwork remain covered by ordinary fixtures.

NAS whole-file artwork downloads now consume a bounded async byte stream. Both advertised size and bytes actually received are checked. The underlying URLSession task is cancelled on exit, error, and caller cancellation. Ranged reads also cancel after collecting their requested window. These loops explicitly run off the main actor.

An independent source investigation preceded edits. A separate read-only patch review found an unguarded bitrate fallback in the indexer; that caller now uses the same checked helper. Verification uses pure boundary calculations, ordinary valid media, and small bounded byte sequences. No original malformed/crash reproduction was run. These checks do not establish a total process-memory bound for Foundation, image decoding, AVFoundation, or third-party artwork lookup paths.

The metadata and oversized-artwork findings have source fix candidates. Transport selection, failed family revocation, and family credential source scoping remain unresolved. Disconnected Watch cache/credential revocation also remains open under #15.

## Axiom guidance

Applied the [Axiom Codex guidance](https://charleswiltgen.github.io/Axiom/start/codex-install) from source revision `71d342b65068d45787f5b6f45ce9deaf58f9629d`: HIG, adaptive layout, SwiftUI animation, and accessibility. The references were read outside the repository; no global skill installation or installation scripts were run.

Concrete applications are native slider semantics, a stable layout that adapts to available space, long-name wrapping, and scoped motion with Reduce Motion support. SDK 26.5 remains the build target. Simulator screenshots and successful builds cannot establish smooth frame times; Instruments and device acceptance remain necessary for that claim.

## Verification

| Check | Result | Evidence boundary |
| --- | --- | --- |
| Shared package, Release | **94 tests passed** in four suites | Includes 26 Cloud tests, transfer identity/restoration and truthful outcomes, pure media bounds, valid media controls, and bounded byte sequences. Isolated storage and injected Cloud services; no real NAS or CloudKit changes. |
| iOS/iPadOS Release | Passed | arm64 simulator build, including embedded Watch app and widgets/ActivityKit. |
| macOS Release | Passed | arm64 build with signing disabled; no Mac runtime/VoiceOver claim. |
| tvOS Release | Passed | arm64 simulator build with signing enabled. |
| Six-profile rendering | Passed for inspected layouts | Fresh iPhone 17 Pro, iPad Pro 11-inch, and Apple TV 1080p simulators on OS 26.5, with six synthetic profiles and long names. iPhone also inspected in dark mode at the largest accessibility text size; final profile activated through its accessibility target. |
| TV navigation | Passed for inspected journey | Simulator directional keys moved to the lower row, scrolled long labels into view, reached the sixth profile, and opened the sample library. Physical remote behavior remains pending. |
| Independent reviews | Findings corrected | Separate source reviews of media, download, and Cloud changes. Cloud follow-up confirmed the scoped review corrections; runtime provider acceptance remains pending. |
| Diff whitespace | Passed | No whitespace errors. |

Local run evidence is under `/tmp/skyr-remediation-2/`: `package-final.log`, `ios-final-check.log`, `macos-final-check.log`, `tvos-final-check.log`, and simulator screenshots. Temporary simulators contained only synthetic/sample data. The package test run covers the final core changes; the subsequent profile-button accessibility trait was verified by platform builds and simulator accessibility inspection.

The final builds still report the existing captured-model warning in `LibraryView.swift` and the PhotosPicker actor-isolation warning in `ProfileEditorSheet.swift`; tvOS also reports skipped App Intents metadata extraction. No new compiler errors remain. Physical VoiceOver speech, iPad multitasking/Mac window resizing, touch scrolling at accessibility sizes, frame-time profiling, paired Watch, biometric hardware, live NAS/2FA, CloudKit convergence, and Live Activity/background-process acceptance are outstanding.

Missing shared-zone recovery offers a new invitation on iPhone/iPad and Mac. A full local reset/leave and family credential revocation remain separate work; the app does not silently move shared profiles or deletion intents into another family.

## Release and tracking limits

Marketing version remains **1.0**. No build number change, distribution archive, TestFlight upload, merge, or public deployment is included in this batch. Before the next upload, inspect App Store Connect's latest build and increment only the build number consistently across the five targets.

Existing asset/concurrency warnings remain tracked by #13/#31. Other remaining work includes #10 conflict reconciliation, #18 playback retry, #20 gapless behavior, #23 metadata refresh, #29 Tailscale onboarding, #30 platform copy, #14 privacy disclosures, and #12 all-platform TestFlight acceptance.

The six approved security issue writes remain unprocessed for the source-integrity reason recorded in the [first report](REMEDIATION-2026-09-14.md#approved-security-issue-publication): the original sealed scan bundle and exact approved preview are missing. This batch does not claim that those issues were published or that normalized finding records replace the approved source.
