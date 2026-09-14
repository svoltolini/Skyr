# Source-only album artwork — issue 34

The release no longer looks up covers through Apple's Search service. The request implementation and earlier opt-in consumer are removed, including automatic scan and manual-refresh fallbacks. NAS-folder covers and embedded pictures remain supported. Matching pictures on multiple albums are kept as source artwork.

## Existing installations

Older album image and palette caches did not record whether the bytes came from the NAS or Apple. This change leaves that directory untouched and unused, and uses a new source-only cache directory. A normal connected scan rebuilds available covers even when every song's tags are already current. Already rebuilt source covers continue to work offline. Some older covers may temporarily show generated placeholders while offline; the app cannot safely identify legitimate source copies in the mixed old cache. Music files, downloads, playlists, favourites and credentials are not removed.

Catalogue decoding replaces only unknown-policy saved colours with generated colours and preserves the indexed music fields. Current source-cache palettes are reapplied by the library. Watch receives playlist metadata and colour pairs, not cover image files; old or unknown-policy Watch colours are normalized on every decode, including queued messages from an older phone, without changing download ownership or playlist/track identities.

Widget snapshot envelopes carry an artwork-policy version. Their reader refuses older envelopes and copied images even if the extension starts before the upgraded app. The next current app publication supplies fresh source artwork. The existing session and publication-revision checks remain.

## Verification

- Focused optimized Release suite: 27 tests passed, including both NAS-folder and embedded FLAC regeneration for fully enriched catalogues, reuse on later scans, repeated source images, manual refresh, legacy cache/music preservation, catalogue and Watch colour migration, widget policy gating and metadata regressions.
- Complete optimized Release package suite: 216 tests passed. The retired online lookup tests were replaced by source-artwork and migration checks.
- Unsigned optimized Release target builds passed for Mac, Apple TV and iOS simulator, including Watch and widgets. No source compiler warnings; TV emitted only the routine skipped AppIntents metadata-extraction notice.
- After integration, the package and shipping source matched the tested snapshot except for the native batch's already verified Mac queue-menu guard and genre-help text row. The complete integrated Mac Release build also passed without compiler warnings.
- Independent read-only review found no material issue in request removal, cache separation, colour normalization, widget policy gating, or metadata/download preservation.
- Source audit finds no remaining lookup/consent consumer, iTunes Search endpoint or Apple artwork-host request path in the application/package sources.
- No build/version bump, signing change, upload or public privacy publication is part of this patch.

Local compilation and fixtures do not establish signed-device NAS, Watch delivery, or widget timeline acceptance. Verify those on the final consolidated TestFlight build. The app can reject old cache data when it reads it; it cannot synchronously recall an already rendered operating-system snapshot. This change omits the external artwork feature and makes no claim of legal approval for its previous use.
