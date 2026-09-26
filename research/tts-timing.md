# ReadAloud — TTS + highlight-timing architecture (research, 2026-09-25)

Legend: **[V]** verified today against source/docs/API, **[O]** observed by running code on this Mac (macOS 26.7), **[I]** inferred / not yet verified — measure before relying on it.

## TL;DR decision

1. **Default local engine: Kokoro-82M, via FluidAudio.** It is Apache-2.0 end to end with no GPL G2P, and `KokoroAneManager.synthesizeDetailed` already returns **per-phoneme durations** plus the normalized text. Word timing therefore comes free from synthesis. No ASR pass is needed.
2. **iOS caveat (the biggest risk):** FluidAudio's own docs say the Kokoro **Core ML** chain has **uncatchable crashes in Apple's Core ML runtime during long iOS sessions** (iOS 26.6, iOS 27), and the maintainers closed #889 as "not planned" today. For iOS, keep FluidAudio's G2P/vocab/voices but put a **second executor behind the engine protocol: the same Kokoro graph on ONNX Runtime's CPU provider**. That route has a 2 h 34 min crash-free full-book report on iOS 27. Choose between the two executors after a device soak.
3. **Timing per engine:** Kokoro → `pred_dur` (native). AVSpeechSynthesizer → `write()` plus the delegate's `willSpeakRange`, stamped with the running frame count. ElevenLabs → character alignment. Any other engine (Supertonic‑3, PocketTTS, …) → Parakeet TDT v3 word timestamps (FluidAudio) aligned to the known text.
4. **Speed:** time-stretch playback (`AVAudioUnitTimePitch.rate` or `AVPlayer.rate` with a pitch-preserving `audioTimePitchAlgorithm`). Timings stay in *media time*, so the highlight is a lookup on the current media time and nothing is re-synthesized. The engine's own `speed` is a voice-pacing preference that becomes part of the cache key.
5. **Unit = sentence.** Synthesize, cache and time each sentence separately. That gives exact sentence boundaries, confines word-alignment errors to one sentence, fits Kokoro's 510-phoneme cap, and makes seeking and caching trivial.

## 1. On-device TTS candidates

