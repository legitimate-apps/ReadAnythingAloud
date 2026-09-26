# STATE — ReadAnythingAloud

Updated: 2026-09-26

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
  now deletes the stub. Build 3 carries the fix; upload status is below in the log.
- Upload: `scripts/release.sh` — archive (Release, generic platform) → export with
  scripts/export-*.plist (manual signing) → `xcrun altool --upload-app` with the
  Legitimate ASC key (`~/.appstoreconnect/config-legitimate.sh`). Failed processing shows only in the
  ASC web UI (TestFlight → Build Uploads), not in /v1/builds.

## Next action
1. Confirm build 3 processes (iOS + macOS), install from TestFlight on the iPad, re-check Kokoro.
2. iPad memory: footprint growth over a long session with the current build.
3. ElevenLabs tiny test with the vault key.
4. Mac: consider limiting onnxruntime to iOS to trim the Mac bundle.
