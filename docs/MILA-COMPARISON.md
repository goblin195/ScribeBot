# Mila comparison and adoption plan

Decision update: the user selected Mila as the foundation for the replacement
ScribeBot application. See [MILA-FOUNDATION-PLAN.md](MILA-FOUNDATION-PLAN.md) for
the implementation sequence; the component-porting sequence below is historical.

Reviewed 2026-09-05. Local source snapshots: ScribeBot `37c2e54`, Mila
`ada9cbb` at `/Users/gavriel/projects/mila`. This is a source review, not a
measured comparison of the running applications. No model or runtime behavior
was changed during this review.

The strongest candidates are a persistent transcription engine, speech-aware
decoding, an optional full-size Hebrew model, and multi-speaker attribution.
Adopt them independently so any improvement or regression has a clear cause.

| Candidate | What the code shows | Recommendation |
|---|---|---|
| Persistent Whisper engine | Mila retains a Whisper context in `WhisperEngine.loadIfNeeded`; ScribeBot `stream.decode` launches `whisper-cli` on every decode. | High priority. Prototype a supervised local worker that loads once per selected model. Measure warm decode latency and memory before replacing the existing backend. |
| Speech-aware chunking | Mila has an RMS utterance detector with pre-roll, onset hysteresis, silence boundaries and a maximum utterance length. ScribeBot uses timed rolling windows and a sampled peak gate. | High priority experiment. Preserve absolute timestamps, final batch transcription and the original audio. Test phrase boundaries and quiet speech. |
| Neural speech detection | Mila's optional Silero gate checks utterances before Whisper and allows decoding to continue if the detector fails. | Evaluate with noise-only and quiet-speech recordings. Record detector errors; a failure must not silently suppress speech. |
| Full Hebrew model | Mila selects ivrit.ai full `large-v3` (roughly 3 GB); ScribeBot selects ivrit.ai `large-v3-turbo` (roughly 1.6 GB). | Add only as an optional quality profile after an A/B comparison. Larger does not establish better accuracy on our meetings. Keep turbo available for live decoding. |
| Core ML encoder | Mila loads a matching encoder when present and tracks actual initialization status. ScribeBot currently invokes its installed CLI. | Later performance experiment. Measure the actual build/backend on the target Mac, including cold initialization. No assumed speedup. |
| Quiet-speech handling | Mila has adaptive capture gain and separate bounded peak normalization before decoding. | Test on an inference copy of audio first. Noise amplification and interaction with speech thresholds can offset the benefit. |
| Multiple speakers | Mila combines pyannote segmentation/WeSpeaker embeddings, online cosine matching and persistent speaker profiles. | Useful new capability for several remote participants or people sharing a mic. Keep microphone/system track identity as a separate attribute. |
| Job lifecycle | Mila uses per-session epochs and chained live tasks, plus per-recording cancellation in post-processing. | Apply these patterns when introducing a worker/queue. Test stop, restart and late completions explicitly. |
| Interrupted recording recovery | Mila detects unfinished WAV headers and orphaned recordings. | Adopt the recovery concept using a derived copy and resumable transcription jobs. Its in-place WAV repair conflicts with ScribeBot's rule protecting original recordings. |
| Remote transcription | Mila has an engine abstraction and endpoint/model capability handling. ScribeBot's provider abstraction currently serves summaries. | Optional later backend. Do not enable uploads as part of a local transcription upgrade. Timestamp support must be explicit. |
| Model downloads | Both implementations verify SHA-256. ScribeBot already has resumable partial downloads and size checks. | Preserve the existing downloader; this is not a missing Mila advantage. |
| Summaries | Mila has richer orchestration and integrations; ScribeBot already supports Ollama/Claude/Codex and overlapping chunk summaries. | Borrow lifecycle ideas where needed. No evidence here that replacing the summary model or prompt improves summary quality. |

## Evidence and boundaries

### Model selection and runtime

Mila sources:

- `Mila/Transcription/ModelManager.swift`: model catalog and checksums.
- `Packages/TranscriptionCore/Sources/TranscriptionCore/WhisperEngine.swift`:
  retained context, warmup, normalization, decoding parameters and Core ML status.
- `Packages/TranscriptionCore/Package.swift`: pinned Whisper binary dependency.

ScribeBot integration points: `languages.py`, `app/Sources/ModelSetup.swift`,
`stream.py`, `live.py`, `toolpaths.py`, and the batch path in `scribebot.py`.

