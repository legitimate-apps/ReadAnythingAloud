# Astra core-experience push — 2026-10-02

## Mission and boundaries
Advance CORPUS.md, core experience first, continuously through the available morning window.
Own worktree `ReadAloud-astra-1002`, branch `astra/core-experience-1002`, based on `121e5c4`.
Main checkout is untouched. No spending, third-party messages, merging, publishing, or releases.
Repository has no CLAUDE.md/AGENTS.md, PR template, or CI workflow. Follow corpus identity and local verification.
Commits use legitimate-apps with a Codex coauthor trailer. Push a review branch/PR when verified.

## Hydrated
CORPUS.md, STATE.md, README.md, project memory (decisions and release/device reference), shared operating
contract, run-to-done and simulator lifecycle skills. Current release state is historical, not reverified.

## Selected work and why
1. Playback intent and failure recovery: pending synthesis can override Pause; final synthesis failure can
   leave the player active forever. Fix core control reliability with discriminating delayed/failing engines.
2. Synchronization and progress: audit seeks, voice switches, completion, timing estimates and observation.
3. Extraction fidelity: typed lists, hidden content, lazy images, readable-page errors and cancellation.
4. Voice and reader polish selected from findings, with Mac/iOS builds and visual checks for UI changes.

## Evidence / resources
- Initial main status clean; baseline `121e5c4`.
- DerivedData lease: `/Volumes/Crucial X8/DerivedData/readaloud-astra-1002`.
- Simulator preflight returned device types successfully.
- Build/test output belongs in leased external storage, not the repository.

## Done
- Hydration and isolated worktree.
- Playback recovery: pending synthesis honors Pause and Resume; failed sentences pause at the unread text
  after queued audio finishes; retry remains possible without automatic request storms. Stop discards stale
  positions/results, engine-start failure stays paused, and short-sentence timing records survive until played.
- Evidence: baseline 54/54 tests. New control against original code failed pause, final failure (300 retries
  in 8 s), and first-failure retention. Fixed playback suites passed 12/12, then expanded recovery suite
  passed 6/6 including stop-during-synthesis and real audio-clock coverage of all 12 short sentences.
  Logs: `baseline-tests.log`, `playback-red.log`, `playback-green.log`, `playback-recovery.log` in leased DD.

- Session progress: completion remains 100% after close/reopen, 99% stays resumable, repeated Play does not
  restart audio, elapsed time is observable between words, invalid rates are ignored. Duration estimation
  counts pauses once and includes heading pauses. Voice changes/close reject stale queue observers.
- Evidence: four new session tests failed against the prior implementation (12 assertions); fixed combined
  playback/session suites passed 18/18 and expanded session suite passed 5/5 (Observation included).
  `session-red.log`, `session-green.log`, `session-observation.log`. Initial macOS app build succeeded.
- Owned iPhone 17 Pro simulator: `EB170F21-6485-4FB0-9703-11BE9C49E21F` (iOS 26.5).

## Next
Extract fidelity regressions for lazy images, list numbering/hidden content, and table cells. Build iOS
and inspect real controls with the simulator pilot skills; add further synchronization/voice checks.
