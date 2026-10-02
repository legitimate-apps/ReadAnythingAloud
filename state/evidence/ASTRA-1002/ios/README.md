# iOS simulator verification — 2026-10-02, 12:32–12:42 EDT

Verified the unchanged production source through `de3b12c` on branch `astra/core-experience-1002`
(final branch head before this evidence update: `1f1988d`). Installed the existing successful Debug
universal simulator build. No test-only app code, delays, engine replacements or new downloads were used.

Device: one leased iPhone 17 Pro, iOS 26.5 (23F77), UDID `6609292F-1E60-4898-8329-797B6967AE0B`.
Imported the synthetic [article fixture](article.txt) through the app's Paste button and selected Karen
in the Apple voices section. After the app stopped, its own container preferences confirmed:
`{"engine":"apple","identifier":"com.apple.voice.super-compact.en-AU.Karen"}`.

## Back to reading while playback advances — passed

1. Started Apple playback at normal speed.
2. Swiped ahead while playback continued. Snapshot15 shows Pause and Back to reading at0:26.
   The [browsing screenshot](browsing-while-playing.jpg) shows the later paragraphs without forcing follow.
3. Tapped Back to reading. Snapshot16 shows Pause at0:39 and no Back to reading button.
   The [returned screenshot](back-to-reading.jpg) shows the currently spoken paragraph3 sentence and word
   highlight in view above the controls. Playback continued.

## Play/Pause during buffering, then Resume — passed at the screen level

1. Stopped the app and removed only `Library/Caches/SpeechClips` inside this owned simulator's app
   container, then relaunched. This gives a genuine uncached Apple synthesis request without changing code.
2. Recorded the screen and used one AXe HID batch: tap `player.playPause`, wait0.12s, tap it again.
   The [four-second recording excerpt](apple-buffering-pause.mp4) shows Play → buffering spinner → Play.
   The [buffering frame](apple-buffering.jpg) is the actual source frame at7.045s, not a reconstruction.
3. [Paused screenshot](apple-paused.jpg) and snapshots18/19 show Play with elapsed1:53 and remaining3:57
   across two later observations. Completion of background synthesis did not start playback.
4. Tapped Play again. Snapshot20 and the [resumed screenshot](apple-resumed.jpg) show Pause, advancing
   elapsed1:56 and the current highlight. The next audio played without resetting the article.

The initial elapsed estimate2:05 became1:53 as real synthesized clip durations populated; the later paused
observations are stable at1:53. The same paragraph8 sentence remains selected. This is UI/runtime evidence,
not an instrumented trace of every sub-frame state or a physical-device audio-quality evaluation.

[Accessibility snapshots](accessibility-snapshots.json) retain the relevant controls, visible text and
elapsed values. The full repeated article field was omitted to keep the evidence readable.

## Cleanup and limits

App stopped. Video recorder exited normally. The simulator was confirmed Shutdown and disposed, and the
follow-up DerivedData lease was released at12:41 EDT. No helper, simulator or build remains for this follow-up.
No merges, releases, paid services or third-party messages. Physical interruption delivery, iPad layout,
and long-text iOS ONNX playback remain separate checks.
