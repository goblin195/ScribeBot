# Architecture

## Shape of the thing

```
  meeting app (Zoom/Teams/Meet)          your voice
          │ CoreAudio process tap             │ AVAudioEngine
          ▼                                   ▼
   <id>.wav  (them)                    <id>-you.wav  (you)
          │                                   │
          └─────────────┬─────────────────────┘
                        ▼
             scribebot.py file <wav>
                        │
              whisper-cli (Metal, ivrit-ai large-v3-turbo)
                        │
              bench/glossary.py — restore English terms
                        ▼
                    <id>.txt
```

Everything runs locally. Nothing in the runtime path opens a socket.

## Why two files instead of diarization

The single most useful decision in this project: **capture each side to its own
file and transcribe them separately.** Who spoke is then a property of which
file the words came from, not something a clustering algorithm has to infer.
Speaker attribution for the common two-party case is exact and free.

Diarization code exists (`bench/der.py`, `bench/run_sherpa_diar.py`) for the
harder case of several people sharing one room microphone. It is not on the
path the app uses.

## Capture — `capture/tap.swift`

A single Swift helper, built as an `.app` bundle, with subcommands:

| Subcommand | Purpose |
|---|---|
| `list` | enumerate processes producing audio |
| `record <secs> <out.wav> [--mic] [pid...]` | fixed-length capture |
| `record-split` | system audio and microphone to separate files |
| `mic <out.wav> [secs] [--stream]` | microphone only |
| `stream [--mic] [pid...]` | continuous capture on stdout |

Three things about this file are load-bearing and were each learned the hard
way:

- **The permission is `kTCCServiceAudioCapture`,** requested through the TCC
  private framework, and it is *not* microphone permission. Without it,
  `AudioDeviceCreateIOProcIDWithBlock` hangs forever inside `mach_msg` with no
  error. Requesting `AVCaptureDevice` authorization does nothing for it.
- **The aggregate device needs a clock source** (`kAudioAggregateDeviceMainSubDeviceKey`),
  and it only runs its IO callback while something is actually playing. This is
  why the microphone cannot ride on the same aggregate device: a silent call
  would stop your own voice from being recorded. The mic runs on its own
  independent `AVAudioEngine`.
- **`installTap` must use the node's *output* format,** not its input format.
  With the wrong format the tap runs and writes nothing, silently.

WAV headers are finalized on close, so the helper installs `SIGTERM`/`SIGINT`
handlers. Without them, stopping a recording left a file with a zero-length
header — a recording that looked silent because it *was* structurally empty.

## Transcription — `scribebot.py`

`file` decodes a WAV with `whisper-cli` and restores terms. `record` captures
first. `rebuild` re-transcribes stored recordings and repairs any `.txt` that
was written incomplete; it never touches audio.

External binaries are resolved through `toolpaths.py`, absolutely. A bare
command name works in your shell and fails inside a Finder-launched app — see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## Term restoration — `bench/glossary.py`

Hebrew ASR transliterates English technical vocabulary: `SSE` becomes
`אס אס אי`, `Kubernetes` becomes `קוברנטיס`. The restorer maps known
transliterations back, matching **exact aliases only** (`bench/aliases.json`,
13 terms today).

It used to do fuzzy romanization matching. That scored better on the benchmark
and corrupted real data — it rewrote 15.4% of a sample of real calendar strings,
turning `מטריקס` into `metrics` seventeen times. Fuzzy matching was removed and
the benchmark score was allowed to fall. `bench/negative_control.py` holds 45
sentences, including adversarial Hebrew and English prose, that must pass
through completely untouched.

**Add terms to `aliases.json` rather than making the matcher cleverer.**

## Streaming preview — `stream.py`, `live.py`

While recording, a live preview is produced with LocalAgreement-2: a word is
confirmed once two consecutive decodes agree on it at the same **absolute**
position in the stream. Timestamps are absolute precisely so that trimming the
buffer does not shift the text underneath the comparison — the earlier
window-relative version oscillated between a third and a half coverage.

The preview is best-effort. Its coverage swings with decode timing, so when
recording stops the app re-transcribes the saved files in one pass and replaces
it. **A transcript on disk that looks truncated is almost always the live
preview left in place because finalization failed.**

## The app — `app/Sources/`

A SwiftUI menu-bar app (`LSUIElement`), ad-hoc signed, no Xcode project.

| File | Role |
|---|---|
| `Recorder.swift` | spawns the capture helpers, owns start/stop, finalization |
| `Store.swift` | paths, library persistence, transcript cache |
| `Transcript.swift`, `TranscriptView.swift` | transcript model and rendering |
| `RTL.swift` | bidirectional text layout for mixed Hebrew/English |
| `Summarizer.swift`, `SummaryPanel.swift` | summaries |
| `Permissions.swift`, `OnboardingView.swift` | first-run permission flow |

Two ordering rules in `Recorder.swift` are guarded by `bench/wiring.py` because
breaking either loses user data:

1. **The finalized transcript is written to disk before hopping to the main
   queue.** Hopping first meant that quitting during the second it takes to
   decode lost the accurate transcript and left the preview fragment as the
   permanent record.
2. **A non-zero exit from the transcriber is surfaced,** never swallowed. Every
   silent-failure bug in this project's history came from ignoring an exit code.

The transcript cache is invalidated by file modification date. Without that,
`rebuild` would repair a transcript on disk that the UI kept showing stale.

## Tests — `check`, `bench/`

`./check` runs every self-check. Notable members:

- `bench/wiring.py` — reads `Recorder.swift` and asserts 10 wiring facts about
  the app, including the two ordering rules above.
- `bench/env_isolation.py` — runs the pipeline under exactly the environment a
  Finder-launched app gets. Three shipped bugs would have been caught here.
- `bench/negative_control.py` — 45 sentences the glossary must not touch.
- `bench/score.py`, `bench/der.py` — word error rate, term preservation,
  diarization error rate.

An earlier version of `check` could not fail: it read `$?` after a pipeline,
which is `tail`'s status. Exit status is now captured before any pipe.
