# Search and open-detail refresh — issue 25

Search already recomputes from coalesced library revisions. Runtime checks now confirm that added, removed and retagged matches update in the actual Mac and iPhone search views while the query remains active. A synthetic incoming catalogue changes the library without editing search text, focus or navigation.

Those checks exposed a remaining detail problem: removing a pushed album left its old header and controls visible. Mac showed indefinite Loading Songs. On iPhone, the stale song button could still choose the removed song in PlayerModel. The fixture supplies no media URL, so this did not request NAS audio.

Album and artist pages now resolve current library content and show an unavailable state when it disappears. Back preserves the search query and current results. Mac album collections filter their original album IDs through the current catalogue. Album row playback and artist song actions resolve a stable song ID to its current array position, so a reordered album still plays the chosen song. Album Play, Shuffle and download actions check the captured source/profile/session. A download-removal confirmation also retains its original album and owner, so an intervening refresh cannot retarget it.

## Verification

- Mac and iPhone: additions, retags and removals update results under the unchanged query `Signal`, eventually reaching No Results. Mac accessibility reports the same focused field. iPhone focus was checked visually because the simulator bridge does not consistently report the field itself as focused.
- Both platforms: an open album or artist receives changed metadata in place. Removal shows Album Unavailable or Artist Unavailable without stale playback/download controls; Back returns to the unchanged query and current results.
- Reordered search-result activation selects the intended `demo_0_0` on both platforms. The final iPhone album-row repeat selects that same song at its new array index 1, then removes the page's controls when the album disappears.
- Five continuous fixture runs preserve source/profile/session identity. Before/fixed runs are separate because restarting the application creates a fresh session. Compact stage records and exact source hashes are in the evidence JSON.
- Final integrated unsigned Release builds passed for Mac, TV and iOS including Watch/widgets. No source compiler warning was reported; TV emitted its usual skipped AppIntents extraction notice.
- Independent source review approved the final three-file patch and its captured action guards. The integrated files match the final fixture byte for byte.

The download-removal confirmation across a profile/session change was source-reviewed, not replayed. Mac collection filtering was reviewed and compiled, not separately navigated in this search pass. The checks use isolated storage, mock CloudKit and synthetic catalogue changes, with no NAS, real audio, public account or personal library operations. Signed-device/provider acceptance remains in issue 12. No version/build bump or upload is included.
