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
  keeping pace with real time (Core ML Kokoro crashed at the first sentence).
- iOS Share extension: Safari → Share → ReadAnythingAloud captures the rendered page (signed-in content
  included) into an App Group inbox; the app imports on activation. Verified in the simulator end to end.
- Extraction: mobile Wikipedia collapsed sections read; " - Site" title suffixes dropped.
- Tests: 44 package tests (+4 Kokoro ONNX model tests gated on READALOUD_KOKORO_ONNX_MODEL).
- Release artifacts: App Store profiles created by API (iOS app, Share ext, Mac app; dist cert XUSS4B2RSZ,
  installer S596ZPQ96Y); archives + signed exports at /Volumes/Crucial X8/DerivedData/readaloud-release
  (ReadAnythingAloud.ipa 23 MB, ReadAnythingAloud.pkg 46 MB).

## Pending on operator
- The vault broker (secretbrokerd) is wedged machine-wide (fd leak; another project's watchdog paged
  the operator with the kickstart fix). Creating the App Store Connect app record needs the LLC Apple ID
  password through the broker (the ASC API cannot create app records). Sign-in is queued; once the
  record exists, upload + TestFlight group are API-only.

## Next action
1. Create the ASC app record (iOS + macOS, bundle com.legitimateapps.ReadAnythingAloud, SKU
   readanythingaloud) → altool upload both packages → internal TestFlight group with all builds.
2. Longer iPad soak (1 h+) and memory check with the Core ML frontend chain loaded CPU-only.
3. ElevenLabs tiny test with the vault key (broker permitting).
4. Mac: consider limiting onnxruntime to iOS to trim the Mac bundle.
