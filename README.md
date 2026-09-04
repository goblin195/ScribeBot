<div align="center">

# 🎙️ Scribebot

### Meeting transcription for Mac that never joins your call.

No bot in the participant list. No audio leaving your machine.
Built for Hebrew speech carrying English technical terms.

[![macOS 14.2+](https://img.shields.io/badge/macOS-14.2%2B-black?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-arm64-black?logo=apple&logoColor=white)](https://support.apple.com/en-us/HT211814)
[![Python 3.10+](https://img.shields.io/badge/Python-3.10%2B-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![Swift](https://img.shields.io/badge/Swift-SwiftUI-F05138?logo=swift&logoColor=white)](https://developer.apple.com/swift/)
[![License: MIT](https://img.shields.io/badge/License-MIT-22c55e)](LICENSE)
[![On-device](https://img.shields.io/badge/inference-100%25%20on--device-8b5cf6)](#-privacy)

</div>

---

## The problem it exists to solve

Real engineering meetings in Israel are conducted in Hebrew with English
technical terms dropped in mid-sentence. Every general-purpose Hebrew speech
model mangles exactly the words that carry the meaning:

```text
Actually said     מה מצב פריסת ה SSE אצלך
Generic Hebrew ASR    מה מצב פריסת ה אס אס אי אצלך     ← the term is gone
Scribebot         מה מצב פריסת ה SSE אצלך             ← restored
```

Lose `SSE`, `DLP`, `Kubernetes`, `latency`, and a transcript of a technical
meeting becomes unsearchable and nearly useless. Scribebot treats those terms as
the payload, not as noise.

## What makes it different

|  | Scribebot | Meeting bots | Most Mac recorders |
|---|:---:|:---:|:---:|
| Joins your call as a participant | **Never** | Yes | No |
| Audio leaves your machine | **Never** | Yes | Often |
| Needs a virtual audio driver | **No** | — | Usually |
| Knows who said what | **Exactly** | Varies | Guessed |
| English terms inside Hebrew | **Restored** | Mangled | Mangled |

**Speaker attribution without diarization.** Scribebot captures the call and
your microphone to two separate files and transcribes them apart. Who spoke is
then a fact about which file the words came from — not something a clustering
algorithm has to guess. For two-party calls it is exact and free.

## Features

- 🎧 **Per-application system audio** via CoreAudio process taps — Zoom, Teams,
  Meet, WhatsApp. No driver to install, no participant to admit.
- 🧠 **On-device transcription** with whisper.cpp on Metal and the
  [ivrit-ai](https://huggingface.co/ivrit-ai) Hebrew `large-v3-turbo` model.
- 🔤 **Technical term restoration** — the piece that makes the transcripts
  usable, and the easiest place to contribute.
- 👥 **Exact speaker attribution** for two-party calls.
- ⚡ **~0.5 s decode per chunk**, with a live preview while you talk.
- 📝 **Summaries and export**, plus a native SwiftUI menu-bar app.
- 🔒 **No network calls at runtime.** At all.

## Quick start

```sh
brew install whisper-cpp                # the decoder
git clone https://github.com/goblin195/ScribeBot.git && cd ScribeBot

# the Hebrew model (~1.6 GB) -> models/ivrit-large-v3-turbo.bin
# converted from ivrit-ai/whisper-large-v3-turbo

./capture/build.sh                      # audio capture helper
./app/build.sh                          # menu bar app -> app/Scribebot.app
open app/Scribebot.app
```

On first launch macOS asks for two **separate** permissions:

| Permission | Why | If denied |
|---|---|---|
| **Screen & System Audio Recording** | to hear the call | capture hangs forever, silently |
| **Microphone** | to hear you | your side records as silence |

> The system-audio permission is `kTCCServiceAudioCapture` and is *not* the
> microphone permission. Granting the microphone does nothing for it. This
> catches everyone once.

### Command line

```sh
./scribebot.py record 60          # capture 60s of system audio, transcribe
./scribebot.py record 60 --pid 42 # capture a single application
./scribebot.py file meeting.wav   # transcribe an existing file
./scribebot.py rebuild            # repair any transcript saved incomplete
```

`rebuild` rewrites `.txt` files only — it never touches audio.

## How it works

```
  meeting app (Zoom/Teams/Meet)          your voice
          │ CoreAudio process tap             │ AVAudioEngine
          ▼                                   ▼
   <id>.wav  (them)                    <id>-you.wav  (you)
          │                                   │
          └─────────────┬─────────────────────┘
                        ▼
              whisper.cpp on Metal
           ivrit-ai large-v3-turbo (Hebrew)
                        │
              glossary — restore English terms
                        ▼
                    <id>.txt
```

Full detail in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Benchmarks

Measured against Tape 0.9.3 on the same audio:

| Metric | Scribebot | Tape 0.9.3 |
|---|:---:|:---:|
| Technical terms preserved | **70.2%** | 46.8% |
| Word error rate | **16.5%** | 21.2% |
| Decode time per chunk | **0.51 s** | 1.62 s |
| Diarization error rate ⚠️ | **15.4%** | 41.0% |

**Read this before quoting those numbers.** The two decoders tie at 46.8% term
preservation — running *Tape's own transcripts* through Scribebot's glossary
scores marginally better than Scribebot's own output. The advantage is a
post-processing stage Tape does not ship, **not** better Hebrew recognition. And
⚠️ every diarization figure comes from synthetic text-to-speech; no real
multi-speaker recording has ever been scored.

[docs/BENCHMARKS.md](docs/BENCHMARKS.md) keeps the full caveats, including two
claims this project got wrong and retracted.

## 🤝 Contributing

Contributions are genuinely welcome, and one of them is unusually easy to make.

### ⭐ Start here: teach it a term

The glossary is where accuracy actually lives, it needs no Swift, no audio
knowledge, and no model. If you have ever watched a Hebrew transcript turn
`Kubernetes` into `קוברנטיס`, you can fix it in `bench/aliases.json`:

```json
{
  "Kubernetes": ["קוברנטיס", "קוברנטס"],
  "Postgres":   ["פוסטגרס"]
}
```

Then:

```sh
./check     # the negative control will reject an alias that damages Hebrew
```

Open a PR with the term and one real sentence it appears in. **This is the
highest-value contribution to the project**, and it scales to any domain —
security, medicine, finance, law — and to any language pairing that
code-switches into English.

### Other good places to start

| Area | What's needed | Difficulty |
|---|---|:---:|
| Glossary terms | Hebrew transliterations of English tech terms | 🟢 easy |
| Surface the mic warning | Bluetooth-headset warning exists but is swallowed by the UI | 🟢 easy |
| Real diarization data | One labelled multi-speaker recording; the benchmark is synthetic | 🟡 medium |
| Latency measurement | True end-to-end lag behind live speech is unmeasured | 🟡 medium |
| Another language | The architecture is not Hebrew-specific — only the model and glossary are | 🔴 involved |

[docs/HANDOVER.md](docs/HANDOVER.md) is an honest account of what works, what is
unproven, and what to do next. Read it before picking something up.

### House rules

1. **Run `./check` before opening a PR.** It is a few seconds and it has caught
   real regressions.
2. **A benchmark gain that fails the negative control is a regression.** Fuzzy
   term matching was tried; it improved the score and corrupted 15.4% of real
   strings. `bench/negative_control.py` holds 45 sentences that must survive
   untouched.
3. **Never swallow a subprocess exit status.** Every silent-failure bug in this
   project's history came from that.
4. **Comments explain *why*,** usually by naming the bug that motivated the line.

See [CONTRIBUTING.md](CONTRIBUTING.md) for the full workflow.

## Project layout

```
scribebot.py          transcribe / record / rebuild
stream.py, live.py    live preview (LocalAgreement-2)
toolpaths.py          absolute binary resolution
capture/tap.swift     CoreAudio process taps + microphone
app/Sources/          SwiftUI menu-bar app
bench/                scoring, glossary, regression guards
docs/                 architecture, handover, benchmarks, troubleshooting
```

## 🔒 Privacy

Audio, transcripts, and summaries are written to
`~/Library/Application Support/Scribebot/` and stay there. **Nothing in this
project makes a network request at runtime.** There is no telemetry, no account,
and no cloud component to opt out of.

Recording a conversation may require the consent of the other participants where
you live. That is your responsibility, not the software's.

## Documentation

| Document | What it covers |
|---|---|
| [ARCHITECTURE](docs/ARCHITECTURE.md) | How capture, transcription, and the app fit together |
| [HANDOVER](docs/HANDOVER.md) | Current state, what is unproven, what to do next |
| [BENCHMARKS](docs/BENCHMARKS.md) | Results, and how much to trust each number |
| [TROUBLESHOOTING](docs/TROUBLESHOOTING.md) | Symptoms and their real causes |
| [CONTRIBUTING](CONTRIBUTING.md) | How to contribute |
| [CLAUDE.md](CLAUDE.md) | Working rules for AI agents in this repo |

## Acknowledgements

- [ivrit-ai](https://huggingface.co/ivrit-ai) — the Hebrew models this depends on
- [whisper.cpp](https://github.com/ggerganov/whisper.cpp) — on-device inference
- Macháček, Dabre & Bojar, *Turning Whisper into Real-Time Transcription System*
  (2023) — the confirmed/unconfirmed streaming discipline

## License

[MIT](LICENSE).
