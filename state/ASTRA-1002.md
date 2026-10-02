# Astra core-experience push — 2026-10-02

## Delivery
- Integration branch: `astra/core-experience-1002`, isolated worktree `ReadAloud-astra-1002`, base `121e5c4`.
- Original run finished at 12:16 EDT. Bounded iOS follow-up verified at 12:42 EDT; evidence delivery below.
- Production code through `de3b12c`, real-model verification in `7390879`; no production changes in the follow-up.
- PR: [#1 — Make extraction, speech playback and reader follow reliable](https://github.com/legitimate-apps/ReadAnythingAloud/pull/1), open for review; not merged.
- Main checkout remains clean at `121e5c4`. No merge, release, store submission, spending or third-party messages.
- Commits use legitimate-apps and `Co-Authored-By: Codex <noreply@openai.com>`.
- Repository has no CI workflow; verification below is local. Never add a self-hosted runner to this public repo.

## Product priorities and completed work
CORPUS.md, STATE.md, README.md, project memory and the shared operating contract were read before selecting
work. Priority was the core promise: readable content, reliable speech, synchronized highlighting and controls.

### Playback and progress
- Pending synthesis honors the current Play/Pause intent; Resume during buffering is retained.
- Synthesis failures stop at unread text after queued audio finishes, without retry storms or silent skipping.
- Stop rejects late work and clears stale positions; short-sentence timing records survive until played.
- Elapsed time stays observable between words. Pause estimates are counted once, including heading pauses.
- Completion remains 100% after close/reopen and voice changes. 99% resumes the real word instead of completing.
- Repeated Play is idempotent; nonfinite rate changes are ignored; stale voice/queue observers are rejected.
- Audio interruptions resume only previously playing sessions when the OS permits; explicit Pause cancels intent.
- Discarded synthesis queues remain cancelled and reject late engine/cache results.

### Extraction and speech
- Lazy images/picture sources, ordered-list start/value/zero/reversed numbering, table captions and hidden
  nested rows/cells/list paragraphs preserve the readable article more faithfully.
- Chinese/Japanese text uses language-aware word segmentation; language codes preserve the full primary tag.
- Long unpunctuated speech units split at clauses, whitespace or grapheme boundaries without losing text.
- Both Kokoro backends recover from phoneme-limit expansion by recursively splitting and retaining original
  UTF-16 word alignment, timing offsets and audio order. Other errors and cancellation propagate.
- Extraction preserves cancellation during navigation and DOM settling. HTTP errors take precedence over
  MIME classification; unsupported streaming content is rejected once WebKit supplies response policy.
- Loader reuse resets response/readiness state; operation-bound timeout/cancellation and navigation identity
  prevent stale completion callbacks from completing the wrong load. Client-side redirects are covered.

### Reader follow and highlighting
- Back to reading returns to an unchanged paused sentence and survives an active scroll ending.
- Deferred rejoin retains forced-layout intent, including when playback advances to a distant sentence.
- Forced reveals lay out a bounded viewport beyond the target, preventing estimated height from clamping
  the sentence below playback controls. Highlights refresh after target layout on Mac and iOS.
- Added a Mac ReaderTests target compiling the production renderer, with three real AppKit viewport tests.
- Synthetic rendered screenshots: [browsing away](evidence/ASTRA-1002/browsing-away.jpg) and
  [rejoined sentence](evidence/ASTRA-1002/rejoined-sentence.jpg). The rejoined sentence highlight was inspected.

## Verification evidence
Builds and tests used leased external DerivedData; leases are now released and logs remain cached. Central directory:
`/Volumes/Crucial X8/DerivedData/readaloud-astra-1002`.

| Check | Observed result | Log/artifact |
| --- | --- | --- |
| Baseline package |54/54 passed | `baseline-tests.log` |
| Playback regressions against original | Pause ignored, final failure retried about 300 times in 8 seconds, unread text skipped | `playback-red.log` |
| Recovered integrated package |97 tests / 16 suites reported passed in 13.163s; 2 optional live-web tests skipped | `final-package-tests.log` |
| Long-text chunking/document tests |20/20 passed; exact reconstructed samples and timing offsets, Unicode, cancellation/error coverage | `voice-chunking.log` |
| Extracted-content fidelity | Original failed 6 assertions; fixed 18/18 combined tests passed | `extraction-red.log`, `extraction-green.log` |
| Multilingual extraction/segmentation | Original Chinese fixture rejected; fixed 30/30 combined tests passed | `multilingual-red.log`, `multilingual-green.log` |
| Loader HTTP/cancellation/reuse |10/10 focused; 25 broader extraction tests executed passed, 2 live skips | Extraction DD: `loader-recovery-image.log`, `extraction-recovery.log` |
| Recovered interruption/queue/progress |20 tests / 4 suites passed in 13.852s, including actual Mac audio completion and pause/resume | Review DD: `recovery-focused.log` |
| Mac reader regressions | Each added failure reproduced; final 3/3 passed in 2.229s | `reader-baseline-test.log`, `reader-live-scroll-red.log`, `reader-distant-before.log`, `reader-final-tests.log` |
| Reader target build | Passed | `reader-final-build.log` |
| Final macOS app build at `de3b12c` | Passed | `final-mac-build.log` |
| iOS Simulator app+Share extension | Passed at `de3b12c` (arm64+x86_64) | `final-ios-build.log` |

Package command: `swift test --jobs 2 --package-path Packages/ReadAloudKit --scratch-path "$DD/PackageBuild"`.
Mac reader command: `xcodebuild -project ReadAnythingAloud.xcodeproj -scheme ReaderTests
-destination 'platform=macOS,arch=arm64' -derivedDataPath "$DD" -jobs 2 build-for-testing CODE_SIGNING_ALLOWED=NO`,
then `xcrun xctest "$DD/Build/Products/Debug/ReaderTests.xctest"`.
Optional `READALOUD_READER_EVIDENCE_DIR` writes JPEGs. The Xcode test runner could not load the external-volume
bundle on this host; direct xctest successfully executes the same built bundle. This is recorded, not hidden.
App builds use scheme ReadAnythingAloud, the same DD and 2 jobs, destinations `platform=macOS,arch=arm64`
and `generic/platform=iOS Simulator`, with signing disabled. No install/archive/release is implied.

## Recovery, reviews and resource ownership
The 11:40 Terminal crash killed the original helpers. Recovery inspected actual worktrees and logs;
unverified/crashed helper logs were not counted as passes. Recovered changes were tested, reviewed and
committed before integration. All useful helper work is integrated; no helper implementation is outstanding.
- Extraction branch: `astra/extraction-reliability-1002`; details in [extraction state](ASTRA-1002-EXTRACTION.md).
- Voice branch: `astra/voice-robustness-1002`; details in [voice state](ASTRA-1002-VOICE.md).
- Review branch: `astra/playback-review-1002`; details in [review state](ASTRA-1002-REVIEW.md).
Independent review covered playback, chunking and extraction. Reader review found deferred layout intent
loss; the fix and distant-target regression are integrated. Only one build/test lane ran after recovery.
Our simulator `EB170F21-6485-4FB0-9703-11BE9C49E21F` stayed Shutdown after recovery; another project owned
a booted device, so no second simulator was started. No Android emulator was started by this run.
All owned simulator and DerivedData leases are released. The owned simulator was confirmed Shutdown and disposed.
Builds/tests are finished; no helper or emulator is running for this run.

## Limits and remaining roadmap
- The bounded follow-up verified Apple buffering Play/Pause/Resume and Back to reading on iPhone17Pro,
  iOS26.5 Simulator. Physical-device interruption delivery, iPad layout and ONNX runtime remain unverified.
- Real Mac Kokoro overflow recovery passed with cached models: raw engine rejected a 299-character numeric
  passage; the wrapper produced 1,680,000 samples at 24 kHz (70 seconds) and 60 ordered, positive word timings.
  This proves real synthesis/recovery, not a listening-quality judgment or iOS ONNX runtime behavior.
  Ordinary successful clips retain their existing model revision/cache.
- Optional live-web extraction tests, paid ElevenLabs calls and release/TestFlight checks were not run.
- Historical September 26 device/release observations in STATE.md remain historical and were not reverified.

## Exact next step
Review PR#1, then verify physical iOS interruption delivery with/without resume permission, completion
followed by voice switch/reopen, iPad layout, and a long numeric/unpunctuated passage using existing iOS
Kokoro models. Listen/check word highlights at chunk joins and monitor memory during extended playback.
The requested iPhone simulator buffering controls and Back to reading scenarios are complete; see below.
Do not merge, release or spend on cloud speech without the applicable authorization.

## Final real-model verification — 12:13 EDT
Added opt-in KokoroCoreMLIntegrationTests. Raw Kokoro must throw phonemeSequenceTooLong for 60 repetitions
of 2024; production recovery must return non-silent 24 kHz audio and all 60 monotonic word timings within
clip duration. Test passed in 16.979s with existing cached models (`real-kokoro-overflow.log`). No cloud speech
calls. Default test runs skip this model-dependent case unless READALOUD_KOKORO_COREML=1.
Latest operator timing: start nothing new after 12:15, wrap at 12:25. This run is finished, with no outstanding implementation.

## Bounded iOS follow-up — finished 12:42 EDT
Operator reopened the run for exactly two simulator checks, with commit/push/release due by12:50.
- One leased iPhone17Pro/iOS26.5; installed the final existing build, no source modifications or model downloads.
- Apple Karen selected in the UI and confirmed in persisted app preferences after stopping.
- **Passed:** Play/Pause with real uncached Apple synthesis. Recording captures the buffering spinner then
  paused Play control; two later snapshots remain at1:53. Resume advances to1:56 with Pause and highlight.
- **Passed:** Browse ahead during playback, then Back to reading. Playback advanced0:26→0:39; the button
  disappeared and the currently spoken sentence returned above the controls with its highlight.
- Screenshots, four-second video, synthetic fixture, snapshots and method are committed under
  [iOS evidence](evidence/ASTRA-1002/ios/README.md). The method records screen-level evidence and its limits.
- App stopped, recorder exited, simulator confirmed Shutdown and disposed; DerivedData lease released12:41.
- In progress: none. No helpers were started. Main checkout untouched. No merges or releases.
