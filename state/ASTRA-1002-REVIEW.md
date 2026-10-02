# Independent playback review — 2026-10-02

Owner: delegated playback review lane, branch astra/playback-review-1002, base 9a42922.
Scope: SpeechPlayer, ReadingSession, SynthesisQueue, NowPlaying, iOS interruption wiring, regression tests.
No main checkout edits, publishing, release, simulator, cloud spending or third-party contact.
Recovered after the host interruption; Apple build/test lane is shared exclusively by the coordinator.

## Findings addressed
- Interruption end previously started any current session when the OS suggested resume, including paused
  or replaced articles. Keep interruption intent on the interrupted session, resume once, and let explicit
  Pause revoke it. Tests cover idle/paused sessions, buffering, actual paused audio, repeated notifications,
  no-resume and replacement/closed sessions.
- Changing voices after actual playback completion reset the player and session to idle, so close could
  overwrite completion. Preserve finished state across queue replacement. Regression covers both newly
  completed playback and a previously completed article reopened from the library.
- Discarded synthesis queues accepted new work and could return cache hits or publish after cancellation.
  Make cancellation terminal; clear clips/observers, reject new requests and check every awaited boundary.
  Tests cover retained-memory eviction, no fresh synthesis, and an uncooperative late engine result.

## Independent source review
Reviewed 793e4df and 634ee19 plus their tests, tracing pending synthesis, pause/resume, seek/restart,
failed render-ahead, final sentence completion, generation rejection, timing segment retention, progress
restoration and observable media time. Existing generation guards correctly reject stale player results.
Queue observers separately reject old voice generations and closed sessions. The completion/voice-change
finding above is the remaining defect identified in those changes. No additional source change to
SpeechPlayer or NowPlaying was justified in this bounded review.

## Verification
- `git diff --check` passed after source edits.
- Historical `review-red.log` did not reach tests: copied build artifacts referenced a different module
  cache path. It is infrastructure failure evidence, not a red regression control.
- Historical `session-green.log` compiled, then crashed immediately in AVAudioPlayerNode initialization:
  `com.apple.coreaudio.avfaudio`, `required condition is false: comp != nullptr`, signal 6. It contains no
  successful Swift Testing result and must not be cited as green. The crash preceded new session logic.
- Coordinator reports baseline full suite 78/78 passed after host recovery.
- Recovered focused execution passed 20 tests in 4 suites (13.852 s, build 9.41 s), exit 0.
  Command: `swift test --package-path Packages/ReadAloudKit --scratch-path <review-DD>/PackageBuild
  --jobs 2 --no-parallel --filter 'QueueCancellationTests|InterruptionTests|SessionProgressTests|PlaybackRecoveryTests'`.
  Evidence: `recovery-focused.log` in the review DD below. This includes real macOS audio-clock
  pause/resume, failure recovery and completion followed by a voice change. The earlier audio
  initialization exception did not recur. No full-suite claim is made for these review changes.
- Historical logs and warmed build: `/Volumes/Crucial X8/DerivedData/readaloud-astra-review-1002-tests/`.
- Local commits: abe6d9d (session/interruption), a0147e5 (terminal queue cancellation). Not pushed.

## Handoff
Focused review work is finished and verified; build reservation and recovered DerivedData lease released.
Coordinator will compile the iOS notification wiring centrally. Real iOS interruption delivery is not
established by these macOS tests. Source commits above are ready for integration; no operator action needed.
