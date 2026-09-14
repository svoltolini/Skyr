# Skyr 1.0 release audit

Date: 14 September 2026

Target public-release weekend: 19–20 September 2026

Audit baseline: `73f85b74ab60a9707de2f744161b172d21ef5b4e`

Repository: [svoltolini/Skyr](https://github.com/svoltolini/Skyr) (private)

Follow-up: the owner approved remediation and the six private security issue payloads. See the [first remediation batch](REMEDIATION-2026-09-14.md) for current implementation, verification, and the missing scan-artifact publication blocker. The findings and results below preserve the original audit checkpoint.

## Release assessment

Skyr is not ready for an unrestricted public 1.0 release at this checkpoint. The source compiles in Release configuration, the signed iPhone and Apple TV simulator experiences are visually coherent, and the app architecture is suitable for the intended product. The audit found failures in Watch downloads, offline download truthfulness, NAS/cache identity, interrupted indexing, two-factor reconnection, CloudKit convergence, profile authorization, and distribution validation.

The GitHub backlog contains 31 verified product, reliability, UX, accessibility, and release tasks. A separate sealed Codex Security scan contains six validated findings; their exact private GitHub issue payloads await owner review.

## What was reviewed

- All 186 tracked files were inventoried.
- All 103 Swift files, about 20,000 lines, were mapped across the five application/extension targets and shared package.
- Networking, indexing, metadata parsers, playback, downloads, profiles, family sharing, CloudKit, widgets, Watch transfer, platform navigation, entitlements, privacy manifests, assets, and release settings received targeted source review.
- Critical download and state transitions were reproduced in isolated source harnesses under `/tmp`; they did not touch a NAS, CloudKit, the user's library, or repository source.
- Signed iPhone and Apple TV Release simulator builds were exercised with the built-in sample catalogue; the iPhone pass also used synthetic profiles.
- Current Apple TestFlight/App Review and Tailscale guidance was checked against official documentation.

## Verification completed

| Check | Result | Boundary |
| --- | --- | --- |
| Shared Swift package, Release | Passed | One existing nested-folder test |
| iOS/iPadOS Release build | Passed | Includes embedded Watch app and widgets |
| macOS Release build | Passed | Compile only |
| tvOS signed Release build and launch | Passed | Fresh isolated tvOS 26.5 simulator with sample library; asset warnings remain |
| Signed iPhone simulator launch | Passed | Fresh isolated iOS 26.5 simulator |
| iPhone UI smoke | Passed | Library, album, simulated playback, search, playlists, and settings rendered |
| Profile PIN isolation | Failed | Owner PIN removal bypass reproduced end to end |
| Reduce Motion | Failed | Smart-playlist decorative motion remained active |
| Compact three-profile iPhone layout | Passed at standard text | Earlier arithmetic-only suspicion withdrawn |
| Codex Security scan | Completed | 6 findings: 3 medium, 3 low; source coverage remains partial where live services are required |

The first unsigned simulator launch failed because the audit artifact lacked CloudKit entitlements. Rebuilding with Xcode-managed simulator signing resolved it. This was a harness problem and is not recorded as a shipping defect.

## Public-release blockers

The following GitHub issues carry `priority:P1` and `release:blocker`:

1. [Watch downloads fail for normal nested NAS paths](https://github.com/svoltolini/Skyr/issues/1)
2. [Real offline downloads can be falsely marked as complete](https://github.com/svoltolini/Skyr/issues/2)
3. [Downloaded audio cache can return a file from another NAS](https://github.com/svoltolini/Skyr/issues/3)
4. [Partially failed refresh can replace the full library with a subset](https://github.com/svoltolini/Skyr/issues/4)
5. [Cancelled scan can publish stale catalogue and connection state](https://github.com/svoltolini/Skyr/issues/5)
6. [DSM two-factor accounts cannot reauthenticate after restore or reconnect](https://github.com/svoltolini/Skyr/issues/6)
7. [CloudKit sync state is not reset or scoped when the Apple Account changes](https://github.com/svoltolini/Skyr/issues/7)
8. [Offline or failed profile deletion is never retried in CloudKit](https://github.com/svoltolini/Skyr/issues/8)
9. [CloudKit cursor advances past failed record changes](https://github.com/svoltolini/Skyr/issues/9)
10. [Whole-document CloudKit conflict policy loses independent profile edits](https://github.com/svoltolini/Skyr/issues/10)
11. [Cancelled or superseded sign-in can still mutate the active connection](https://github.com/svoltolini/Skyr/issues/11)
12. [Run the signed TestFlight acceptance matrix on every shipping platform](https://github.com/svoltolini/Skyr/issues/12)
13. [Complete App Store packaging and capability validation for every target](https://github.com/svoltolini/Skyr/issues/13)
14. [Correct privacy copy and disclose external artwork lookup](https://github.com/svoltolini/Skyr/issues/14)
15. [Enforce profile lock across widgets, snapshots, and Watch handoff](https://github.com/svoltolini/Skyr/issues/15)

Five of the pending security issues also carry release-blocker priority in their exact preview: automatic HTTP credential transport, malformed metadata termination, failed family revocation, owner PIN removal, and cross-NAS family credential scoping. The oversized-cover allocation finding is P2.

## Important follow-up

- Downloads and playback: [#16](https://github.com/svoltolini/Skyr/issues/16), [#17](https://github.com/svoltolini/Skyr/issues/17), [#18](https://github.com/svoltolini/Skyr/issues/18), [#19](https://github.com/svoltolini/Skyr/issues/19), [#20](https://github.com/svoltolini/Skyr/issues/20)
- Catalogue and metadata: [#21](https://github.com/svoltolini/Skyr/issues/21), [#22](https://github.com/svoltolini/Skyr/issues/22), [#23](https://github.com/svoltolini/Skyr/issues/23), [#25](https://github.com/svoltolini/Skyr/issues/25)
- Platform UI and accessibility: [#24](https://github.com/svoltolini/Skyr/issues/24), [#26](https://github.com/svoltolini/Skyr/issues/26), [#27](https://github.com/svoltolini/Skyr/issues/27), [#28](https://github.com/svoltolini/Skyr/issues/28), [#30](https://github.com/svoltolini/Skyr/issues/30)
- NAS onboarding: [#29](https://github.com/svoltolini/Skyr/issues/29)
- Build hygiene: [#31](https://github.com/svoltolini/Skyr/issues/31)

## Tailscale recommendation

Recommend Tailscale as an optional guided route for remote NAS access. It avoids asking ordinary users to open router ports, and Synology users can install it from Package Center. The app should accept a Tailscale IP or full MagicDNS hostname, show the effective transport, and keep DSM authentication separate from Tailscale device access.

This should be onboarding and route-selection work, not an embedded VPN integration for the first release. The current private-address heuristic does not classify Tailscale's `100.64.0.0/10` range as local, so copy and probe order need an explicit route model. Independent Apple Watch remote access is not yet verified and should not be promised.

Official references:

- [Tailscale on Synology](https://tailscale.com/docs/integrations/synology)
- [Access NAS and media servers](https://tailscale.com/docs/use-cases/personal-or-at-home-use/access-nas-media-file-servers)
- [MagicDNS](https://tailscale.com/docs/features/magicdns)
- [Sharing Tailscale nodes](https://tailscale.com/docs/features/sharing)
- [Reserved Tailscale address range](https://tailscale.com/docs/reference/reserved-ip-addresses)

## TestFlight and versioning

- Keep `MARKETING_VERSION` at `1.0`.
- Increment `CURRENT_PROJECT_VERSION` for every upload and keep the value aligned across iOS, widgets, Watch, Mac, and Apple TV.
- Test one focused batch per build and attach the build number to every result.
- Do not treat a later build of the same version as guaranteed to avoid review. Apple says later builds may not require a full review, and every upload still has processing and eligibility checks.

Official references:

- [Invite external TestFlight testers](https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers)
- [Upload builds](https://developer.apple.com/help/app-store-connect/manage-builds/upload-builds)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)

## Required acceptance evidence

Before making 1.0 public, record all of the following against the exact TestFlight build:

- Real iPhone and iPad, Mac, Apple TV, and paired Watch.
- Controlled Synology DSM versions, standard and 2FA accounts, least-privilege family account, LAN, Tailscale if offered, and public HTTPS if supported.
- Initial scan, partial failure, refresh, folder change, NAS restart, session expiry, sign-out/server switch, and recovery.
- Streaming, seeking, next-track transitions, offline download/playback, background completion, Live Activity, widget action, AirPlay, and Watch independent playback.
- Two Apple Accounts exercising owner/member invitation, profile edits, simultaneous offline changes, deletion, revocation, and account switch.
- Accessibility text sizes, VoiceOver, Reduce Motion, keyboard/remote focus, six profiles, and long/Unicode names.
- Distribution archives, signed entitlements, privacy manifests, App Store metadata, review resources, and zero unexplained warnings.

## Recommended work order

1. Fix profile authorization, secure transport, family revocation, and NAS-scoped identity.
2. Fix Watch/offline downloads and interrupted-indexing data integrity.
3. Fix CloudKit account scoping and convergence.
4. Upload a build-number-only TestFlight candidate and run the full real-device/provider matrix.
5. Complete distribution metadata and capability validation.
6. Finish motion, accessibility, navigation, and copy work, then repeat focused regression passes.

No product source fix was made during this audit. The only repository changes are Git setup, ignore rules, this README, and this audit record.
