# Extraction reliability — Astra 2026-10-02

Branch: `astra/extraction-reliability-1002`; isolated worktree; baseline `9a42922`.

## Outcome

Completed and verified on macOS. Production changes are limited to `ArticleExtractor.swift`:

- HTTP failures take precedence over MIME classification, including binary/media error bodies.
- Unsupported response types finish with their typed error when WebKit delivers response policy,
  without waiting for the rest of a streaming response or an optional cancellation callback.
- Cancellation is checked before extraction, after JavaScript evaluation, and during DOM settling.
  A cancellation racing a navigation failure preserves cancellation semantics. Temporary loads stop
  when extraction leaves its off-screen view.
- Each loader operation owns its timeout and cancellation callbacks. Reuse clears response metadata,
  readiness polling, and readiness mode. Navigation identity filters old completion/failure callbacks;
  client-side redirects adopt their new navigation.
- Added real WebKit tests served from an in-process loopback HTTP server. No internet dependency.

## Verification

Scratch path: `/Volumes/Crucial X8/DerivedData/readaloud-astra-extraction-1002/spm`.
Logs are beside that directory. The extraction DerivedData lease and exclusive Apple build slot
were released after verification.

Commands, from the extraction worktree:

```sh
swift test --package-path Packages/ReadAloudKit --scratch-path '/Volumes/Crucial X8/DerivedData/readaloud-astra-extraction-1002/spm' --jobs 2 --filter PageLoaderTests
swift test --package-path Packages/ReadAloudKit --scratch-path '/Volumes/Crucial X8/DerivedData/readaloud-astra-extraction-1002/spm' --jobs 2 --filter 'PageLoaderTests|ExtractionTests|ExtractionFidelityTests'
```

- `loader-recovery-image.log`: build 4.30 seconds; all 10 loader tests passed in 9.814 seconds,
  including four HTTP/MIME combinations and five unsupported streaming MIME types.
- `extraction-recovery.log`: exit 0; reported 27 tests across four suites in 12.223 seconds.
  25 tests executed successfully; the optional live-web suite's two tests were explicitly skipped.
  Existing local extraction and fidelity tests passed alongside the new loader suite.
- `git diff --check` passed.

The interrupted lane's `loader-before.log` completed its build but reported WebKit process crashes,
including the positive HTML control. It was not a verified baseline. After host recovery,
`loader-recovery.log` passed all cases except the image fixture that supplied headers and no body.
WebKit can sniff image bytes before delivering response policy. The final fixture sends a valid PNG
prefix padded beyond the sniffing buffer, leaves the remaining HTTP body unsent, and proves rejection
without response completion. Production code needed no special image workaround.

## Limits

No simulator or device validation was performed. The older STATE note about order-sensitive iOS
local-file fixture timeouts remains unverified; no speculative file-loading change was made.
No live-web tests, push, PR, release, external spending, or shared-service changes were performed.

Parent integrates this commit and owns validation against the combined branch.
