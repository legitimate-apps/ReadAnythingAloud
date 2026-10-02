# Voice robustness — 2026-10-02

Branch: `astra/voice-robustness-1002`, based on `9a42922`. Owned by voice delegate; integrate through parent.

## Picked and why
Long unpunctuated paragraphs are not bounded by DocumentBuilder. FluidAudio 0.17.4 rejects phoneme
strings over 510 scalars, so both Kokoro backends can fail before reading the rest of a passage.
Written character count also cannot bound normalization expansion (numbers, symbols).

## In progress
- Bound document speech units at clauses, whitespace or Unicode grapheme boundaries, preserving original ranges.
- Adaptive Kokoro splitting on the exact phoneme overflow error, preserving audio and original word timings.
- Lease `readaloud-astra-voice-1002` acquired; no simulator needed for initial macOS package checks.

## Next
Run discriminating tests and build, record evidence, commit each coherent fix. No cloud API calls or spending.

## Recovery and completion
Integrator recovered this lane after helper interruption and the 11:40 Terminal crash. Added deterministic
recursive-overflow tests proving exact reconstructed audio, original word timing offsets, Unicode/grapheme
preservation, non-overflow error propagation, inconsistent-rate rejection and cancellation between chunks.
Preserved model revisions: successful ordinary sentences are unchanged and should retain their disk cache.

Observed verification: `swift test --jobs 2 --filter 'KokoroChunkingTests|DocumentBuilderTests'` with integration
DD scratch passed20/20; `voice-chunking.log` in `readaloud-astra-1002` DD. Source diff checked on recovery.
Real model overflow synthesis and iOS device playback remain unproven; helper tests exercise the exact
FluidAudio overflow error handled by both engine wrappers. No new models or cloud calls.
