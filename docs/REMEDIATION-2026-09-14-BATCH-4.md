# Skyr 1.0 — responsiveness and artwork privacy

Batch 4 addresses [#33](https://github.com/svoltolini/Skyr/issues/33) and the in-app work in [#14](https://github.com/svoltolini/Skyr/issues/14). Marketing version remains **1.0**; every target uses build **202609142150**.

## Changes

- Routine profile edits write a small ordered journal before publishing the new state. Full snapshot normalization, encoding and compression run on a serial background queue. Relaunch replays accepted edits with their original revisions, while checkpoint tokens prevent an older save from replacing newer state.
- Cloud document preparation runs outside the main actor. Account/generation and deletion checks still govern publication. Profile activation, remote merges and explicit recovery continue to use synchronous acknowledgement paths; this change does not move every profile operation off the main actor.
- Failed edits and failed background saves surface a profile-save error on iPhone/iPad, Mac and TV. A journal write failure rejects the edit; a snapshot failure retains its journal for recovery.
- Apple artwork lookup defaults off. Its consent file is local to the device, excluded from backup and separate from profile/iCloud settings. Both scanning and manual cover refresh use the same choice. Disabling cancels the URLSession transfer and invalidates late results before they can be cached.
- Onboarding and Settings explain the artist/album terms sent to Apple, ordinary connection information, and the distinction between NAS audio and iCloud profile data. Privacy Details works offline. Existing embedded, NAS and cached artwork remains available.
- The privacy text also explains family invitation-link access, credentials explicitly selected for Family Access, Watch credential transfer and local diagnostic backups. [The policy draft](PRIVACY-POLICY.md) and [store privacy inventory](PRIVACY-RELEASE-CHECK.md) are separate publication artifacts.

## Review and validation

Independent review corrected two persistence races: checkpoint cleanup competing with profile reads, and an older save error being shown after a newer revision. It also corrected artwork transport cleanup so cancellation reaches the actual URLSession task. Final integration review added account-generation checks after an asynchronous decode failure so an old account's remaining records and deletions cannot be applied.

The final combined candidate passed **190 Release package tests in nine suites**, including 12 new persistence fixtures, 11 artwork privacy/transport tests and the account-change/decode-failure regression. Independent review also ran a 14-case comparison against the established merge semantics and separately passed the final account-change regression. A child process journaled four synthetic edits and exited before checkpointing; two fresh processes recovered the exact original sync digest and values. Checkpoint replacement, failed writes, cleanup/read interleaving, stale completions, deletion and recovery are covered. The reviewed persistence/cloud source matched the final candidate and workspace.

Native Mac measurements used temporary Release builds from baseline `0595808f7f0a93d35f393dfd8c9774f3baa593c2` and the candidate on an Apple M5 Max running macOS 26.6.2. Isolated 5,000- and 15,000-track catalogues used local WAV audio and mocked CloudKit. After startup, each run issued 48 section changes and next-track commands, with a requested 500 ms pause between iterations. The first seeding edit and flush were excluded. Only the four `*-measured-summary.json` cases are reported below; exact statistics, counts, source hashes and methodology are retained in [the compact evidence](evidence/batch-4-performance.json).

| Tracks / build | Profile edit median / p95 (ms) | Flush call median / p95 (ms) | Command p95 (ms) | Navigation loop (s) |
| --- | ---: | ---: | ---: | ---: |
| 5,000 baseline | 47.624 / 59.199 | 45.940 / 47.067 | 60.327 | 25.499 |
| 5,000 candidate | 0.512 / 0.809 | 0.009 / 0.012 | 4.288 | 24.886 |
| 15,000 baseline | 147.224 / 162.543 | 141.837 / 143.697 | 151.844 | 36.667 |
| 15,000 candidate | 0.506 / 0.711 | 0.010 / 0.013 | 3.226 | 34.293 |

These are synchronous call durations, not complete frame-rendering times. A candidate flush schedules a background checkpoint after edits are journaled; its short duration is not the snapshot's completion time. Persistence preparation matches the final implementation after removing temporary timing probes and the final error-message wording. The fixture mocks CloudKit and predates the final guard against an old account's page continuing after an asynchronous decode failure, as well as the last wording and UI-only fixes. Those changes do not alter the timed routine profile calls.

Instruments recorded Hitches and Time Profiler data, but no SwiftUI view-body detail. The candidate traces still contain long stalls, reaching **516.666 ms at 5,000 tracks and 1,333.332 ms at 15,000 tracks**, during the native playback/navigation run. Whole-trace hitch counts are not a controlled before/after comparison: durations, activity and flush counts differ, and the traces include startup and window/compositor work. Routine profile persistence is improved and its durability checks pass; global UI smoothness is not established. [#35](https://github.com/svoltolini/Skyr/issues/35) tracks the remaining navigation stalls and separate profiling of cold profile activation and incoming remote merges.

On an iPhone 17 Pro simulator running iOS 26.5, the default-off choice and offline policy were checked at standard and Accessibility Extra Large text sizes. The disclosure and buttons remain readable, and the welcome screen is hidden from accessibility while onboarding is presented. On Apple TV 4K / tvOS 26.5, remote focus, full-screen privacy text, scrolling and Back were checked. Both signed simulator Release builds passed. Mac runtime, physical touch/VoiceOver, NAS and playback-device journeys remain in the acceptance matrix.

## Signed release artifacts

The final source, including the account-change correction, passed iOS (with Watch/widgets), universal Mac and TV Release archives and App Store exports. All five app/extension bundles are **1.0 (202609142150)**, include their privacy manifests and pass signature verification. Exported CloudKit environments are Production; development debugging is disabled. The iPhone signature and provisioning profile both contain the approved CarPlay audio entitlement. TV reports only the expected skipped AppIntents extraction notice.

[Export verification](evidence/batch-4-export-verification.json) records package hashes and bundle checks. The frozen source manifest matched after archiving. An earlier, unuploaded candidate was superseded by the final account-change correction. TestFlight processing and availability will be recorded here after Apple's checks finish.

The tests use synthetic profiles, ordinary local audio and intercepted artwork requests. They do not send personal library terms to Apple or connect to a live NAS. Axiom HIG, SwiftUI performance and accessibility guidance informed the controls and profiling procedure, using the previously reviewed reference revision `71d342b65068d45787f5b6f45ce9deaf58f9629d`.

## Public release work remains

The owner confirmed no public website or support contact exists yet. App Store Connect's privacy-policy URL/text and public description/support fields are unset; this does not prevent the authorized internal TestFlight batch. Complete and publish the policy and app-level privacy answers before public submission. #14 remains open until those acceptance items are finished.

[#34](https://github.com/svoltolini/Skyr/issues/34) tracks Apple's artwork usage terms. The archived Search API documentation constrains promotional artwork use and specifies adjacent store links/badges. Consent alone does not establish usage rights. Confirm the permitted use or omit external Apple artwork from the public release.

The existing all-platform TestFlight acceptance matrix in #12 still covers real NAS/CloudKit, Watch transfers, CarPlay, accessibility and network interruption. Local tests and Mac fixture measurements do not complete those device/provider checks.