| Engine (Swift route) | Quality | Size | Speed (measured where stated) | License: code / weights | Swift maturity | Durations / timestamps exposed? |
|---|---|---|---|---|---|---|
| **Kokoro-82M — FluidAudio `KokoroAneManager`** (Core ML, ANE) | Best-in-class small TTS; FluidAudio en WER 0.68% on the MiniMax set after the #700 fix [V] | ~0.33 GB [V] | 31× (M5 Pro) [V]; 18–21× on iPhone 17 Pro Max (issue #844 report) [V-report] | Apache-2.0 / Apache-2.0 [V]; README: "GPL dependencies: None" [V] | High: v0.17.4 released today, very active, iOS showcase apps (e.g. "Local Narrator") [V]. **iOS long-session crashes, see §1a** | **Yes.** `KokoroAneSynthesisResult.predictedDurations: [Int32]` (frames per input token) + `inputIds`, `phonemes`, `normalizedText` [V] |
| Kokoro — **MLX Swift** (`Blaizzy/mlx-audio-swift`) | same model | ~0.3 GB | GPU/Metal [I] | MIT / Apache [V] | Good, active (Sep 18) [V] | **Yes.** `KokoroModel.generateWithDurations(...) -> (audio, phonemes, durations)` [V] |
| Kokoro — **`mlalma/kokoro-ios`** (MLX + MisakiSwift) | same | ~0.3 GB | ~3.3× on iPhone 13 Pro (README) [V-claim] | MIT; MisakiSwift Apache-2.0 [V] | Stale (last push Jan 2026) [V] | **Yes, word level.** `generateAudio(...) -> ([Float], [MToken]?)`; `TimestampPredictor` fills per-token `start_ts/end_ts` (port of `KPipeline.join_timestamps`) [V] |
| Kokoro — **sherpa-onnx** | same | ~80–330 MB | CPU [I] | Apache-2.0 [V]; bundles espeak-ng (GPL-3) [I-known] | Mature C API | **No.** `SherpaOnnxGeneratedAudio` = `samples, n, sample_rate` only [V] |
| Kokoro — **kokoro-onnx** (Python) | same | 88–310 MB | — | MIT [V]; espeak-based G2P | Python only | Yes, **if** the ONNX export has a `duration` output (`scripts/export.py`, `create_timed`). The `onnx-community/Kokoro-82M-v1.0-ONNX` export has no such output [I]. This is the ONNX to reuse on iOS |
| **Supertonic‑3** (FluidAudio `Supertonic3Manager`) | Good, 31 languages, en WER 1.02% [V] | int4 ~0.10 GB [V] | 94× (M5 Pro) [V]; "2 min of audio in 3 s" on iPhone 17 Pro (showcase) [V-claim] | MIT / **OpenRAIL(++)** weights: use restrictions [V] | Newer (conversion updated today) | **No per-word timing.** The duration predictor is utterance-level [V] → needs ASR alignment |
| **PocketTTS** (Kyutai; FluidAudio `PocketTtsManager`, also mlx-audio-swift) | Very good, voice cloning, en WER 0.51% [V] | ~330 MB fp16 [V] | 6.5× (M5 Pro); streaming TTFA 26 ms [V] | MIT / **CC-BY-4.0**, HF gated (auto) [V] | Good; iOS 18/macOS 15 APIs [V] | **No.** Autoregressive over 80 ms frames, no phoneme stage → ASR alignment |
| Chatterbox / Nano (FluidAudio beta), NeuTTS, LuxTTS, StyleTTS2 | Varying | 0.1–1 GB | slower | mostly MIT/Apache/research | Beta | No word timing |
| KittenTTS | Lower than Kokoro | 15–80M | fast | Apache-2.0 | FluidAudio rejected it ("inefficient espeak alternatives") [V] | No |
| Orpheus 3B, Sesame CSM-1B, Dia-1.6B, VibeVoice, Kyutai TTS 1.6B | High / expressive | 0.5–3B | Not iPhone-real-time for long-form [I] | Apache/MIT/CC-BY [V] | None production-ready in Swift | No (Kyutai's **STT** has word timestamps; its TTS was not checked) |

### 1a. Kokoro Core ML on iOS — crash evidence [V]
- `Documentation/TTS/KokoroAne.md` "Known OS issues": BNNS SIGSEGV on iOS 26.6 (#844); on iOS 27, an MPSGraph SIGABRT on the GPU route and a `vadd_fp16_sme` SIGSEGV on the CPU-tail route (#889). The doc says there is "currently no OS version or routing on iOS that is demonstrated safe for long sessions".
- #844 reporter (iPhone 17 Pro Max, iOS 26.6): crashes appeared after about 8–20 synthesis calls while reading articles. That is exactly our workload.
- #889: the same Kokoro v1.0 graph on **onnxruntime 1.24.2 CPU EP**, fed by FluidAudio's `phonemes(for:)`, `KokoroAneVocab.encode` and voice packs, ran **2 h 34 min** with no crash on an iPad M5 with iOS 27. Another contributor found that running the Core ML parts through Accelerate also avoided the crash. Closed 2026-09-25 as not planned (an Apple runtime bug).
- iOS 27 background ANE inference needs the `com.apple.developer.background-tasks.continued-processing.inference` entitlement [V]. Metal/GPU work (MLX) is not permitted in the background [I-known platform rule], so the MLX routes cannot synthesize while the screen is locked.

### 1b. Phoneme → word mapping
- Kokoro frame = 600 samples at 24 kHz = **25 ms** at speed 1.0. The reference `KPipeline.join_timestamps` uses `MAGIC_DIVISOR = 80` (half-frames) and splits each space token's duration between its neighbours [V]. `mlx-audio-swift` suggests `secondsPerFrame = audioSeconds / durations.sum()`, which is robust to the `speed` setting [V].
- FluidAudio recipe (the author of issue #943 does exactly this for karaoke highlighting on iOS): split `inputIds` on the vocab space token → per-word groups. `normalizedText` (added in #943) gives the spoken words, so "$45" → "forty five dollars" can be mapped back to one display word. Chunked input gets a BOS/EOS pair per chunk. Synthesizing per sentence avoids that bookkeeping.
- G2P on iOS: FluidAudio uses the Misaki lexicon with a BART Core ML fallback for out-of-vocabulary words; there is no espeak (GPL) [V]. sherpa-onnx, kokoro-onnx and KittenTTS rely on espeak-ng, which is GPL-3 and a problem for App Store distribution [I-known].
- Map spoken words to display words with a word-level Levenshtein / Needleman–Wunsch alignment of the normalized spoken tokens against tokenized source words. Merge many-to-one matches and interpolate unmatched spans.

## 2. FluidAudio (github.com/FluidInference/FluidAudio) [V]
- Apache-2.0, v0.17.4 (2026-09-25). `Package.swift`: macOS 14 / iOS 17 minimum; PocketTTS and Chatterbox need macOS 15 / iOS 18.
- TTS: KokoroAne (en, zh, ja, es, fr; 54 English voice packs), PocketTTS, Supertonic‑3, StyleTTS2, LuxTTS, NeuTTS, Inflect, and Chatterbox (beta). The README still labels TTS "Beta".
- ASR: Parakeet TDT v3 0.6B (library default, 25 languages), Parakeet Ultra (recommended), Parakeet Redux (~220 MB, iOS 18+), v2 English, Nemotron streaming. `ASRResult.tokenTimings: [TokenTiming]` and the public `buildWordTimings(from:) -> [WordTiming]` [V]. Parakeet v3 weights are CC-BY-4.0 (attribution required).
- **Timings: Kokoro yes (`predictedDurations`); every other FluidAudio TTS backend no.** Parakeet provides word timestamps for arbitrary audio, so one package covers both TTS and alignment.
- `ModelHub.offlineMode` lets the app ship or stage models without contacting HuggingFace at runtime.

## 3. AVSpeechSynthesizer
- `speechSynthesizer(_:willSpeakRangeOfSpeechString:utterance:)`: iOS 7+ / macOS 10.14+, "generally a word" [V].
- `write(_:toBufferCallback:toMarkerCallback:)` and `AVSpeechSynthesisMarker` (`mark` word/sentence/paragraph/phoneme/bookmark, `textRange`, `byteSampleOffset`): **iOS 16+ / macOS 13+** [V] (not iOS 17).
- **[O] macOS 26.7, default compact voice:** `write` produced 102,328 frames (22.05 kHz), but the **marker callback delivered 0 markers**. This matches the SO #78541092 reports for iOS 17 and 18.4. The delegate's **`willSpeakRange` did fire 14 times during `write`**, interleaved with the buffer callbacks. Recording the cumulative frame count at each callback gave monotonic, plausible word-start offsets ("Reading" at 2.92 s, "fun." at 4.20 s). Probe: `research/avspeech-write-probe.swift`. Not yet checked: iOS, Premium/Enhanced voices, and Personal Voice.
- Recipe: render sentences with `write`, stamp `willSpeakRange` with the running frame count, and cache as with the neural engines. Seeking and rate changes then work the same way. The fallback is live `speak()` with `willSpeakRange`, where a rate change means restarting the utterance at the current word.
- Enhanced/Premium voices are user-downloaded, and there are known premature-stop bugs with some voice + string combinations (Apple forums 737685). Keep utterances at sentence size.

## 4. ElevenLabs (cloud option) [V]
- `POST /v1/text-to-speech/{voice_id}/with-timestamps` returns `{audio_base64, alignment{characters[], character_start_times_seconds[], character_end_times_seconds[]}, normalized_alignment{…}}`. `/stream/with-timestamps` returns a stream of JSON chunks with the same fields. Whether chunk times are relative to the chunk or the request is not documented, so verify empirically. `output_format` defaults to `mp3_44100_128`.
- Models: `eleven_flash_v2_5` (32 languages, 40k-character limit), `eleven_multilingual_v2` (10k limit; the API default; "most stable long-form"), `eleven_v3` (5k limit; **request stitching is not available**). The pricing page shows a 40k limit for v2/v3, which conflicts with the models page; use the lower number.
- Price: **$0.05 per 1k characters for Flash/Turbo, $0.10 per 1k for Multilingual v2/v3**. A 2,000-word article is about 12k characters, so roughly $0.60 on Flash or $1.20 on v2.
- Chunking: split by paragraph at ≤ ~2–3k characters, pass `previous_text`/`next_text`, or `previous_request_ids` (max 3, less than 2 h old, same model). Word timing = group `alignment` characters on whitespace, then add the chunk's offset.

## 5. Fallback alignment
- **Parakeet TDT v3 via FluidAudio:** `AsrModels.downloadAndLoad(version: .v3)`, `AsrManager().transcribe(samples)`, then `buildWordTimings(from: result.tokenTimings!)` [V]. On Mac, `senstella/parakeet-mlx` (Apache-2.0) also gives word timestamps [V].
- Known text: per sentence, align ASR words to source words (edit-distance DP), then interpolate the gaps. Sentence bounds are already exact from the chunk boundaries. Storyteller does the same thing at book scale. It started with Whisper word timestamps plus Levenshtein fuzzy sentence matching and moved to MMS CTC emissions plus n-gram anchors plus CTC Viterbi forced alignment [V, smoores.dev]. FluidAudio's catalog lists a Qwen3-ForcedAligner Core ML port as *not supported* (large footprint) [V].

## 6. Recommended architecture
```
Article → Readability extract → sentence segmentation (NLTokenizer .sentence, keep source ranges)
  → per sentence: TTSEngine.synthesize(sentence) -> SentenceAudio{pcm, sampleRate, wordTimings[(sourceRange, t0, t1)]}
       KokoroEngine      (FluidAudio G2P + executor: CoreML-ANE on macOS; ORT-CPU or CoreML on iOS after soak) → pred_dur
       AppleVoiceEngine  (AVSpeechSynthesizer.write + willSpeakRange frame stamps)
       ElevenLabsEngine  (with-timestamps char alignment; opt-in, BYO key or paid tier)
       OtherEngine       (Supertonic-3/PocketTTS) → Parakeet v3 word timings → text alignment
  → cache: <articleID>/<engine>-<modelVer>-<voice>-<pace>/<sentenceIdx>.m4a (AAC 24 kHz mono) + timings.json
  → playback: AVAudioEngine[AVAudioPlayerNode → AVAudioUnitTimePitch] scheduling sentence buffers with lookahead;
     timeline = Σ sentence durations; highlight = binary search(mediaTime) → word/sentence
```
- **Speed changes:** set `AVAudioUnitTimePitch.rate` (0.5×–3×; the documented range is 1/32–32). Media time is unchanged, so the timing tables stay valid. When the article is fully rendered, `AVPlayer` over the concatenated file (`audioTimePitchAlgorithm = .timeDomain` for speech) is simpler for Now Playing, scrubbing and background playback. The highlight comes from `currentTime()` through a periodic observer. [I] With AVAudioEngine, derive media time from your own scheduled-frame bookkeeping plus `playerNode.playerTime(forNodeTime:)`, and check its semantics under TimePitch in a spike.
- **Scrubbing:** seek to a sentence start (exact) or a word start. Out-of-cache seeks synthesize that sentence first; Kokoro takes about 0.25 s per sentence on Mac.
- **Background:** pre-render ahead while in the foreground. For locked-screen synthesis use the CPU route (ORT) or the iOS 27 ANE entitlement, never MLX/GPU.
- **Cache key:** hash of (normalized sentence text, engine, model revision, voice, engine pace). Store in `Caches/` (purgeable), with an optional "download for offline" copy in Application Support.

## Open items to measure (spike checklist)
1. Kokoro ORT-CPU real-time factor on an iPhone (A17/A18) using a duration-output ONNX export. Kokoro CoreML soak on iOS 27: 100+ sentence calls.
2. AVSpeech `write` + `willSpeakRange` on iOS with Premium, Enhanced and Personal voices.
3. Accuracy of FluidAudio `predictedDurations` → word start compared with Parakeet timings on a few articles (expect under ~50 ms).
4. Relative vs absolute times in ElevenLabs stream chunks.
