# Privacy release evidence

This is an engineering inventory and publication checklist, not a claim that App Store privacy answers have been published.

## Previously verified store state (batch 4)

App Store Connect API: app `6811461121`, app info `67902bd2-bf96-476e-b090-3b91431c1962`, en-GB localization `4f44c0ad-b6c9-47e9-85cb-cae23e2c7bb2`. `privacyPolicyUrl`, `privacyChoicesUrl` and `privacyPolicyText` were all null. The owner confirmed there is no public website or support contact yet. The API record is a preparation-for-submission record; this batch does not submit a public release.

## Data flow inventory

| Feature | Data and destination | Source evidence |
| --- | --- | --- |
| NAS sign-in and playback | Credentials, folder/media requests to the configured NAS; catalogue/downloads stored on device | `Networking/SynologyClient.swift`, `State/AppModel.swift`, `State/LibraryStore.swift`, `State/DownloadManager.swift` |
| Album artwork | NAS-folder images and embedded music pictures only; no external artwork search or image requests | `Indexing/CoverStore.swift`, source reads in `LibraryIndexer.swift` and `LibraryStore.swift`, `SkyrShared/ArtworkPolicy.swift` |
| Profile sync | Name, chosen photo, role, dates, Apple user-record association, PIN verification values; favourites, playlists, searches, recent plays and settings in private/family-shared CloudKit zone | `CloudSync.record(for:)`, `Models/Profile.swift`, `ProfileStateMerge.swift` |
| Family connection | NAS address, names, account and music folder in family CloudKit record; selected Family Access password in `record.encryptedValues`; anyone with the share link can join | `CloudSync.record(for: FamilyInfo)` |
| Watch and widgets | Watch playlist metadata, mosaic colour pairs, and the connection information needed for NAS downloads; no transferred cover image files. Widgets receive cover copies and metadata in an app-group snapshot. | `SkyrWatch/WatchStore.swift`, `WatchDownloads.swift`, `Models/WatchCatalogue.swift`, `WidgetFeed.swift`, `SkyrShared/WidgetSnapshot.swift` |
| Diagnostics | Local diagnostic file, potentially included in device backups, copied on user action; Apple separately provides TestFlight feedback/crash reports according to Apple settings | `DiagnosticsLog.swift`, `DiagnosticsView.swift` |
| Biometrics | Operating-system authentication result; no biometric template exposed to Skyr | `ProfileStore.swift` |

The package manifests include SkyrCore and SkyrShared, with no third-party SDK dependency. The project targets include privacy manifests declaring required UserDefaults/file-timestamp reasons, no tracking, and no developer-collected data types. These manifests are not substitutes for the app-level App Store answers.

## Proposed App Store answer rationale to confirm before publication

Apple distinguishes data transmitted for real-time processing from data retained for later access. Its guidance also distinguishes information the developer receives from Apple services from information collected by Apple itself. Optional behavior does not automatically qualify for optional disclosure. See [Apple's data collection and Apple-service guidance](https://developer.apple.com/app-store/app-privacy-details/).

For the app code reviewed here, no developer-operated backend receives user library data, no analytics SDK is present, and no cross-app advertising tracking is implemented. CloudKit data lives in the user's private/family-shared zone. NAS and iCloud requests still occur for their respective features; do not describe the app as sending nothing outside the local network.

The owner must confirm any developer access/use outside this code, particularly App Store analytics, TestFlight reports and voluntarily submitted support information, before publishing an app-level "Data Not Collected" answer. If retained developer-accessible data is used, classify its actual type, purpose and linkage under Apple's definitions instead. Do not invent a location or tracking use solely because a server sees an IP address.

The no-tracking manifest declaration is consistent with the reviewed source. The collected-data declaration needs to be reconciled with the final owner-confirmed practices, rather than being changed speculatively to a fabricated collection category.

## Remaining publication work

1. Complete and host `PRIVACY-POLICY.md` with a real support contact and support-retention practice.
2. Set the public URL and Apple TV policy text, then verify read-back through App Store Connect.
3. Review, save and publish the app-level privacy answers for the final release. This has not been performed by these source changes.
4. Confirm onboarding and Settings behavior on the signed TestFlight builds across platforms.

Apple requires a public privacy-policy URL and tvOS policy text before public release: [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy).
