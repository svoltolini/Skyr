# Gumbo P1 Board Status — 15 September 2026

This document records the verification of open P1 issues and security filing status following the earlier triage. It does not include TestFlight upload or marketing version changes.

## P1 Issues Verification

Issues marked "code done" in earlier triage were verified against main branch (`7454bc3`).

### #1 — Watch downloads fail for normal nested NAS paths

**Status:** FIX VERIFIED — awaiting Tester device pass

**Evidence:**
- `WatchDownloadJob` in `Packages/SkyrCore/Sources/SkyrCore/Models/WatchCatalogue.swift:82-108` uses structured JSON task metadata instead of path-based filenames
- `cacheID` property (line 74-78) creates source-scoped identifiers via `DownloadManager.cacheKey(trackID:driveID:)`
- Safe local filenames isolate by generation, profile and NAS source
- Test coverage in `Packages/SkyrCore/Tests/SkyrCoreTests/DownloadTests.swift:105-114`:

```swift
@Test func watchTaskMetadataPreservesNestedUnicodeNamesAndSeparatesSources() throws {
    let playlist = watchPlaylist()
    let job = try #require(WatchDownloadJob(playlist: playlist, track: playlist.tracks[0], generation: UUID()))
    #expect(WatchDownloadJob.decode(job.encoded) == job)
    #expect(!job.fileName.contains("/"))
    #expect(!job.fileName.contains("|"))
    #expect(playlist.cacheID != watchPlaylist(driveID: "nas-b").cacheID)
```

**Remaining acceptance:** Paired Watch transfer, background relaunch, independent playback

---

### #3 — Downloaded audio cache can return a file from another NAS

**Status:** FIX VERIFIED — awaiting Tester two-NAS journey

**Evidence:**
- `DownloadManager.cacheKey` in `Packages/SkyrCore/Sources/SkyrCore/State/DownloadManager.swift:349-363` uses length-delimited JSON encoding of `[driveID, trackID]` with SHA256 hash
- `DownloadRecord` (line 10-44) stores `driveID` and requires it for manifest loading
- Legacy manifests without `driveID` are pruned on load (line 991-994)

```swift
public nonisolated static func cacheKey(trackID: String, driveID: String) -> String {
    let data = (try? JSONEncoder().encode([driveID, trackID])) ?? Data()
    // SHA256 hash to create filesystem-safe identifier
```

**Remaining acceptance:** Two servers with identical paths, sign-out/reconnect/online/offline playback

---

### #7 — CloudKit sync state is not reset or scoped when Apple Account changes

**Status:** FIX VERIFIED — awaiting Tester live account journeys

**Evidence:**
- `CloudPersistence` stores per-account snapshots in `CloudAccountState`
- `accountChanged()` at `CloudSync.swift:120-138` invalidates generation, cancels uploads, resets all metadata
- Account-scoped subscription state and generation guards
- Test coverage in `CloudReliabilityTests.swift:127-170`:

```swift
@Test @MainActor func cloudAccountSnapshotsSeparateOwnerMemberCursorsAndSubscriptionsAcrossRelaunch() async throws {
    // Verifies A → signed out → B journey with separate cursors, subscriptions
    #expect(fixture.sync.membership == .member)
    #expect(stateB.zones["family-A"] == nil) // B's state doesn't have A's zone
```

Additional tests: `cloudDirectAccountChangeDoesNotUploadOrRebindAnotherAccountsProfiles`, `cloudAccountChangeDiscardsASuspendedPageBeforeAnyApplication`

**Remaining acceptance:** Live A → signed out → B and A → B owner/member journeys on two devices

---

### #8 — Offline or failed profile deletion is never retried in CloudKit

**Status:** FIX VERIFIED — awaiting Tester offline deletion convergence

