# Skyr 1.0 — first remediation batch

Date: 14 September 2026

Base: `1f77fdb7fa9b5a4175931738f6865df2dcfeed6c`

Branch: `codex/release-blockers`

This is an implementation candidate following the [release audit](RELEASE-AUDIT-2026-09-14.md). The owner approved starting fixes and creating the six previously previewed private security issues. Public-release readiness has not been established. Keep the related issues open until the candidate is reviewed, merged, and its required device/provider checks pass.

## Changes and issue coverage

| Issues | Candidate behavior | Remaining acceptance |
| --- | --- | --- |
| [#1](https://github.com/svoltolini/Skyr/issues/1), [#16](https://github.com/svoltolini/Skyr/issues/16) | Watch task metadata preserves nested and Unicode NAS paths. Safe local filenames and manifests are scoped to NAS, profile, playlist, and transfer generation. Availability checks verify actual files, expected size, and server-error responses. Open playlist screens resolve current membership. Partial downloads can be removed. | Paired Watch transfer, background relaunch, independent playback, disk-full recovery. Old unscoped Watch downloads require a fresh download. |
| [#2](https://github.com/svoltolini/Skyr/issues/2), [#3](https://github.com/svoltolini/Skyr/issues/3) | A real track without a usable source reports an error. Sample simulation is explicit and never persisted as a real file. Downloads and pending jobs use NAS-scoped keys, including offline reads and legacy record migration. | Two real NAS libraries containing identical paths. The underlying NAS identifier still uses hostname; same-host different-port/account identity needs further work. |
| [#4](https://github.com/svoltolini/Skyr/issues/4), [#5](https://github.com/svoltolini/Skyr/issues/5) | An unreadable folder prevents partial refresh publication. Cancelled or superseded scan/enrichment callbacks cannot replace newer catalogue state or write covers. A failed refresh displays a retry banner while preserving the existing library. | NAS interruption during a large scan and device performance. |
| [#6](https://github.com/svoltolini/Skyr/issues/6), [#11](https://github.com/svoltolini/Skyr/issues/11) | Session restoration/reconnect can request password and OTP again, preserving a matching cached library. Cancellation, server selection, and folder changes invalidate suspended sign-in work. Orphan sessions are logged out. | Real DSM 2FA, expired sessions, and all platform reauthentication sheets. |
| [#21](https://github.com/svoltolini/Skyr/issues/21), [#22](https://github.com/svoltolini/Skyr/issues/22) | Cached catalogue reuse requires the selected hostname and exact music folder. Cover writes recreate cleared directories and serialize reset/write operations. | Folder switching and cover refresh on a real library. Broader connection identity remains as described above. |
| Owner PIN security finding | Profile activation validates the canonical PIN; management requires an authenticated eligible profile. Biometric results revalidate current state. Edits are tied to their opening session and profile revision. Remote PIN changes lock active access and revoke biometric enrollment. | Biometric hardware, remote profile changes, and owner/member journeys on two Apple Accounts. |
| [#15](https://github.com/svoltolini/Skyr/issues/15), partial | Widget data and covers require a current persisted profile-session authorization. Startup/lock revokes new reads and stale publication. Widget playback rechecks the profile session after awaiting connection. New Watch handoff requires an open profile. | WidgetKit controls removal of already rendered timelines. Revocation of cached data/credentials on a disconnected Watch is still outstanding. |
| [#17](https://github.com/svoltolini/Skyr/issues/17), partial | Shared pending ownership is persisted, cancellation removes the cancelling owner, and completion no longer unconditionally restores that owner. Startup callback ordering protects legacy background downloads during migration. | Immediate cancel/retry attempt identity and process-termination tests still need work. |
| [#19](https://github.com/svoltolini/Skyr/issues/19), partial | Download failures are presented in iPhone/iPad and Mac UI. | Live Activity still needs distinct failed/cancelled/completed terminal states. |
| [#24](https://github.com/svoltolini/Skyr/issues/24), [#25](https://github.com/svoltolini/Skyr/issues/25) | Go to Album switches the Mac/TV section before navigating, including repeated requests. Search refreshes when derived catalogue contents change; stale derivation cannot repopulate a cleared library. | Remote/keyboard navigation and unchanged-query results during a real refresh. |
| [#26](https://github.com/svoltolini/Skyr/issues/26) | Artwork motion, flips, zooms, focus/transport effects, download celebrations, and PIN shaking respect Reduce Motion. PIN errors also have visible text. | Physical-device motion, VoiceOver, and frame-time assessment. Simulator rendering alone does not establish animation smoothness. |

## Verification

| Check | Result | Evidence boundary |
| --- | --- | --- |
| Shared package, Release | 46 tests passed | Connection lifecycle, scan cancellation/partial failure, cover reset, profile policy, download ownership/restoration, Watch manifests, widget authorization, and search revision fixtures. Temporary storage; no real NAS or CloudKit requests. |
| iOS/iPadOS Release | Build passed | Includes the embedded Watch app and widget extension, arm64 simulator signing. |
| macOS Release | Build passed | arm64 compilation with signing disabled; no Mac runtime claim. |
| tvOS Release | Build passed | arm64 simulator signing. |
| iPhone and Apple TV launch | Passed | Fresh iOS/tvOS 26.5 simulators opened the sample library; library screen screenshots were visually checked. This is a launch/render smoke check, not interaction or performance acceptance. |
| Diff whitespace | Passed | No whitespace errors. |

Existing asset/concurrency warnings remain tracked in #13 and #31. No distribution archive, TestFlight upload, real NAS session, CloudKit multi-account test, biometric hardware test, or paired Watch runtime test was performed by this batch.

## Outstanding work

CloudKit account scoping, deletion retries, cursor handling, and conflict reconciliation remain open in #7–#10. Also outstanding: playback retry (#18), gapless behavior (#20), same-size metadata updates (#23), Mac slider accessibility (#27), profile layout (#28), Tailscale onboarding (#29), platform copy (#30), Release warnings (#31), privacy disclosures (#14), packaging (#13), and the full TestFlight acceptance matrix (#12).

The other security findings — transport selection, bounded metadata/artwork handling, family revocation, and family credential source scoping — remain unresolved. This batch implements the owner-PIN change only.

## Approved security issue publication

The six issue writes remain unprocessed. The original temporary sealed scan bundle and exact preview file are no longer present. Codex Security still returns the six normalized workbench findings for scan `f3adaf31-9aee-4070-a450-f4cb8a8ac159`, but its completed-report retrieval fails because the artifact root is missing. Normalized workbench records are not a replacement for the original sealed tracking source.

The security tracking workflow requires validating that sealed source immediately before each write and confirming the exact approved payload. The approval is recorded; it is not being requested again. No replacement scan or changed payload has been presented as the approved original, and no security issue creation is claimed here. This publication problem does not prevent source fixes.

## TestFlight

Marketing version remains **1.0**. This batch does not yet create a TestFlight upload. Increment only the build number, consistently across all five targets, when preparing the next signed upload; check the latest uploaded build first rather than assuming local build 1 is current in App Store Connect.

The first device pass should concentrate on connection recovery, interrupted scans, offline downloads, profile switching/locking, widgets, and Watch playlist transfer. Attach the exact build number and actual device/NAS/account details to the results in #12. Package and simulator checks do not substitute for those results.
