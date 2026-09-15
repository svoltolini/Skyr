# Album navigation and cancellation

An album request on iPhone and Apple TV waits briefly for the player sheet to dismiss. That pending push now belongs to the current navigation command, connection, NAS source and authenticated profile session. A newer request, leaving Library, signing out, changing source or locking/reopening the profile prevents the old request from opening a page. The final push resolves the current album by ID, so removed albums are rejected and refreshed titles are used. Mac keeps its immediate navigation behavior.

Apple TV's independent tab owner cancels the same pending request when the listener selects another tab. The existing platform owners still switch to Library/Albums and use their own navigation stacks; no second Back mechanism was introduced.

## Verification

Five new shared tests exercise out-of-order completions, leave-and-return cancellation, explicit TV cancellation, lock/reopen, source replacement with matching album IDs, metadata refresh and removal. The complete Release package suite passed **230 tests in 13 suites** with ordinary parallelism. Release iOS including Watch/widgets, Mac and TV builds passed. An independent source review found no concrete regression.

Actual simulator remote input in the final guarded TV fixture opened **Nocturne Drift / Halden Vey** from **Slow Pulse Meridian** in Now Playing. The correct song was marked playing. Moving focus into album content and pressing Back returned to Library. The TV simulator exposes only window chrome through accessibility; the destination and Back result were verified visually. Back from the top tab bar follows tvOS behavior and exits to Home.

The parallel native Mac table fixture tested Go to Album from Songs, a playlist containing duplicate songs, Search and Downloads via the Now Playing inspector. Each reached its exact album; Back returned to the Albums grid selected by the navigation owner. These Mac checks used the parallel table candidate, whose exact binary/source hashes are recorded in [Mac evidence](evidence/album-navigation-mac.json). Its table-specific changes remain separately tracked in #35; the shared navigation guard received the independent tests and builds above.

All fixtures use synthetic/sample metadata, dedicated temporary storage, mock CloudKit and simulated playback or a local silent file. No real NAS account or user music was used. [TV source and runtime evidence](evidence/album-navigation-tv.json) records the guarded fixture. Signed device/provider acceptance and spoken VoiceOver remain in #12 and #27. Version 1.0 and the build number are unchanged.
