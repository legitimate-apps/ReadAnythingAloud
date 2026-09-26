# CORPUS — ReadAnythingAloud

*What this project IS and what governs it. Living document: revise points in place, do not append.*

## 1. Thesis

Any web page should become a narrated, read-along document in one gesture. Drop or paste a URL and
you get a clean article, read aloud by a good voice, with the current word and sentence highlighted
in sync — like Storyteller does for audiobooks — and full audio controls. Local and free by default.

## 2. What it is

1. A native SwiftUI app for **macOS, iPhone and iPad** (one multiplatform target), shipped to
   TestFlight under **Legitimate LLC** (team 3LTL47SJ8C). Name: **ReadAnythingAloud**.
2. **Input:** drag-drop or paste a URL (window, Dock icon, `.webloc`, HTML file, plain text), iOS Share
   Sheet extension, open-in via URL scheme.
3. **Extraction:** the page is loaded in an off-screen WKWebView (JS-rendered pages and the user's
   cookies work) and Mozilla Readability (Apache-2.0, bundled) extracts the article; a DOM walker turns it
   into typed blocks (heading, paragraph, list item, quote, code, image, caption).
4. **Voices (engines behind one protocol, unit = sentence):**
   - Kokoro-82M, on-device neural, word timings from the model's predicted durations. macOS runs FluidAudio's
     Core ML graph; iOS runs the int8 ONNX export on ONNX Runtime's CPU provider, because the Core ML graph
     trips an Apple BNNS bug on iOS 26.4+ (FluidAudio #844/#889). FluidAudio supplies the text frontend on both.
   - Apple system voices (AVSpeechSynthesizer `write` + `willSpeakRange` frame stamps).
   - ElevenLabs (optional, user's own key, `with-timestamps` character alignment).
   - Engines without timings → Parakeet TDT v3 (or better) word timestamps aligned to the known text.
     Never Whisper-base (operator rule).
5. **Playback:** AVAudioEngine player → time-pitch (speed without re-synthesis); timings in media time so the
   highlight is a lookup of media time. Sentence audio cached on disk.
6. **Reading view:** TextKit 2 text view; minimal, good-looking highlight: soft sentence tint + an animated
   word pill. Tap a word to jump, follow mode with "back to reading", resume position per article.
7. **Look:** signature color is a desaturated, slightly dark salmon (asset `AccentColor`, `Color.signature`;
   operator 2026-09-25). Icon, highlights and controls use it.

## 3. Constraints

1. **Public open source, MIT** (operator 2026-09-25). Every dependency MIT/BSD/Apache. No GPL/AGPL
   (App Store incompatibility): no espeak-ng, no Readest/Omnivore code.
2. Public repo ⇒ **no self-hosted runners**; CI is local builds (or hosted Linux-only checks).
3. Repo `legitimate-apps/ReadAnythingAloud`, identity `legitimate-apps`
   (309192374+legitimate-apps@users.noreply.github.com), per-command. No legal name in content.
4. Standalone: Storyteller / SpeedRead are references only, never dependencies.
5. No new spend or accounts without the operator. ElevenLabs is bring-your-own-key.

## 4. Done means

On TestFlight (macOS + iOS), installable, verified on real articles: a long one, one with images and
lists, and one paywalled/broken (fails gracefully). Highlighting stays in sync through speed changes and
seeks.
