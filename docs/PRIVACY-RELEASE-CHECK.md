# Privacy release evidence

Checked 14 September 2026 for batch 4. This is an engineering inventory and publication checklist, not a claim that App Store privacy answers have been published.

## Verified store state

App Store Connect API: app `6811461121`, app info `67902bd2-bf96-476e-b090-3b91431c1962`, en-GB localization `4f44c0ad-b6c9-47e9-85cb-cae23e2c7bb2`. `privacyPolicyUrl`, `privacyChoicesUrl` and `privacyPolicyText` were all null. The owner confirmed there is no public website or support contact yet. The API record is a preparation-for-submission record; this batch does not submit a public release.

## Data flow inventory

| Feature | Data and destination | Source evidence |
| --- | --- | --- |
| NAS sign-in and playback | Credentials, folder/media requests to the configured NAS; catalogue/downloads stored on device | `Networking/SynologyClient.swift`, `State/AppModel.swift`, `State/LibraryStore.swift`, `State/DownloadManager.swift` |
| Apple artwork | After local opt-in: artist and album search terms to iTunes Search; image request to Apple artwork host; ordinary IP/request information visible to Apple | `Indexing/ArtworkLookup.swift`, scan fallback in `LibraryIndexer.swift`, manual refresh in `LibraryStore.swift` |
| Profile sync | Name, chosen photo, role, dates, Apple user-record association, PIN verification values; favourites, playlists, searches, recent plays and settings in private/family-shared CloudKit zone | `CloudSync.record(for:)`, `Models/Profile.swift`, `ProfileStateMerge.swift` |
| Family connection | NAS address, names, account and music folder in family CloudKit record; selected Family Access password in `record.encryptedValues`; anyone with the share link can join | `CloudSync.record(for: FamilyInfo)` |
| Watch and widgets | Playlist/cover/playback metadata and the connection information needed for Watch NAS downloads; app-group widget snapshot | `SkyrWatch/WatchStore.swift`, `WatchDownloadManager.swift`, `WidgetFeed.swift` |
| Diagnostics | Local diagnostic file, potentially included in device backups, copied on user action; Apple separately provides TestFlight feedback/crash reports according to Apple settings | `DiagnosticsLog.swift`, `DiagnosticsView.swift` |
| Biometrics | Operating-system authentication result; no biometric template exposed to Skyr | `ProfileStore.swift` |

The package manifests include SkyrCore and SkyrShared, with no third-party SDK dependency. The project targets include privacy manifests declaring required UserDefaults/file-timestamp reasons, no tracking, and no developer-collected data types. These manifests are not substitutes for the app-level App Store answers.

## Proposed App Store answer rationale to confirm before publication

Apple distinguishes data transmitted for real-time processing from data retained for later access. Its guidance also distinguishes information the developer receives from Apple services from information collected by Apple itself. Optional behavior does not automatically qualify for optional disclosure. See [Apple's data collection and Apple-service guidance](https://developer.apple.com/app-store/app-privacy-details/).

For the app code reviewed here, no developer-operated backend receives user library data, no analytics SDK is present, and no cross-app advertising tracking is implemented. CloudKit data lives in the user's private/family-shared zone. The external artwork service is operated by Apple; do not equate its requests with "nothing leaves your network" or claim Apple discards them immediately. The Search API documentation does not establish retention guarantees.

The owner must confirm any developer access/use outside this code, particularly App Store analytics, TestFlight reports and voluntarily submitted support information, before publishing an app-level "Data Not Collected" answer. If retained developer-accessible data is used, classify its actual type, purpose and linkage under Apple's definitions instead. Do not invent a location or tracking use solely because a server sees an IP address.

The no-tracking manifest declaration is consistent with the reviewed source. The collected-data declaration needs to be reconciled with the final owner-confirmed practices and public artwork decision, rather than being changed speculatively to a fabricated collection category.

## Remaining publication work

1. Resolve the online artwork usage decision in [#34](https://github.com/svoltolini/Skyr/issues/34).
2. Complete and host `PRIVACY-POLICY.md` with a real support contact and support-retention practice.
3. Set the public URL and Apple TV policy text, then verify read-back through App Store Connect.
4. Review, save and publish the app-level privacy answers for the final release. This has not been performed in batch 4.
5. Confirm onboarding and Settings behavior on the signed TestFlight builds across platforms.

Apple requires a public privacy-policy URL and tvOS policy text before public release: [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).
