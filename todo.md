# Scribebot improvement roadmap

Based on the read-only project review of 2026-09-05. Work proceeds in the order
below. Checkboxes represent implemented and automated-tested work; app-driven
acceptance is tracked separately and must not be inferred from self-checks.

## 1. Capture isolation, process ownership, and durable recovery

Capture isolation and persistent recovery are implemented and under automated
verification. Hardware/app acceptance and true full-disk testing remain open.

- [x] Prevent a slow or failed live decoder from blocking saved system/mic audio.
      Bound preview buffering; stop preview visibly on overload rather than
      silently concatenating audio across skipped time.
- [x] Own system and microphone preview processes separately; separate their
      partial-line buffers, source labels, and provisional text.
- [x] Report preview/microphone startup failures and roll back failed capture starts.
- [x] Drain capture output and wait for microphone WAV finalization before batch
      transcription. Serialize sink writes and close; reject overlapping starts.
- [x] Report unexpected helper exits and disk/write failures during recording.
- [x] Persist a recording manifest at start and checkpoint recording progress.
- [x] Persist recording/awaiting-transcription/complete/partial/failed states.
- [x] Detect interrupted jobs on launch and provide recovery from saved audio;
      repair only validated files through a deliberate recovery operation.
- [x] Preserve previous transcripts until replacements are durably saved; expose
      partial results when only one source succeeds.
- [x] Surface storage failures and check free space. Do not swallow persistence errors.
- [x] Add behavioral tests for stalled decoders, closed pipes, independent source
      framing, shutdown, missing preview scripts, and failed startup.
- [x] Test interrupted finalization, failed source decoding, rejected output paths,
      low-space preflight, unexpected helper exits, and inherited capture locks.
- [ ] Exercise actual ENOSPC during capture and atomic transcript replacement on
      an isolated full test volume; preflight tests do not cover actual disk exhaustion.
- [ ] Acceptance: make a recording from the app using an isolated test library;
      verify both WAV files and the complete final transcript without rebuild.

## 2. One chronological, timestamped transcript

Finalization currently stores all of Them followed by all of You, losing
conversation order. Export separately re-decodes one track and can omit the mic.

- [ ] Persist segments with stable IDs, source, start/end times, speaker,
      raw recognition, corrected text, and version/provenance.
- [ ] Align both tracks to capture time, including initial silence, gaps and
      overlapping speech; merge into chronological turns without losing overlaps.
- [ ] Generate UI text, summaries, search, and exports from this canonical record.
- [ ] Export both tracks, speaker labels, and user corrections without new ASR.
- [ ] Move export preparation off the main actor and disclose estimated timing.
- [ ] Forward --lang in the segments CLI and surface failed segment decodes.
- [ ] Distinguish audio source from person identity. Evaluate remote-track
      diarization after alignment; allow manual speaker names.
- [ ] Do not map invitee order onto voice order merely because counts match.
- [ ] Test two-track export completeness, timestamps, overlaps, and corrections.

Speaker separation increment (2026-09-06):
- [x] Add local remote-track speaker clustering without a fixed two-speaker limit.
- [x] Add automatic analysis after successful finalization and an explicit
      Separate speakers / Analyze again action for older calls.
- [x] Add a remote-speaker count override (excluding the local microphone),
      uncertainty labels, chronological estimated timestamps, and manual names.
- [x] Persist speaker segments, raw text, names, analysis revision and engine
      in the recording manifest; render the text projection for summary/search.
- [x] Preserve previous results when analysis fails; invalidate the speaker view
      when an external transcript rewrite no longer matches its text projection.
- [x] Keep ASR JSON sidecars in temporary directories, forward segment language,
      and surface failed segment decoding.
- [ ] Live speaker diarization, cross-meeting voice profiles, manual reassignment
      of individual turns, precise cross-track synchronization, and export wiring.
- [ ] Validate on longer calls with more participants; automatic cluster counts
      and overlapping speech remain estimates, not a speaker-accuracy guarantee.
- Local runtime: existing .venv with sherpa-onnx 1.13.7 and NumPy; pyannote 3.0
  segmentation and WeSpeaker resnet34 ONNX models under models/diar. No downloads
  or cloud audio transfers were needed. Distribution packaging/model setup remains
  open; missing dependencies surface a warning and retain the ordinary transcript.

## 3. Evidence-backed summaries and reliable jobs

Current 1,500-word chunks become only 2–3 sentences before final synthesis,
discarding detail. Cache freshness ignores model and instruction changes.

