# STATE — ReadAnythingAloud

Updated: 2026-09-25

## Decisions (operator, 2026-09-25)
- Build our own (no forkable 90% OSS exists — research/oss-landscape.md).
- Platforms: macOS + iPhone + iPad. Team: Legitimate LLC 3LTL47SJ8C. Public, MIT. Name: ReadAnythingAloud.

## Done
- Research: research/oss-landscape.md, research/tts-timing.md.

## Pending on operator
- (none)

## Known risks
- FluidAudio Kokoro Core ML crashes on iOS 26.4+/27 during long sessions (Apple BNNS/MPSGraph bug,
  FluidAudio #844/#889). Mac 26.6+ fine. Need an iOS executor strategy + device soak (test iPad Air 4,
  iPadOS 26.6.1 — standing-authorized for test installs when plugged in).

## Next action
- Scaffold XcodeGen project + ReadAloudKit package; extraction → segmentation → Apple voice → playback →
  highlight vertical slice on Mac.
