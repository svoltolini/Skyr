# Gumbo issue log

Crashes, hangs and data problems seen on real devices, with their cause and fix. Newest first.
Build numbers are `CURRENT_PROJECT_VERSION` stamps (date and time of the build).

## 2026-09-14

### Settings › Family kept showing "Error saving record … state-… Atomic failure" (build 202609131835)
- **Seen:** on the phone, twice, each time right after launch had pulled two changed records from
  iCloud (the Mac app writes the same profile, state and family records). The message named the
  ProfileState record and the reason "Atomic failure".
- **Cause:** when one record in a CloudKit batch fails, every other record in it comes back as
  `batchRequestFailed` ("Atomic failure"), even with `atomically: false`. The sync threw the
  first failure it met, so what was shown was the side effect, and the record that actually
  failed (most likely a plain version conflict on a record the Mac had just changed) was never
  logged or resolved.
- **Fix:** `CloudSync.save` resolves version conflicts per record, retries the batch casualties
  one at a time so the real failure surfaces, logs each failure with its CloudKit code and server
  message, and shows "Couldn't save the profile / favourites / family's server details to
  iCloud: …" instead of a record identifier. A build pointed at the production environment
  synced cleanly on the phone afterwards (12:23 UTC).

### Family invitation link "is not valid" for the invited person (build 202609131835)
- **Seen:** the owner sent the family link to a relative in another country; opening it showed
  "the iCloud link is not valid". The owner wondered whether iCloud Family Sharing was required.
- **Cause:** the link is a CloudKit share (`icloud.com/share/…`), which any Apple Account can
  accept, in any country, with no Family Sharing involved. But the app never declared
  `CKSharingSupported` in its Info.plist, so iOS and macOS had no app to hand the link to and
  opened it in the browser, where a share for a third-party app has no page. The link also only
  works once Gumbo is installed, and only in the same CloudKit environment as the build that made
  it (TestFlight and App Store builds use Production; Xcode builds use Development).
- **Fix:** `CKSharingSupported: true` on the iOS and Mac targets; a "Have an invitation link?"
  entry on the Welcome screen, in the Mac setup assistant and in Settings › Family that accepts a
  pasted link (`CloudSync.accept(url:)`); invitation copy that says to install Gumbo first and that
  Family Sharing plays no part. The invited person needs a build with this fix installed before
  opening the link.

## 2026-09-13

### Mac app "crashes" after a scan (build 202609131657, macOS)
- **Seen:** the Mac app stopped responding right after "Reading tags for 116 songs". macOS recorded
  a CPU-resource diagnostic: 86% of a core for 105 s on the main thread inside SwiftUI lazy-stack
  layout. The process was still alive; it was a hang, not a crash.
- **Cause:** the Library screen's body reads the scan subtitle, and the indexer bumped its
  progress counters for every song and every cover. Each bump re-evaluated the whole Library
  screen, with every shelf and card, hundreds of times in a row.
- **Fix:** the indexer publishes progress at most twice a second, and the subtitle is read in a
  view modifier with its own observation scope, so the shelves no longer re-render for it.

### iPhone/iPad build running on the Mac crashed at launch (build 202609131608)
- **Seen:** TestFlight offered the iOS build on the Mac as an iPad app; it asserted inside a
  sheet's environment two seconds after launch, sharing the native Mac app's data container.
- **Fix:** the iOS build no longer offers itself on Macs (`SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD`
  off, build 202609131728); the native Mac app is uploaded to TestFlight instead.

### Library emptied after installing a release build (build 202609131608)
- **Seen:** every scan reported "0 folders listed, 0 files seen" and the catalogue was replaced by
  an empty one. Debug builds never showed it.
- **Cause:** with this toolchain, results returned from worker tasks as tuples carrying a `Result`
  with an error payload come back corrupted in release builds; the task-group version returned
  nothing at all.
- **Fix:** `parallelResults` (plain awaited tasks) and struct payloads everywhere; a scan that lists
  no folders now keeps the existing library instead of replacing it. Regression test in
  `Packages/SkyrCore/Tests/SkyrCoreTests/ScanTests.swift`, run with `swift test -c release`.

### iCloud "Cannot create new type … in production schema"
- **Seen:** every TestFlight build failed to sync the family and profile records.
- **Cause:** release builds use CloudKit's production environment; the schema existed only in
  development.
- **Fix:** deployed Development → Production in the CloudKit Console. Any new record type or
  field must be deployed the same way before the next upload.

### Watch app crashed when the phone answered a sync (simulator)
- **Cause:** WatchConnectivity reply/error closures written inside a main-actor class are inferred
  main-actor and abort when called on the connectivity queue.
- **Fix:** `@Sendable` closures that hop to the main actor; same treatment for `URLSession`
  task queries and KVO observers.

## 2026-09-12

### iPhone crashed in the background (build 202609121249)
- **Cause:** the background-scan task handler registered with `BGTaskScheduler` was inferred
  main-actor and called on the scheduler's queue.
- **Fix:** `@Sendable` handler and expiration closure hopping to the main actor (build
  202609121715).

### iPhone and Mac builds deadlocked at launch after the television work
- **Cause:** `AppDirectories.support` returned itself on every platform except tvOS.
- **Fix:** returns the Application Support directory.