**Evidence:**
- `prepareProfileDeletion` at `CloudSync.swift:571-614` persists tombstone before local removal
- `retryDeletions` at line 621-656 processes pending deletions with partial acknowledgement handling
- Tombstones suppress returned records via `isTombstoned()` check
- Test coverage in `CloudReliabilityTests.swift:252-270`:

```swift
@Test @MainActor func cloudOfflineDeletionIsDurableBeforeLocalRemovalAndRetriesBothRecordsAfterRelaunch() async throws {
    // Verifies offline deletion intent persists and retries after relaunch
    #expect(fixture.sync.pendingDeletionCount == 1)
    #expect(snapshot.zones[CKCurrentUserDefaultName]?.deletions[member.id] == [member.id, "state-\(member.id)"])
```

Additional tests: `cloudPartialDeletionKeepsOnlyUnacknowledgedWorkAndSuppressesReturnedRecords`, `cloudDeletionIsRefusedWhenItsIntentCannotBeSaved`

**Remaining acceptance:** Real CloudKit offline deletion and eventual two-device convergence

---

### #10 — Whole-document CloudKit conflict policy loses independent profile edits

**Status:** FIX VERIFIED — awaiting Tester two-device convergence

**Evidence:**
- `ProfileState.merged(with:)` implements per-field merge with sync metadata
- `ProfileStateMergeTests.swift` covers 216 history merge orders and 120 reorder permutations
- `ProfileCloudDocument` uses bounded versioned compressed envelope (~630 KB for 15k songs)
- Test coverage in `ProfileStateMergeTests.swift:26-51`:

```swift
@Test func profileMergePreservesIndependentFieldsCollectionsAndLibraries() {
    let merged = left.merged(with: right)
    #expect(merged == right.merged(with: left)) // Commutative
    #expect(merged.settings.appearance == "Dark")  // From left
    #expect(!merged.settings.gapless)              // From right
```

Additional tests: `profileMergeDeletionSurvivesUnrelatedEditsAndStaleReplay`, `profileCloudConflictsMergeLatestLocalEditsAcrossSuccessiveRetries`

**Remaining acceptance:** Both devices on build 202609142035+, independent offline edits, convergence

---

## Issue #35 — Mac large-library navigation stalls

**Status:** UI/POLISH LANE — not Gumbo core work

This issue has labels `bug`, `priority:P1`, `area:ui-ux` and tracks Mac navigation stalls (516ms–1333ms at 5k/15k tracks). Batch 4 and batch 5 improved profile persistence responsiveness, but global UI smoothness work remains.

Per constraints, this is Polish/a11y optimization work and should not be taken in this scope.

---

## Remaining Open P1s Summary

| Issue | Title | Status | Owner |
|-------|-------|--------|-------|
| #1 | Watch downloads fail for nested NAS paths | Fixed — awaiting Tester | Gumbo |
| #3 | Downloaded cache from another NAS | Fixed — awaiting Tester | Gumbo |
| #7 | CloudKit sync not scoped to Apple Account | Fixed — awaiting Tester | Gumbo |
| #8 | Profile deletion not retried offline | Fixed — awaiting Tester | Gumbo |
| #10 | CloudKit conflict loses independent edits | Fixed — awaiting Tester | Gumbo |
| #12 | TestFlight acceptance matrix | Needs device pass | Gumbo |
| #13 | App Store packaging validation | Needs metadata/URLs | Gumbo |
| #14 | Privacy copy and artwork disclosure | Policy URL needed | Gumbo |
| #35 | Mac navigation stalls | UI/Polish lane | Polish |

**Connect-owned (not Gumbo):** #6 DSM 2FA reauthentication (partially merged, needs 2FA device testing)

---

## Security Findings Status

The release audit identified 6 security findings from Codex Security scan `f3adaf31-9aee-4070-a450-f4cb8a8ac159`. GitHub issue creation requires owner access (403 returned).

### Filing Status

