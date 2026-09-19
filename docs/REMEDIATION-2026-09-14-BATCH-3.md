# Gumbo 1.0 — third remediation batch

Date: 14 September 2026. Base: `f284565b289ae3dd048726516eb112d913e2728a`.

This continues [batch 2](REMEDIATION-2026-09-14-BATCH-2.md) in [PR #32](https://github.com/svoltolini/gumbo/pull/32). Marketing version stays **1.0**. The candidate build is **202609142035** on all five targets.

## Changes

- **Playback, #18:** retry resolves an unavailable or failed source again, while a healthy paused item resumes in place. Playback status follows readiness and seek completion. Shared command revisions prevent a delayed CarPlay or widget request from replacing a newer command. Explicit commands and headphone removal cancel interruption resume.
- **NAS identity, #3:** catalogue, credentials, family access and download lookup distinguish the canonical scheme, hostname, effective port and account. A confirmed recovery flow can copy older favourites, playlists and history into the selected library while preserving its existing changes and the original saved state. Old cached audio is not relabelled. Older hostname-only credentials require a fresh sign-in.
- **Transport and onboarding:** discovery and bare addresses prefer HTTPS. HTTP requires an explicit choice for that exact origin, including Watch downloads. Ordinary request redirects cannot change origins; queued downloads recheck permission immediately before starting. Tailscale remains an optional connection route, not proof that a connection is encrypted or authorised.
- **Family access:** only credentials verified for the current NAS source are offered. Sharing removal requires CloudKit acknowledgement before rotating the NAS password. Failed changes preserve a saved pending state and recovery instructions; retries cannot switch Apple Account, family, NAS or profile session. Missing legacy credentials do not produce a false success result.
- **CloudKit, #10:** profile settings, favourites, playlist fields and membership have explicit merge metadata. Conflicts merge and retry against the returned server record; local edits made during an upload remain pending. Unreadable profile documents are preserved. History uses a bounded set of observed events, including a repeat of the current first item. Large CloudKit documents use a bounded, versioned compressed envelope in the existing Data field, without a schema change. Independent review corrected payload size and quadratic sequence work.
- **CarPlay and packaging, #13:** Apple approved the audio entitlement and the App ID capability was enabled. The project includes it. CarPlay refreshes after library and profile changes, revalidates delayed selections, respects template item limits and handles asynchronous template failures. tvOS has a privacy manifest and both required 1× and 2× Top Shelf images, including the wide format. Watch icons are in a separate catalog, preserving their compiled image digests and eliminating a Mac archive warning.
- **Compiler diagnostics, #31:** SwiftUI closures capture immutable values rather than crossing actor boundaries through mutable bindings. Swift 6 isolation checks remain enabled.

## Verification and distribution

| Check | Result and boundary |
| --- | --- |
| Final shared package | **165 Release tests passed**, seven suites. Current package files exactly match the tested isolated snapshot. Includes 14 family access cases, 25 playback cases, four recovery integration cases, scoped transport/queued-download checks, merge/convergence and previous regression coverage. No real NAS or CloudKit mutations. |
| Independent final review | No remaining blocker in the reviewed playback, family access and cloud corrections. Cloud review additionally passed 216 three-way history merge orders and 120 playlist reorder permutations. |
| Large profile | 15,000-song CloudKit payload approximately 630 KB, with matching round-trip digest. Initial processing improved from about 5.73 s to 0.62 s in the reviewer fixture. Ordinary history update plus encoding remains about 50 ms at 5k / 165 ms at 15k; tracked in [#33](https://github.com/svoltolini/gumbo/issues/33). These are command-line timings, not device frame traces. |
| Final iOS archive | Passed with embedded Watch and widgets; all version 1.0 / build 202609142035. No project-source or asset warnings. |
| Final macOS archive | Passed; no project-source or asset warnings. |
| Final tvOS archive | Passed; no project-source or asset warnings. Xcode emits its expected skipped App Intents extraction message because this target has no AppIntents dependency. |
| Packaging | Every app/extension archive contains its privacy manifest. The exported iPhone binary and App Store distribution profile include CarPlay audio; executable uses production CloudKit and is not debuggable. The 17 compiled Watch images retain their original pixel digests and slot mappings after catalog separation. |
| Whitespace | Passed. |

Final archive/export/upload evidence is under `/tmp/skyr-remediation-3/final`; core tests are in `/tmp/skyr-remediation-3/cloud-final-package.log`, independent cloud checks in `/tmp/skyr-remediation-3/cloud-review`, and icon checks in `/tmp/skyr-remediation-3/icon-diagnosis`.

iOS and macOS uploads were accepted and processed as VALID, with internalBuildState IN_BETA_TESTING and membership in the existing internal Testers group verified through the API. Their testing notes were updated and read back. The first tvOS upload was rejected for a missing 1× wide Top Shelf image; both 1× sizes were then derived from the existing 2× artwork with the owner's explicit approval. The corrected exported TV asset catalog and signature were checked before retrying. These TV-only assets are absent from the iOS and Mac compiled catalogs and do not alter their accepted builds. The corrected TV upload was accepted (delivery `809d9258-05cd-4f9b-8cde-8d0667ccd2e3`). All three platforms now report VALID and IN_BETA_TESTING, and membership in the internal Testers group was verified. Testing notes were saved and read back for all three. External beta state is READY_FOR_BETA_SUBMISSION; no external beta review or public App Store release is claimed.

App Store Connect was read through the existing team API key. No App Store Connect MCP tool is installed in this environment. The API confirmed the app identifier, existing iOS/macOS build `202609141324`, and the internal testing group. Routine build and testing-group operations use the API or Apple's command-line tools; browser access was needed to find the existing issuer identifier and enable the newly approved CarPlay capability.

## Git and release record

[PR #32](https://github.com/svoltolini/gumbo/pull/32) merged as `f18ea5915345a3e7f46cb16a6eeb09cbeb644a64`; batch 3 implementation is `328eb011835fb11b14858afb8bbf404de3ca7cae`.

Closed with verification evidence: **#2, #4, #5, #11, #18, #22, #31**. **25 issues remain open**, including new performance follow-up #33. Twenty implemented/partial issues received explicit remaining-acceptance notes; open state does not mean no work was merged.

| Platform | Build ID | Confirmed state |
| --- | --- | --- |
| iOS, companion Watch and widgets | `425639f9-7888-4770-a16c-cba48dfc2fd8` | 1.0 (202609142035), internal testing |
| macOS | `9f1c513a-d2bb-434a-b74b-aad8d1e980fd` | 1.0 (202609142035), internal testing |
| tvOS | `809d9258-05cd-4f9b-8cde-8d0667ccd2e3` | 1.0 (202609142035), internal testing |

Next recommended batch: large-library responsiveness (#33) and privacy/artwork disclosure (#14), while the owner exercises this build's NAS, CloudKit, Watch and CarPlay journeys. Finish App Review readiness in #13 before public submission.

## Required device acceptance

- Put **every device used for CloudKit testing on this build**. Older TestFlight builds write whole snapshots without deletion metadata; mixed old/new writers cannot guarantee preservation of deletion intent. Older builds also cannot read the compressed envelope used for larger documents. The updated reader accepts both formats. Verify offline independent edits, deletions, playlist reordering, relaunch and convergence on two devices.
- Test NAS sign-in, 2FA expiry, HTTP choice, remote access, interrupted refresh and a source change with the same paths. After upgrading, confirm saved-library recovery and download music again where older source identities were unscoped.
- Test actual background transfer termination/relaunch, Watch download/playback, Live Activities, voice/remote input, CarPlay connection/reconnection and audio interruptions.
- Confirm accessibility speech, keyboard/focus navigation, Reduce Motion and frame times on supported hardware. Compiling and rendering do not establish smooth animation performance.

Family pending-state tests recreate the model against isolated saved preferences; actual process termination and recovery remain device acceptance. Changing a family password does not necessarily end already established DSM sessions. The app explains that DSM may also need to terminate them. Cached audio on a disconnected Watch remains separately tracked in #15. Background URLSession redirects are handled by the operating system and do not invoke the ordinary redirect delegate; this batch does not claim universal redirect enforcement for those transfers.

Public App Store release is separate from the authorised TestFlight upload. Store metadata, privacy disclosures, review access and the all-platform acceptance matrix remain in #12–#14. Gapless behaviour (#20), metadata refresh (#23), remaining onboarding (#29) and platform copy (#30) are subsequent work.

The six approved security ticket writes retain the source-integrity limitation documented in [batch 1](REMEDIATION-2026-09-14.md#approved-security-issue-publication). No missing sealed preview was reconstructed or represented as the approved original.