- [ ] Extract structured decisions, proposals, tasks, owners, deadlines,
      unresolved questions, and source segment IDs before prose generation.
- [ ] Reconcile duplicate facts and later corrections in chronological order.
- [ ] Separate explicitly stated facts from inference; leave unstated fields empty.
- [ ] Validate output schemas; keep evidence for each decision/action item.
- [ ] Budget context by selected model and token allowance, reserving output space.
- [ ] Supply meeting date/timezone for relative deadlines without inventing dates.
- [ ] Audit factual support, names, technical terms, numbers, negations and owners;
      expose uncertain claims and make evidence navigable.
- [ ] Cache by transcript version, model/provider, template contents, writing
      instructions, and prompt version; save generation provenance.
- [ ] Give jobs unique identities; prevent cancelled work from updating newer jobs.
- [ ] Cancel provider subprocesses as well as wrappers; use coherent timeouts and
      resumable progress for long multi-chunk summaries.
- [ ] Preserve legitimate CJK/multilingual text; flag or retry unexpected script
      instead of unconditional character deletion.
- [ ] Surface successful-generation terminology warnings instead of discarding stderr.
- [ ] Correct provider-dependent privacy copy beside Generate and throughout UI/docs.
- [ ] Isolate CLI provider execution and disable unnecessary tools; treat transcript
      content as data, not instructions. Test provider failures and cancellation.

## 4. Recognition quality and performance

- [ ] Add speech activity detection with boundary padding and original timestamps;
      evaluate quiet Hebrew, short acknowledgments, background noise and English terms.
- [ ] Trim silent streaming buffers before returning from the silence guard.
- [ ] Show separate microphone/system meters, selected input, and actionable device
      warnings. Distinguish silence from capture failures.
- [ ] Test device changes, Bluetooth and speaker bleed; keep echo cancellation
      conservative until both tracks are measured (prior AEC reduced tap levels).
- [ ] Add per-recording Auto/Hebrew/other-language controls and persist the choice.
- [ ] Make preview and final model selection understandable and consistent.
- [ ] Evaluate persistent model workers against repeated whisper-cli launches,
      measuring memory, responsiveness, latency and battery/CPU load.
- [ ] Compare model candidates on identical real meetings: Hebrew WER, English
      terms, names, numbers, negations, completeness, and end-to-end latency.
- [ ] Add personal/project vocabulary editing and explicit remember-correction flow.
- [ ] Preserve raw recognition and reversible glossary edits; treat names separately.
- [ ] Retain conservative matching and expand false-replacement negative controls.

## 5. Daily use, calendar, backup, and release quality

- [ ] Unify primary and legacy detail views so search/export capabilities are reachable.
- [ ] Add audio playback, sentence seeking, edit/undo, in-recording search, and
      targeted retry of failed transcription.
- [ ] Consolidate EventKit titles and the static imported People index; persist
      meeting association and distinguish invitations from confirmed speakers.
- [ ] Add backup/restore workflow preserving metadata, audio, transcript and summaries.
- [ ] Maintain validated Trash-based deletion; include new artifacts in file ownership.
- [ ] Evaluate library search responsiveness as libraries grow; avoid UI-thread I/O.
- [ ] Keep runtime dependencies/binary paths consistent between development and
      release; verify signed bundles under Finder-style environments.
- [ ] Review release signing/distribution, compatibility and first-run permission flow.
- [ ] Keep architecture and privacy documentation aligned with actual provider behavior.

## Quality gates across every phase

- [ ] Build a consented real-meeting reference set: Hebrew/English switching,
      quiet speech, overlap, Bluetooth, speaker playback, long silence and interruptions.
- [ ] Measure summary factuality and recording completeness alongside recognition.
- [ ] Fix empty-reference WER reporting: invented speech currently scores zero;
      add a silence-hallucination metric and corpus-weighted WER alongside clip mean.
- [ ] Add app-driven lifecycle regression tests, not only source-pattern assertions.
- [ ] Run ./check and relevant Swift tests/builds for implementation changes.
- [ ] Require app-made audio and complete final .txt for capture acceptance.
- [ ] Label synthetic measurements; do not reuse historical benchmark numbers as
      current accuracy claims. Existing diarization benchmarks are synthetic.

## Baseline and references