| Finding | Severity | Code Fix | GitHub Issue |
|---------|----------|----------|--------------|
| HTTP credential transport | P1 | — | **Connect owns** (skip) |
| Malformed metadata termination | P1 | Merged batch 2 | Not filed (see below) |
| Failed family revocation | P1 | Merged batch 3 | Not filed (see below) |
| Owner PIN removal bypass | P1 | Merged batch 1 | Not filed (see below) |
| Cross-NAS family credential scoping | P1 | Merged batch 3 | Not filed (see below) |
| Oversized-cover allocation | P2 | Merged batch 2 | Not filed (see below) |

### Issue Bodies for Manual Filing

The exact issue bodies are provided below for Sam to file manually.

---

## Security Issue Bodies

### 1. Malformed Metadata Termination

**Title:** `[Security] Malformed metadata termination can exhaust memory or crash`

**Labels:** `security`, `priority:P1`, `release:blocker`

**Body:**

```markdown
## Security Finding — Malformed Metadata Termination

**Severity:** Medium (P1 release blocker)

**Source:** Codex Security scan `f3adaf31-9aee-4070-a450-f4cb8a8ac159` (14 September 2026)

## Description

Malformed or adversarially crafted media metadata (MP4/ID3 tags) can cause unbounded memory allocation or crash the indexer before tag parsing completes.

## Affected Components

- `Packages/SkyrCore/Sources/SkyrCore/Indexing/` — MP4/ID3 tag parsing
- Any file scanned from a user's NAS library

## Potential Impact

- Application crash during library scan
- Memory exhaustion on the device
- Denial of service through a single malformed file

## Remediation Status

Source fixes merged in batch 2: MP4/ID3 changes check spans before arithmetic, integer conversion, and slicing. They reject incomplete declared regions, validate optional frame/descriptor prefixes, and cap complete tag regions.

## Verification

- `Packages/SkyrCore/Tests/SkyrCoreTests/MediaBoundaryTests.swift`
- `Packages/SkyrCore/Tests/SkyrCoreTests/BoundedBytesTests.swift`
```

---

### 2. Failed Family Revocation

**Title:** `[Security] Failed family revocation leaves stale credentials accessible`

**Labels:** `security`, `priority:P1`, `release:blocker`

**Body:**

```markdown
## Security Finding — Failed Family Revocation

**Severity:** Medium (P1 release blocker)

**Source:** Codex Security scan `f3adaf31-9aee-4070-a450-f4cb8a8ac159` (14 September 2026)

## Description

When family sharing removal fails (CloudKit unavailable, partial acknowledgement), previously shared credentials and profile access may remain available to revoked members.

## Affected Components

- `Packages/SkyrCore/Sources/SkyrCore/State/CloudSync.swift` — sharing removal
- `Packages/SkyrCore/Sources/SkyrCore/Models/FamilyInfo.swift` — credential distribution

## Potential Impact

- Revoked family members retain NAS access
- Stale credentials accessible after intended removal
- Privacy breach if family membership ends acrimoniously

## Remediation Status

Source fixes merged in batch 3: Sharing removal requires CloudKit acknowledgement before rotating the NAS password. Failed changes preserve a saved pending state and recovery instructions. Retries cannot switch Apple Account, family, NAS or profile session.

## Verification

- `Packages/SkyrCore/Tests/SkyrCoreTests/FamilyAccessTests.swift`
- Manual family removal/rejoin journeys remain device acceptance
```

---

### 3. Owner PIN Removal Bypass

**Title:** `[Security] Owner PIN can be removed without current PIN validation`

**Labels:** `security`, `priority:P1`, `release:blocker`

**Body:**

