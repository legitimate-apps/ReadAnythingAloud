# ReadAnythingAloud

Drop in a link and listen. ReadAnythingAloud turns any web article into a narrated, read-along page: a
clean reading view, a natural voice, and the current sentence and word highlighted in sync as it reads.

- **macOS, iPhone and iPad.** Drag a link, `.webloc` or HTML file onto the window, paste a URL, or use
  Share → ReadAnythingAloud from Safari (the page is captured as you see it, so articles you are signed in
  to work too).
- **Local and free by default.** On-device neural voice (Kokoro-82M) with word timings from the model
  itself; Apple system voices for other languages; ElevenLabs optional with your own API key.
- **Full controls.** Play/pause, skip by sentence or paragraph, scrub, 0.5–3.5× speed without
  re-synthesis, tap any word to read from there, and every article resumes where you left off.
- **Honest failures.** Blocked or paywalled pages say so and offer to open the page (sign in, pass a
  check) or paste the text; paywall teasers are flagged as previews.

## Building

Requires Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
xcodegen generate
open ReadAnythingAloud.xcodeproj
```

The engine, extraction and timing code live in the `ReadAloudKit` Swift package (`swift test` in
`Packages/ReadAloudKit`). The first use of the natural voice downloads its model (about 150 MB on macOS,
250 MB on iOS).

## License

MIT (see `LICENSE`). Third-party components and model weights are credited in `NOTICE`.
