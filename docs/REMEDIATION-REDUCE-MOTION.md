# Reduce Motion coverage

The remaining decorative movement in the reviewed shared screens now uses stable states or short fades when Reduce Motion is enabled. This includes the iPhone root transition, library facet and onboarding movement, album carousel changes, playlist/download grids, status badges, page indicators, indexing numbers and artist-header stretch. Both root stage and profile-lock animation modifiers are disabled together so one cannot reintroduce the other's movement. Default preference branches retain their existing motion.

## Validation

The independently reviewed 12-file patch has SHA-256 `925cff08b59f23177de357aab32b69119f6808971b489642f285d6d5555bba45`, based on main `f3170a6039d5b200421f2b3d0522565c63c28d5a`. Pure Release builds passed for iOS including Watch/widgets, macOS and tvOS. The final root-lock modifier correction also passed a fresh iOS Release compilation.

An isolated fixture used the actual changed views and existing native `DriftingLightView`, temporary storage, mock CloudKit, an ephemeral download session and no restored NAS or audio stream. On Mac, iPhone 17 Pro simulator with iOS 26.5, and Apple TV simulator with tvOS 26.5:

- Reduce Motion was true before the first visible frame, and the actual decorative layer had no drift animation.
- Changing the preference to false installed the existing animation on that same view; changing it back to true removed it.
- Page indicators, favourite badges and indexing progress remained readable after state changes. iPhone onboarding advanced with either setting.

The fixture alone sets the SDK's writable backing environment value; production views continue reading the public `accessibilityReduceMotion` environment value. A separate probe confirmed the actual public value, and layer instrumentation recorded the real animation key. No system preference was changed. Mac/iPhone fixture buttons were exercised through native UI automation. TV's simulator accessibility bridge exposes only window chrome, so fixture state commands drove that platform's preference changes and screenshots verified the result.

The [runtime evidence](evidence/reduce-motion.json) records these scoped checks. The patch received independent source review with no remaining concrete finding. Marketing version and build number are unchanged.

## Remaining acceptance

[#26](https://github.com/svoltolini/gumbo/issues/26) remains open for signed-device OS preference delivery, iPad-specific acceptance and the full animation matrix. Simultaneous stage/profile-lock changes, every collection insertion/removal, held-overscroll preference toggling and system navigation/focus animations were source-reviewed rather than recorded frame by frame. These fixture results do not establish physical remote, VoiceOver, real NAS, CloudKit or Watch acceptance.