The full ivrit.ai GGML model is compatible with whisper.cpp according to its
[upstream model card](https://huggingface.co/ivrit-ai/whisper-large-v3-ggml).
This establishes compatibility, not an accuracy advantage over turbo.
[Upstream whisper.cpp](https://github.com/ggml-org/whisper.cpp) supports Metal,
Core ML and VAD; whether a particular installed binary enables them must be
verified locally.

Mila's `audio_ctx=750` optimization applies only to short audio and is disabled
for its Core ML path. The source contains a small fixture sweep reporting a
speedup, but that result was not reproduced here and the inspected table does
not establish fixture provenance. Do not apply it to full recordings or quote
it as a ScribeBot performance result.

A first worker can remain outside the SwiftUI process to preserve crash
isolation. It should have request IDs, absolute audio offsets, a model identity,
bounded work queues, deadlines, cancellation, and explicit errors. Keep the
existing CLI backend available during evaluation. Preserve the live output
protocol: committed text versus the provisional `~` tail.

### Speech detection

Mila sources: `Mila/Audio/UtteranceDetector.swift`,
`Mila/Audio/LiveTranscriber.swift`, `Mila/Audio/AdaptiveGainController.swift`,
and `Packages/TranscriptionCore/Sources/TranscriptionCore/SileroVAD.swift`.
The neural gate is optional, and the fixed-timer path does not consult it.
Its benefits should not be attributed to every Mila recording mode.

[Silero's upstream project](https://github.com/snakers4/silero-vad) provides
speech detection. Our integration still needs evidence on Hebrew, quiet
voices, keyboard sounds, fans, music and mixed speech/noise.

Silence boundaries do not guarantee a single speaker: uninterrupted turn
changes and overlapping speech can occupy one utterance. Do not inherit the
Mila comment claiming utterances contain one speaker by construction.

### Speaker recognition

Mila sources: `Mila/Transcription/SpeakerDiarizer.swift`,
`Mila/Transcription/LiveSpeakerDiarizer.swift`,
`Mila/Models/SpeakerProfileStore.swift`, and
`Mila/Models/RecognisedSpeakerAssigner.swift`.

Online assignment updates a centroid on a confident match, attaches borderline
matches without updating it, and restricts creating a speaker from short audio.
That can limit fragmentation but can also attach a short new-speaker utterance
to the wrong existing person. ScribeBot should support unknown/uncertain labels
and user corrections instead of implying every assignment is certain.

Mila's `docs/seed-anchor-sweep.md` explicitly says its seed-weight experiment
has not been run because the corpus is unavailable. Its recognition thresholds
are not independently validated by this review. ScribeBot's existing
`docs/BENCHMARKS.md` also labels its diarization figures as synthetic-only.
Neither project establishes a real-meeting winner.

Evaluate diarization within each captured track, then merge on the shared
recording timeline. Test cross-track microphone bleed before assuming the
track label uniquely identifies a human. Persistent voice profiles should be
an explicit user feature with correction and deletion controls.

### Reliability and existing strengths

Mila sources: `Mila/Actions/PostRecordingCoordinator.swift`,
`Mila/Actions/RecordingSummarizer.swift`, and `Mila/Audio/WAVHeaderRepair.swift`.
Recovery should recognize narrowly defined corruption and never reinterpret
healthy metadata as audio. ScribeBot must keep original recordings untouched.

Preserve ScribeBot's separate capture streams, final re-transcription after
recording, exact glossary aliases and negative controls, explicit subprocess
failure handling, Finder-compatible binary resolution and verified downloads.
Its architecture document's statement that nothing opens a socket is outdated:
`providers.py` contains Ollama HTTP calls and cloud-capable summary providers.
The transcription comparison here is about the local ASR path.

## Suggested implementation order and acceptance criteria

1. Establish an A/B harness using the existing scoring utilities. Compare raw
   ASR and ASR plus the same glossary separately. Use identical audio and
   decoding parameters when isolating model quality; include held-out real
   speech, technical English inside Hebrew and a non-Hebrew control set.
2. Prototype a persistent worker behind the existing transcription interface.
   Measure first-text latency, warm decode time, memory and backlog under a
   long stream. Exercise worker crash, timeout, cancellation and restart.
3. Evaluate utterance chunking and Silero independently, then together. Check
   false text during silence, lost quiet words, pause/resume timestamps,
   maximum-length monologues and the final incomplete utterance on stop.
4. Expose the full Hebrew model if it improves held-out accuracy enough to
   justify latency and memory. A useful candidate arrangement is turbo for
   preview and full large-v3 for final transcription; this remains unmeasured.
5. Integrate optional multi-speaker attribution after real annotated meetings
   are available. Measure speaker error, fragmentation and false identity
   matches, including short turns and overlap. Use separate enrollment audio.
6. Evaluate Core ML and adaptive gain as separate experiments. Preserve a
   known-working backend throughout rollout.

For runtime changes, run `./check`, including Finder-environment tests and
glossary negative controls. Then make a recording through the app and verify
that the final transcript on disk includes its ending without `rebuild`.
Self-checks alone do not prove that user flow works.

Before copying Mila implementation files, retain their applicable attribution
and notices; its checkout includes `LICENSE` and `NOTICE`. No Mila code or
model weights have been copied as part of this review.

## Review validation

The comparison covers selected backend and model paths, not every file or a
full security audit. No Mila build, model download, speed benchmark, WER run,
diarization evaluation or audio-hardware test was performed for this report.
The user confirmed that all three outcomes are in scope: accuracy, live
responsiveness/reliability, and identifying multiple speakers. The sequence
above is an implementation dependency order, not a decision to omit any area.

ScribeBot's `./check` passed after this documentation change, including all
45 glossary negative-control sentences, 12 app-wiring checks, model-download
checks and the Finder-environment transcription probe. That probe uses a
synthetic signal and is not an accuracy benchmark or an app-driven recording.
