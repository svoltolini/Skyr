# Catalogue cache ordering — issue 21

Changing the selected folder or NAS invalidates unfinished cache saves. A new cache is prepared away from the main actor and published only if it is still the latest requested save. The final generation check and atomic replacement use the same short lock as source changes and sign-out. An older scan cannot overwrite a newer completed catalogue or recreate a cache after removal.

The previous committed cache stays intact if encoding, staging, or publication fails, or if a folder change is interrupted. Its existing canonical source and exact-root checks prevent it from being restored under the new selection; it remains recoverable when the user explicitly reconnects to the original source and folder. The JSON format is unchanged.

An interrupted process can leave a staging file. A background cleanup recognizes only this cache's staging filenames, validates the writer PID and UUID, and requires a regular file that is not a symlink. It removes a file only when a process-existence check confirms that the writer has exited. Live, unknown, inaccessible or reused PIDs are retained conservatively. Committed catalogues, unrelated files and music are not cleanup targets.

## Verification

- Reproduced the original race with an older `/old` save held after staging: a newer `/new` save completed, then the old save overwrote it. The visible catalogue remained `/new` while the saved cache became `/old`.
- The fixed version discards the older staged save. Both the active process and a fresh reader retain `/new`.
- Eight isolated writer-to-fresh-reader scenarios passed all 16 phases: immediate quit, scan cancellation, scan failure, completed replacement, changed port, changed account, reverse completion, and process exit after staging. The last case preserves the prior committed cache and cleans the abandoned staging file after restart.
- Nine new normal package test methods cover ordering, source/folder invalidation, cancellation, sign-out removal, encoding/staging/publication failures, preservation of newer data, and conservative staging cleanup. The exact normal Release suite passed 225 tests in 12 suites. The separate process fixture entry point is not included in that count or the production patch.
- Integrated unsigned Release builds passed for Mac, Apple TV, and iOS including Watch and widgets. The three changed source/test files match the independently reviewed candidate hashes in the evidence JSON.
- Independent review checked publication ordering, failure preservation, source/root restoration, cancellation, removal, and cleanup ownership. No outstanding material finding remained.

The process tests use actual persisted files and fresh processes with a synthetic NAS and temporary support/defaults storage. They do not contact a NAS or CloudKit, and they do not establish signed-device provider acceptance. This is process-termination recovery, not a power-loss or fsync durability claim. The final device/provider matrix remains in issue 12. No version/build bump or upload is part of this patch.