Review: eight selected self-checks passed; glossary negative controls 45/45 using
1,243 terms. Isolated probes confirmed silent-buffer growth, ignored segments
language, CJK deletion, and empty-reference WER. No live accuracy benchmark or
app-driven capture was performed during the review.

- https://github.com/ggml-org/whisper.cpp (VAD, C API, persistent server example)
- https://docs.ollama.com/capabilities/structured-outputs (schema-constrained output)
- Repository CLAUDE.md governs recording safety and verification.

## Implementation log

- 2026-09-05: Roadmap recorded. First increment implemented: nonblocking preview
  inputs bounded to eight seconds, visible preview pause on overflow, independent
  source process/framing/provisional state, continuous pipe draining, asynchronous
  orderly capture shutdown, failed-start cleanup, and unique recording filenames.
  Short recordings are retained rather than automatically deleted.
- Validation: ./check passed with the new capture transport harness. It runs the
  production Swift Recorder against synthetic helpers and a temporary library,
  verifies complete system/mic audio despite stalled preview, and delays mic
  header finalization to exercise shutdown ordering. This is not a real speech
  benchmark or a hardware/app-UI acceptance recording.
- Full Swift app compilation passed. Existing actor-isolation warnings in Store
  and summary code remain; this increment adds no new compiler warnings.
- App acceptance remains pending: the current installed Scribebot window reports
  "System audio not granted" and disables New recording. No permission settings
  were changed, no real recordings were modified, and the running installed app
  was not replaced. The compile output is /tmp/Scribebot-capture-review.
- Next increment: durable start manifests, persistent job states and recovery,
  surfaced write failures, and safe retry of incomplete finalization.
- 2026-09-06: Second increment implemented. Manifests are written before capture
  starts and checkpointed every five seconds. Persistent job state exposes retry
  after interruption. Capture helpers inherit a library lock and stop when the
  owning app exits. Unexpected exits and storage errors are surfaced.
- Retry validates saved PCM16/mono/16 kHz WAVs and decodes temporary repaired
  copies. Failed source decoding keeps the previous transcript and writes any
  successful source to .partial.txt. Replacement text is staged and synchronized
  before atomic rename; completion metadata follows it. This is not a transaction
  across both files or a guarantee against power loss.
- Synthetic tests verify original WAV bytes remain unchanged during retry,
  legacy metadata still loads, and a child retains the library lock until exit.
  A regression found during testing now preserves the specific helper-exit
  failure instead of replacing it with a generic shutdown warning.
- Validation: ./check passed in full, including capture transport, audio recovery,
  model download, and Finder-environment transcription checks. Full Swift app
  and capture-helper builds passed; existing summary actor-isolation warnings
  remain. Review binaries are /tmp/Scribebot-recovery-review and
  /tmp/ScribebotCapture-recovery-review.
- Remaining acceptance: actual full-disk failures, device/permission behavior,
  app-owner crash with real capture hardware, and an app-made complete transcript.
  The installed app has not been replaced. Decoder descendant cancellation is
  also still open; the current timeout terminates its direct Python process.
- Next implementation stage: phase 2, chronological timestamped transcripts.
- 2026-09-06: Zoom acceptance exposed a Bluetooth system-audio rate mismatch.
  In a 135-second app recording the system signal occupied only about 45 seconds.
  A temporary copy expanded by three yielded recognizable remote Hebrew speech;
  original recording files were unchanged. Capture now labels IOProc frames with
  the aggregate device rate instead of the tap's advertised rate, logs both rates,
  and exits visibly if that device rate changes. Synthetic conversion checks cover
  duration and pitch at 16, 24, 44.1, and 48 kHz. A new Zoom recording is still
  required to confirm the hardware fix.
- 2026-09-06: The next app-made Zoom recording verified the Bluetooth rate fix:
  104.83 s system audio and 104.60 s microphone audio, nonzero system samples
  through 104.62 s, complete status, and Hebrew text from both sources without
  rebuild. This verifies this recording, not every device or a verbatim accuracy score.
- Speaker analysis of read-only copies of that recording produced two remote
  voice labels plus You, with uncertain spans retained. The original experimental
  embedding/settings over-clustered the call; the integrated WeSpeaker model uses
  the standard 0.5 cluster threshold and leaves clusters with less than two seconds
  of evidence unassigned. This is a small real-call check, not a validated DER benchmark.
- Speaker checks cover eight synthetic identities, overlap/uncertainty, raw-text
  preservation, language forwarding, temporary sidecars, decoder errors and persisted
  results after a failed retry. Full ./check passed.
