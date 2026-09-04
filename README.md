# Scribebot

A Mac meeting transcriber that never joins your call.

Scribebot captures the audio a meeting app is already playing, plus your own
microphone, and transcribes both on this machine. No bot appears in the
participant list, no audio is uploaded, and no transcript leaves the disk.

It is built for **Hebrew speech carrying English technical terms** — the way
most real engineering meetings in Israel are actually conducted:

> מה מצב פריסת ה SSE אצלך

A general Hebrew model hears `SSE` and writes `אס אס אי`. Scribebot restores the
term.

## What it does

- **Captures system audio per application** using CoreAudio process taps — Zoom,
  Teams, Meet, WhatsApp, anything. No virtual audio driver to install.
- **Records your microphone separately.** Because the two sides are captured to
  separate files and transcribed apart, who spoke is known without any speaker
  diarization at all.
- **Transcribes on-device** with whisper.cpp on Metal, using the
  [ivrit-ai](https://huggingface.co/ivrit-ai) Hebrew `large-v3-turbo` model.
- **Restores English technical terms** that Hebrew ASR transliterates.
- **Summarizes** meetings, and exports transcripts.

## Requirements

- macOS 14.2 or later, Apple Silicon
- Python 3.10+ (`X | None` syntax is used throughout)
- `whisper-cli` — `brew install whisper-cpp`
- The model file, ~1.6 GB, at `models/ivrit-large-v3-turbo.bin`
  (converted from `ivrit-ai/whisper-large-v3-turbo`; `models/` is gitignored)

## Build

```sh
./capture/build.sh    # the audio capture helper (see note below)
./app/build.sh        # the menu bar app -> app/Scribebot.app
```

Both are ad-hoc signed; no Apple developer account is needed. Open
`app/Scribebot.app` and grant, when asked:

- **Screen & System Audio Recording** — this is what lets Scribebot hear the
  call. It is a *different* permission from the microphone, and the capture
  helper hangs indefinitely without it.
- **Microphone** — for your own voice.

Rebuilding the capture helper re-signs its bundle, which can invalidate the
system-audio grant. If capture stops working immediately after a rebuild,
re-approve it in System Settings.

## Use

Open the app, press record, stop when the meeting ends. The transcript is
written to `~/Library/Application Support/Scribebot/recordings/`.

The same pipeline is available from the command line:

```sh
./scribebot.py record 60          # capture 60s of system audio, transcribe
./scribebot.py record 60 --pid 42 # capture one application only
./scribebot.py file meeting.wav   # transcribe an existing file
./scribebot.py rebuild            # re-transcribe stored recordings, repairing
                                  # any transcript that was saved incomplete
```

`rebuild` rewrites `.txt` files only. It never modifies or removes audio.

## Tests

```sh
./check           # all self-checks, a few seconds
./check --e2e     # additionally exercises real audio hardware
```

`./check` passing does not mean the product works — see
[docs/HANDOVER.md](docs/HANDOVER.md), which is blunt about what is proven and
what is not.

## Documentation

| Document | What it covers |
|---|---|
| [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) | How capture, transcription, and the app fit together |
| [docs/HANDOVER.md](docs/HANDOVER.md) | Current state, what is unproven, what to do next |
| [docs/BENCHMARKS.md](docs/BENCHMARKS.md) | Measured results, and how much to trust each number |
| [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) | Symptoms and their real causes |
| [RECORDINGS.md](RECORDINGS.md) | Why the recordings directory must never be touched |
| [CLAUDE.md](CLAUDE.md) | Working rules for AI agents in this repo |

## Privacy

Audio, transcripts, and summaries are written to
`~/Library/Application Support/Scribebot/` and stay there. Nothing in this
project makes a network request at runtime.

Recording a conversation may require the consent of the other participants
depending on where you are. That is your responsibility, not the software's.
