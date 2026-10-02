# STATE — ReadAnythingAloud

Updated: 2026-10-02

## Development update — 2026-10-02
Core-experience reliability work is complete on `astra/core-experience-1002`, in [PR #1](https://github.com/legitimate-apps/ReadAnythingAloud/pull/1). This is
not a release. Playback intent, failure recovery, completion/resume, interruptions, cancelled queues,
extraction fidelity/cancellation, multilingual segmentation, long-text Kokoro recovery and reader rejoin
are covered by regressions. Both app platforms build; Mac reader viewport tests and real cached Kokoro
overflow synthesis pass. See [the run state](state/ASTRA-1002.md) for evidence, limits and the exact next step.
The September device and release observations below remain historical.

## Decisions (operator, 2026-09-25)
- Build our own (no forkable 90% OSS exists — research/oss-landscape.md).
- Platforms: macOS + iPhone + iPad. Team: Legitimate LLC 3LTL47SJ8C. Public, MIT. Name: ReadAnythingAloud.
- Signature color: desaturated, slightly dark salmon.

## Done (observed)
- Mac: Kokoro playback with sentence + word highlight in sync, follow scrolling, 2× speed, tap-to-jump,
  resume on launch. Real articles: Wikipedia (images, lists), Paul Graham "How to Do Great Work" (long),
  The Economist (403 → graceful sheet with Open page / Paste text; teaser flagged as preview).
- iPad Air 4 (iPadOS 26.6.1): Apple-voice playback fixed (one long-lived AVSpeechSynthesizer); Kokoro on
  ONNX Runtime downloads (88 MB, hash-checked) and plays with engine word timings; soak 23+ min crash-free,
  keeping pace with real time (Core ML Kokoro crashed at the first sentence). 1 h soak (1:02:05 of
  audio in 60 min) crash-free; footprint 556 MB after releasing FluidAudio's Core ML chain (was 882–962 MB).
- iOS Share extension: Safari → Share → ReadAnythingAloud captures the rendered page (signed-in content
  included) into an App Group inbox; the app imports on activation. Verified in the simulator end to end.
- Extraction: mobile Wikipedia collapsed sections read; " - Site" title suffixes dropped.
- Word tap moves the playhead without changing play/pause (operator report 2026-09-26).
- Tests: 50 package tests (+4 Kokoro ONNX model tests gated on READALOUD_KOKORO_ONNX_MODEL).
- Release artifacts: App Store profiles created by API (iOS app, Share ext, Mac app; dist cert XUSS4B2RSZ,
  installer S596ZPQ96Y); archives + signed exports at /Volumes/Crucial X8/DerivedData/readaloud-release
  (ReadAnythingAloud.ipa 23 MB, ReadAnythingAloud.pkg 46 MB).

## Release (App Store Connect)
- App record created 2026-09-26 in the ASC web UI (API can't): Apple id 6816335563, iOS + macOS,
  SKU readanythingaloud. Internal TestFlight group "Internal" (fb3acfa1-…), all builds, 2 testers.
- Builds 1 and 2 were rejected in processing: ITMS-90208, Xcode embedded an empty stub
  onnxruntime.framework (ORT is a static xcframework already linked into the binary). A post-build phase
  now deletes the stub. **On TestFlight (Internal group), 2026-09-26: iOS build 3 VALID / IN_BETA_TESTING,
  macOS build 4 VALID.** (Mac needed LSSupportsOpeningDocumentsInPlace = YES; NO fails the build.)
- Upload: `Scripts/release.sh` — archive (Release, generic platform) → export with
  Scripts/export-*.plist (manual signing) → `xcrun altool --upload-app` with the
  Legitimate ASC key (`~/.appstoreconnect/config-legitimate.sh`). Failed processing shows only in the
  ASC web UI (TestFlight → Build Uploads), not in /v1/builds.

## Notes
- ONNX Runtime is linked on iOS only (Mac app 73 → 42 MB). The ORT engine and its tests compile only for iOS;
  run them with `xcodebuild test -scheme ReadAloudKit-Package -destination 'platform=iOS Simulator,id=…'`.
- On the iOS Simulator, the package's `file://` fixture extractions (`extract(url:)` on bundled HTML) can hit
  the 30 s timeout depending on test order, while `extract(html:)` tests pass. Production iOS never loads
  file URLs (files are read and passed as HTML); real web pages extract in ~1 s on the iPad.

## Next action
1. Review the core-experience PR and verify the final branch on one leased iPhone/iPad device or simulator;
   use the exact controls, interruption and reader scenarios in [the run state](state/ASTRA-1002.md).
2. Check long numeric/unpunctuated passages on iOS Kokoro and memory growth during extended playback.
3. Revisit release/TestFlight validation and optional ElevenLabs testing in a separately authorized run.
