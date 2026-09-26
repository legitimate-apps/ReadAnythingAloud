# ReadAloud: open-source landscape survey

Date: 2026-09-25. Scope: what already exists for URL → readable article → TTS with synced word + sentence highlighting, native macOS + iOS, TestFlight.

Method: GitHub API via `gh` (license SPDX, last push, stars, README, key source files), Exa / DuckDuckGo search, one DeepWiki fetch. GitHub code search hit its rate limit partway through, so a few code-level claims rest on README text or search snippets. The markers below show which.

- **[V]** verified: I read the repo metadata, README, or source myself.
- **[S]** from a search snippet or third-party page.
- **[I]** my inference.

## Bottom line

**Q2. Does anything already do about 90% of the spec under a compatible license? No.**

- No surveyed project combines a native SwiftUI app on both macOS and iOS with URL extraction, a rendered reading view, synced word and sentence highlighting, and a full transport (skip by sentence or paragraph, tap to jump, resume).
- The closest native project is **Articles2Podcast** (MIT, iOS only). It covers roughly half the spec. It does URL → Readability → Kokoro/AVSpeech → a podcast-style player with lock-screen controls. It has no reading view, no highlighting, no macOS target, and no sentence navigation. [V]
- The closest match on behavior is **pcamarajr/kokoro-reader** (MIT). It highlights the current sentence and word with Kokoro word timestamps and supports jump-to-sentence and follow mode. But it is a Chrome extension plus a Python server, not a native app. [V]
- The polished highlighting implementations are **Readest** (AGPL-3.0) and **readalong-reader** (GPL-3.0). Both are copyleft web stacks, so they are useful for ideas only. [V]

**Recommendation:** build new in SwiftUI. Take proven parts under permissive licenses: the Readability extraction package, the Kokoro Swift runtime, and the player and lock-screen patterns from Articles2Podcast. Copy the highlight UX ideas (not the code) from Readest, kokoro-reader and readalong-reader.

## Ranked candidates

Ranked by how useful each is to us, as a code donor or as a UX reference.