```markdown
## Security Finding — Owner PIN Removal Bypass

**Severity:** Medium (P1 release blocker)

**Source:** Codex Security scan `f3adaf31-9aee-4070-a450-f4cb8a8ac159` (14 September 2026)

## Description

The profile PIN (used to protect owner/admin access) could be removed or bypassed without validating the current PIN, allowing unauthorized profile management.

## Affected Components

- `Packages/SkyrCore/Sources/SkyrCore/State/ProfileStore.swift` — PIN validation
- Profile management and activation flows

## Potential Impact

- Unauthorized profile access
- PIN protection bypassed
- Owner privileges obtained without authorization

## Remediation Status

Source fixes merged in batch 1: Profile activation validates the canonical PIN; management requires an authenticated eligible profile. Biometric results revalidate current state. Edits are tied to their opening session and profile revision. Remote PIN changes lock active access and revoke biometric enrollment.

## Verification

- `Packages/SkyrCore/Tests/SkyrCoreTests/ProfileAuthorizationTests.swift`
- Biometric hardware and remote profile changes remain device acceptance
```

---

### 4. Cross-NAS Family Credential Scoping

**Title:** `[Security] Family credentials not scoped to their originating NAS`

**Labels:** `security`, `priority:P1`, `release:blocker`

**Body:**

```markdown
## Security Finding — Cross-NAS Family Credential Scoping

**Severity:** Medium (P1 release blocker)

**Source:** Codex Security scan `f3adaf31-9aee-4070-a450-f4cb8a8ac159` (14 September 2026)

## Description

Family NAS credentials distributed through CloudKit may be offered for a different NAS server than the one they were verified against, potentially leaking credentials to the wrong destination.

## Affected Components

- `Packages/SkyrCore/Sources/SkyrCore/State/CloudSync.swift` — FamilyInfo distribution
- Connection and credential presentation flows

## Potential Impact

- NAS credentials sent to wrong server
- Credential leakage if family switches NAS servers
- Privacy breach through credential misdirection

## Remediation Status

Source fixes merged in batch 3: Only credentials verified for the current NAS source are offered. Catalogue, credentials, family access and download lookup distinguish the canonical scheme, hostname, effective port and account.

## Verification

- `Packages/SkyrCore/Tests/SkyrCoreTests/FamilyAccessTests.swift` — 14 family access cases
- `Packages/SkyrCore/Tests/SkyrCoreTests/ConnectionTests.swift`
```

---

### 5. Oversized Cover Allocation

**Title:** `[Security] Oversized artwork can exhaust memory during download`

**Labels:** `security`, `priority:P2`

**Body:**

```markdown
## Security Finding — Oversized Cover Allocation

**Severity:** Low (P2)

**Source:** Codex Security scan `f3adaf31-9aee-4070-a450-f4cb8a8ac159` (14 September 2026)

## Description

NAS whole-file artwork downloads did not bound the byte stream, allowing a maliciously large cover image to exhaust device memory.

## Affected Components

- Artwork download and caching flows
- Cover image fetching from NAS

## Potential Impact

- Memory exhaustion from large artwork
- Application crash during cover download

## Remediation Status

Source fixes merged in batch 2: NAS whole-file artwork downloads now consume a bounded async byte stream. Both advertised size and bytes actually received are checked. The underlying URLSession task is cancelled on exit, error, and caller cancellation.

## Verification

- `Packages/SkyrCore/Tests/SkyrCoreTests/BoundedBytesTests.swift`
- Image decoding/Foundation memory bounds remain outside source control
```

---

## Tester Notes

### Issues ready for device pass/close:

1. **#1, #3** — Download two nested-path playlists from different NAS servers, verify correct audio plays, test offline
2. **#7, #8** — Test A → sign out → B account journey; delete profile offline, verify remote convergence
3. **#10** — Make independent edits on two devices offline, reconnect, verify merge preserves both

### Still needs code/owner work:

- **#12** — Full TestFlight acceptance matrix (device testing in progress)
- **#13** — App Store metadata, privacy URLs, support contact
- **#14** — Publish privacy policy, set App Store URLs

### Not this scope:

- **#35** — Polish/UI performance (navigation stalls)
- **#6** — Connect owns DSM 2FA work
