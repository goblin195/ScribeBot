# Handover

State of the project as of 2026-09-05. Written to be useful to whoever picks
this up, including its own author six months from now.

## What works

- **System audio capture** per application, via CoreAudio process taps, with no
  virtual audio driver and without joining the call as a participant.
- **Microphone capture** on an independent engine, so your voice is recorded
  even when the call is silent.
- **On-device transcription** of Hebrew with embedded English technical terms,
  at roughly 0.5 s per chunk.
- **Speaker attribution** for two-party calls, exactly, by capturing each side
  to its own file.
- **Term restoration**, summaries, export, and a menu-bar GUI.
- `./check` — self-checks covering the glossary, the app's wiring, the
  environment, and the scoring metrics.

## What is not proven

Be honest about these when reporting status.

1. **Diarization has never been measured on real multi-speaker audio.** Every
   diarization error rate in [BENCHMARKS.md](BENCHMARKS.md) comes from synthetic
   text-to-speech. Getting one real recording of several people on one
   microphone, hand-labelled, is the highest-value missing piece of evidence.
2. **The transcription advantage over Tape is post-processing, not
   recognition.** The two decoders tie; the glossary is the entire difference.
   Do not describe it as better Hebrew ASR.
3. **The test suite does not drive the UI.** It reads Swift source and runs the
   pipeline directly. Every serious defect so far was found by a human using the
   app — silent recordings, truncated transcripts, stale GUI text.
4. **Latency behind live speech has not been measured end to end.** The 0.51 s
   figure is decode throughput.

## Open items

- **Surface the microphone quality warning in the UI.** `tap.swift` detects a
  Bluetooth hands-free profile (≤16 kHz input) and prints a warning, but
  `Recorder.swift` sends the helper's stderr to `FileHandle.nullDevice`, so the
  user never sees it. They instead experience it as "I can't hear myself". This
  is the most valuable small fix outstanding.
- **`docs/progress.html`** is a progress page from the build and is not
  maintained. Either update it or retire it.
- **A stray file named `10`** sits in the repository root, apparently from a
  mistyped redirect. Confirm before removing.
- **Build artifacts are committed** — `app/Scribebot.app` and
  `capture/ScribebotCapture.app` binaries are tracked. Convenient for handing
  someone a working app, unusual for a source repository.

## Where the bodies are buried

Read [CLAUDE.md](../CLAUDE.md) before changing anything. The short version:

- The recordings directory is irreplaceable user data. Ten files have already
  been destroyed. See [RECORDINGS.md](../RECORDINGS.md).
- A Finder-launched app has no shell environment. This has caused three separate
  shipped bugs. `bench/env_isolation.py` exists to catch the fourth.
- Never swallow a subprocess exit status. Every silent-failure bug here came
  from that.
- The glossary matches exact aliases only. Fuzzy matching was tried; it improved
  the benchmark and corrupted real data.

## Verification standard

A fix to the transcription path is not proven by `./check`. It is proven by **a
recording made from the app itself whose `.txt` on disk is complete without
running `rebuild`**. Confirm the running app is the binary you built before
concluding anything.

## Suggested next steps, in order

1. Surface the microphone warning in the UI — small, and it removes the most
   confusing failure mode a user hits.
2. Record one real multi-speaker meeting, label it, and score diarization
   against it. Until then, that column of the benchmark table is unsupported.
3. Measure true end-to-end latency behind live speech.
4. Grow `bench/aliases.json` from real transcripts. This is where accuracy
   gains actually live. Run `./check` after each addition — the negative
   control will catch an alias that damages ordinary Hebrew.