| # | Project | Platform / stack | License | Last push | Word hl | Sentence hl | Local neural TTS | Forkability for native Mac+iOS on TestFlight |
|---|---|---|---|---|---|---|---|---|
| 1 | [skywalkerswartz/Articles2Podcast](https://github.com/skywalkerswartz/Articles2Podcast) | iOS 18, SwiftUI + SwiftData, share extension | MIT | 2026-03-07, 1★ | No | No | Yes: KokoroSwift (MLX), AVSpeech fallback | **Best code donor.** Reuse the extractor, player, `MPNowPlaying`/remote commands, share extension and model download. README mentions eSpeakNGLib forks (GPL-3.0) for non-English G2P; `project.yml` does not pin it. **Keep eSpeak out.** [V] |
| 2 | [wolfyy970/audio-monster](https://github.com/wolfyy970/audio-monster) | macOS 14 menu bar, Swift 6.2 | MIT | 2026-09-21, 0★ | No | No | Yes: Kokoro via mlx-audio-swift | Donor for macOS extraction: WebKit hydration plus a native Swift Readability. Output is an M4A file with no reading view. [V] |
| 3 | [pcamarajr/kokoro-reader](https://github.com/pcamarajr/kokoro-reader) | Chrome MV3 + local Python Kokoro server | MIT | 2026-09-24, 1★ | **Yes** (Kokoro word timestamps, English only) | **Yes** | Yes (server) | Not native. It is the best **algorithm and UX reference** and closely matches our spec. [V] |
| 4 | [readest/readest](https://github.com/readest/readest) | Tauri + Next.js; macOS, iOS, Android, Web; on the App Store | **AGPL-3.0** | 2026-09-24, 24.6k★ | **Yes**, Edge TTS (cloud) only | Yes, all engines | No (Edge cloud, Web Speech, native) | **Do not fork.** AGPL, web stack, ebook-focused. The best reference for highlight edge cases (PRs #4566 and #4807). [V] |
| 5 | [BrunoAMSilva/readalong-reader](https://github.com/brunoamsilva/readalong-reader) | Web component | **GPL-3.0** | 2026-06-27 | Yes: exact with system TTS, estimated with Kokoro | Yes, plus focus dimming | Yes: kokoro-js (WebGPU/WASM) | UX reference only (GPL). [V] |
| 6 | [JayFarei/lazyread](https://github.com/JayFarei/lazyread) | macOS local web app (Node, uv, MLX) | MIT | 2026-07-16 | Yes, via Qwen3 forced aligner | Yes | Yes: Qwen3-TTS 1.7B | Reference for the "synthesize, then force-align" approach. Heavy (about 5.4 GB of models). Not native. [V] |
| 7 | [ken107/read-aloud](https://github.com/ken107/read-aloud) | Chrome/Firefox extension | MIT | 2026-09-24, 1.75k★ | Word or section, shown in the popup rather than on the page [S] | Section | No (browser and cloud voices) | JS only. Mature reference for web TTS edge cases. [V license and activity] |
| 8 | [aaajiao/readread](https://github.com/aaajiao/readread) | macOS menu bar SwiftUI + bundled Python | MIT | 2026-05-26 | No (paragraph only) | Paragraph | Yes: kokoro-onnx | The Python sidecar will not ship on iOS. Extraction goes through the Defuddle hosted API (cloud). [V] |
| 9 | [omnivore-app/omnivore](https://github.com/omnivore-app/omnivore) | Read-later service + iOS/macOS apps | **AGPL-3.0** | Repo 2026-09-18; `apple/` last touched 2025-09 | Word-offset tracking from server "speech marks" | Utterance | No (server-side Azure/OpenAI) | **Do not fork.** AGPL and depends on the defunct hosted backend. See `AudioController.swift` for the speech-mark sync pattern. [V] |
| 10 | [Storyteller](https://gitlab.com/storyteller-platform/storyteller) | Self-hosted server + mobile reader | MIT | 2026-09-25 | No | Yes: phrase or sentence aligned to human audiobooks | n/a (alignment, not TTS) | Conceptual reference for how the sentence highlight looks. [V license and activity; S features] |
| 11 | [nedmah/TextLector](https://github.com/nedmah/TextLector) | Kotlin Multiplatform (Android + iOS) | Apache-2.0 | 2026-06-01 | No | Paragraph | Yes: Piper / Supertonic via sherpa-onnx | Not SwiftUI. [V] |
| – | [NetNewsWire](https://github.com/Ranchero-Software/NetNewsWire) | macOS/iOS RSS | MIT | Active | – | – | No TTS | Reader-view UI reference only. [V] |
| – | [wallabag/ios-app](https://github.com/wallabag/ios-app) | iOS | MIT | **Archived** | – | – | – | Dead. [V] |

Other things found that do not fit: Speechify-style clones and Kokoro browser extensions (armand0e, Curious-Ray, fswolf, crocidb), PDF/EPUB readers (openreader, LocalReader-Pro, fox-reader, projectwhy-tts), and hotkey readers (outloud). Voice Dream and Speechify are closed source. Apple's own Safari "Listen to Page" is the de facto native competitor. [I]

## Building blocks (permissive, Swift)

### TTS with timing

- **AVSpeechSynthesizer.** Its `willSpeakRangeOfSpeechString` callback gives *exact* word ranges for free. Two cautions: ranges are UTF-16 offsets, so convert them with `Range(nsRange, in:)`; and emoji can make the highlight drift. [S]
- **[FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio)** (Apache-2.0, 2.9k★, pushed today). Runs Kokoro on CoreML/ANE. Its README table says the Kokoro backend has "GPL dependencies: None". Its docs have a "Word timing" section: `predictedDurations` gives per-token frame counts that you group into words. Caveat: English-only TTS beta. [V]
- **[mlalma/kokoro-ios](https://github.com/mlalma/kokoro-ios)** (MIT, 290★; KokoroSwift on MLX; iOS 18 / macOS 15). Per-token timestamps arrived in 1.0.8. It uses MisakiSwift (Apache-2.0) for G2P, and its eSpeakNG dependency is commented out. [V]
- **[Blaizzy/mlx-audio-swift](https://github.com/Blaizzy/mlx-audio-swift)** (MIT). Offers Kokoro plus Qwen3-ForcedAligner, for aligning any TTS output. [V]
- **Avoid:** eSpeak NG and eSpeakNGSwift (GPL-3.0). [V]

### Article extraction

| Option | License | Status | Notes |
|---|---|---|---|
| [Ryu0118/swift-readability](https://github.com/Ryu0118/swift-readability) | MIT, wraps Mozilla Readability.js (Apache-2.0) | Pushed 2026-09-19, 61★ | Runs the reference Firefox Reader algorithm in WKWebView. Handles JS-rendered pages when fed the rendered DOM. Articles2Podcast uses it and found you must pass the real `baseURL`, or CSP `frame-ancestors` makes Substack and similar sites fail. [V] |
| [lake-of-fire/swift-readability](https://github.com/lake-of-fire/swift-readability) | BSD-3-Clause | Pushed 2026-09-14 | Pure Swift on SwiftSoup. Ports Mozilla's whole fixture corpus at v0.6.0. No WebView, so it suits a share extension's memory limits. [V README] |
| [neolee/swift-readability](https://github.com/neolee/swift-readability) | MIT | 2026-07, 3★ | Pure Swift port that aims for output parity and has diagnostics. Young. [V] |
| [kepano/defuddle](https://github.com/kepano/defuddle) | MIT | Active, 9.5k★ | JS alternative (Obsidian Web Clipper). Could run in WKWebView as a second pass. [V license; I usage] |
| [postlight/parser](https://github.com/postlight/parser) | Apache-2.0 | Last push 2024-07 | Node-centric and stale. **Skip.** [V] |
| exyte/ReadabilityKit | MIT | Archived | **Skip.** [V] |

**Recommendation for extraction:**

- Load the page in an off-screen WKWebView so client-rendered pages hydrate and the user's cookies apply.
- Run Readability.js on the live DOM. Use Ryu0118's package, or vendor Readability.js directly.
- Use the lake-of-fire SwiftSoup port for the share extension, or as a fast path for static HTML.
- Keep Defuddle as a fallback extractor.

I have not measured robustness on a real URL corpus; that is the first spike to run. [I]

## UX patterns worth borrowing

**Highlighting**

1. **Two-tier highlight.** A soft tint on the current sentence and a stronger mark on the current word. readalong-reader adds optional "focus dimming" of the rest of the text. [V]
2. **Never flash the whole sentence before its first word.** Draw the first word immediately (Readest PR #4566). [S]
3. **Word timing loop.** Synthesize one sentence at a time for natural prosody, then highlight word by word. Drive the highlight from a boundary table polled against the audio clock with a display link. Rate changes and pause/resume then need no extra handling (Readest's `EdgeTTSClient`). [S]
4. **Granularity setting (word or sentence)** with automatic fallback to sentence when the engine gives no word timings (Readest PR #4807). [S]
5. **Light only the current range; don't accumulate** previously spoken words. [S]

**Following and navigation**

6. **Follow mode.** Auto-scroll with the voice. When the user scrolls away, stop following and show a "⌖ Follow" or "Back to reading" pill (kokoro-reader, Readest, LocalReader-Pro). [V/S]
7. **Start points.** Start from the selection, else from the first visible sentence. Tap (Alt-click on Mac) any sentence to jump to it. [V]
8. **Keyboard shortcuts** for play/pause and previous/next sentence (kokoro-reader). [V]

**Content handling**

9. Speak headings, paragraphs, list items and block quotes. Skip navigation, comments, share widgets, cookie banners and references (kokoro-reader). [V]
10. Show images, and optionally speak their captions. Show code blocks but skip them in audio, or announce them briefly. [I]

**Audio pipeline**

11. **Prefetch.** Synthesize about 3 sentences ahead. Kokoro runs about 10× realtime on Apple Silicon and about 3.3× on an iPhone 13 Pro. [V]

**Failed extraction and paywalls**

12. Treat very short output (fewer than 50 words) as a paywall or bot-challenge page and show a specific error instead of a TTS failure (Articles2Podcast). [V]
13. Offer these fallbacks [I]:
    - "Open page and retry", which lets the user log in inside the WKWebView.
    - "Read whole page".
    - "Paste text".

## License note for App Store / TestFlight

GPL and AGPL code is widely considered incompatible with App Store terms: the FSF's position, and VLC's removal from the App Store in 2011. This is background knowledge, not re-verified this session. Readest ships on the App Store only because its authors hold the copyright. A fork by us would not have that option.

The same caution applies to TestFlight, since it is Apple distribution under the same terms. [I]

Keep the whole dependency graph MIT, BSD or Apache. Watch transitive G2P dependencies: eSpeak NG is GPL-3.0. The Kokoro model weights are Apache-2.0. [V]
