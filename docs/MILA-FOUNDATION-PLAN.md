# ScribeBot on Mila: implementation plan

Date: 2026-09-05. Decision: use Mila as the application foundation.
Scope: transcription accuracy, live speed/reliability, speaker identification,
the ScribeBot interface, and compatibility with existing recordings.

This supersedes the port-components-into-ScribeBot approach in
`MILA-COMPARISON.md`. That report remains useful as technical evidence.
This document plans implementation; it does not report a completed migration.

## Product and architecture decisions

- Fork Mila and retain its working SwiftUI application, transcription package,
  job orchestration, model management and speaker pipeline initially. Reshape
  its screens progressively; do not first extract an entirely new backend.
- Bring across ScribeBot's glossary, summary templates, Hebrew/English layout,
  recording workflows and visual direction. Adapt views to Mila's state model
  rather than transplanting ScribeBot's `Store` and `Recorder` wholesale.
- Preserve microphone and system audio as independent original tracks. Mila's
  current meeting mode mixes them into a single mono file, so this requires
  deliberate backend work even though Mila is the foundation.
- Keep ASR local by default. Expose existing optional remote/summary providers
  with explicit user configuration. Do not copy authentication secrets or
  activate cloud providers automatically during import.
- Keep the existing ScribeBot usable throughout development. Switch daily use
  only after the new application passes the release gates below.
- All three requested improvement areas belong in the first replacement
  release. Advanced acceleration tuning can follow once the baseline works.

Target shape:

```text
ScribeBot SwiftUI screens
    -> Mila session / transcription / summary services
        -> independent mic + system source tracks
        -> persistent Whisper + speech detection
        -> per-track speaker attribution / recognition
        -> raw transcript + glossary display text + user edits
        -> summaries / search / exports
    -> versioned recording store in a separate application-data root
        <- copy-based legacy ScribeBot importer
```

## Confirmed starting constraints

- Reviewed source bases: Mila `ada9cbb`, ScribeBot `37c2e54`. Recheck HEAD and
  working changes at implementation start. Both checkouts have local changes;
  preserve them and record which changes are included in the new fork.
- Mila uses XcodeGen and Xcode; ScribeBot currently uses `swiftc` plus Python
  helpers. Full Xcode is selected on this machine; `xcodegen` was not found on
  the current PATH. This review did not build Mila or install dependencies.
- Hardware capability queries were blocked in this tool environment. Measure
  RAM, actual device support and live throughput during the baseline phase;
  do not assume this Mac can run full Whisper and diarization concurrently.
- Mila's app entry point contains substantial service wiring. Preserve that
  ordering during the interface work and avoid broad file/class renaming.
- Mila includes upstream update configuration and automatic storage behaviors.
  Identity/storage isolation must precede ordinary app launch or real import.

## Phase 1 — Isolated foundation and runnable baseline

Complexity: medium. Depends on: nothing.

1. Create a separate Git checkout, proposed location
   `/Users/gavriel/projects/scribebot-next`, on `codex/mila-foundation`.
   Preserve Mila history and record the exact source revision. Keep the
   existing `mila` and `scribebot` checkouts intact. The location is planned,
   not created by this document.
2. Keep Mila as an upstream source remote. Preserve its license, NOTICE and
   third-party notices and include attribution for carried-over ScribeBot code.
   Do not retain upstream release publishing destinations for the new app.
3. Resolve build prerequisites, package dependencies and diarization runtime
   requirements. Build the source baseline before broad changes. An app build
   without the Python embedding runtime is not a speaker-feature pass.
4. Before launching against ordinary user storage, define an isolated app
   identity, proposed `dev.scribebot.next`, with display name `ScribeBot Next`
   and data root `~/Library/Application Support/ScribebotNext`.
5. Centralize that identity across storage, defaults, Keychain, voice profiles,
   model/runtime caches, URL/file handlers and MCP access. Add an injectable
   temporary root for tests. Disable upstream Sparkle checks and legacy-root
   migration; remove inherited upstream branding and publishing credentials.
6. Run baseline recordings only with disposable storage until isolation is
   verified. Record which baseline tests pass, fail or need unavailable models.
   Hosted app tests also execute app startup: inspect their bootstrap before
   running them. Use injected recording roots, isolated defaults and temporary
   model/profile locations, not just temporary audio filenames.

Main files: Mila `project.yml`, `Makefile`, `Mila/App/MilaApp.swift`,
`Mila/Models/RecordingStore.swift`, storage/settings classes, and package data
readers. Keep internal target/module names initially if renaming adds risk.

Exit gate: reproducible debug build; isolated launch cannot move existing
Mila/legacy/ScribeBot files, share credentials, or contact the upstream updater.
Microphone and system capture each produce playable audio in the test library.

## Phase 2 — Original-audio policy, track schema and job correctness

Complexity: high. Depends on: Phase 1.

1. Add a backward-compatible recording schema with a schema version and a
   track manifest: track ID, relative filename, source, sample format, start
   offset and duration. Existing Mila single-file records remain readable.
2. Extend `RecordingSession` to persist mic and system source streams before
   mixing. A mixed playback/analysis file may be generated as a derivative.
   Keep both streams on an explicit shared timeline and record discontinuities.
3. Audit every consumer of `audioFileName`: playback, transcription, recovery,
   export, compression, trash, permanent deletion, storage relocation and MCP.
   No feature may orphan or accidentally delete the second track.
4. Disable automatic removal of original WAVs after compression and automatic
   disposal of short/empty recordings. Recovery repairs a derived copy only.
   User-requested deletion applies solely to the new app's owned library;
   imported source files are never deletion targets.
5. Integrate final full-recording transcription as a tracked job. Distinguish
   capturing, finalizing, completed, failed and cancelled states. A preview
   must not silently become a completed final transcript after a failure.
6. Separate ASR revisions from user edits/suppressed segments. Mila currently
   protects edits by treating some live output as authoritative; adding a
   final pass must not restore text the user deliberately removed.
7. Keep bounded live work, per-session IDs, cancellation and late-result
   rejection. Persist final results before reporting success; make restart
   recovery retryable without duplicating jobs or transcripts.

Main files: `Mila/Audio/RecordingSession.swift`, `Mila/Models/Recording.swift`,
`RecordingStore.swift`, `Mila/Audio/LiveTranscriber.swift`,
`Mila/Transcription/TranscriptionService.swift`, and action coordinators.

Exit gate: independent tracks survive pause/resume, one silent source, a device
failure, stop/start and app interruption. Original audio hashes remain intact
through compression/recovery tests. The final transcript retains the last
spoken phrase and preserves deliberate user edits.

## Phase 3 — ScribeBot interface and workflow parity

Complexity: medium to high. Depends on: Phase 1; track UI depends on Phase 2.

Adapt Mila's views in this order:

1. Library shell, sidebar, search and recording rows.
2. Recording detail with playback, transcript, source/speaker labels and summary.
3. Live recording panel with clear provisional/final text and processing state.
4. Meetings and People views, separating calendar attendees from recognized
   speakers. Calendar membership must never be treated as voice identification.
5. Settings and onboarding for models, microphone/system permissions, language,
   summaries, speakers and storage.

Use ScribeBot's existing visual direction: white/soft-gray surfaces, charcoal
controls and the shared pale-blue sidebar/detail-header token (`#F5F8FC`).
Preserve native typography, keyboard operation, dark mode and mixed Hebrew/
English directionality. Verify the actual screens, not just Swift compilation.

Sources to adapt from ScribeBot: `app/Sources/Theme.swift`, `RTL.swift`,
`MainWindow.swift`, `RecordingDetail.swift`, `TranscriptView.swift`,
`Meetings.swift`, `PeopleView.swift`, and summary/template views.
Mila targets: `Mila/Views/ContentView.swift`, `SidebarView.swift`,
`HistoryListView.swift`, `RecordingDetailView.swift`, and settings views.

Exit gate: the user can record, browse, search, play, rename, read, summarize and
export from the new ScribeBot interface without exposing internal diagnostics
as ordinary product controls. Hebrew/English selections and copied text work.

## Phase 4 — Accuracy and live performance

Complexity: high. Depends on: Phase 2; controls integrate with Phase 3.

1. Reuse Mila's persistent engine, utterance detector and optional Silero gate.
   Verify the enabled path and error behavior; presence of source code does
   not mean the app actually uses that path on this hardware.
2. Carry across the exact-match glossary and aliases. Prefer a native Swift
   module for the final app, with equivalence fixtures against the existing
   Python implementation. Preserve raw ASR separately and apply restoration
   consistently to display, search, summary inputs and exports.
3. Preserve all 45 existing negative-control sentences and add behavior cases
   for Unicode, punctuation and alias boundaries. Do not add fuzzy matching.
4. Benchmark turbo and full ivrit.ai large-v3 with identical audio/settings.
   Offer a fast profile and a quality profile; turbo preview plus full-model
   finalization is a candidate configuration, not a predetermined winner.
5. Preserve multilingual selection and automatic language behavior. Include
   Hebrew mixed with English technical terms and non-Hebrew controls.
6. Measure first-text latency, stable-text latency, finalization duration,
   peak memory and queued-audio growth. Avoid concurrent model loads that push
   the machine into sustained memory pressure.
7. Keep speech-detector failures visible and allow ASR to proceed on detector
   errors. Verify quiet voices, noise-only clips, clipped words at boundaries,
   long monologues and final short utterances.

Exit gate: no material accuracy regression against the old app on the agreed
held-out corpus; glossary negative controls remain unchanged; live processing
keeps pace over an agreed representative long recording without growing backlog.
Record actual numbers before selecting defaults or advertising an improvement.
Core ML context tuning and aggressive gain changes are separate later trials.

## Phase 5 — Multiple speakers and returning-speaker recognition

Complexity: high. Depends on: Phases 2 and 4.

1. Package and verify Mila's embedding/diarization runtime on the target Mac.
   Exercise model/runtime setup from a clean app launch, including failures.
   Start with Apple Silicon support, matching the existing ScribeBot build.
   Mila's bundled Python/bootstrap downloads are ARM64-specific; a universal
   Swift app binary alone does not establish Intel diarization support.
2. Attribute speakers within each source track, then merge by absolute time.
   Keep source identity separate from inferred person identity. Check speaker
   bleed between tracks and simultaneous speech explicitly.
3. Use stable per-recording labels, manual rename, unknown/uncertain outcomes,
   and correction controls. Do not force a short ambiguous utterance to a
   named person simply because a nearest embedding exists.
4. Make returning-speaker profiles an explicit configurable feature with
   correction/deletion. Version embeddings by model so incompatible vectors
   cannot be silently combined. Keep enrollment separate from evaluation audio.
5. Evaluate real multi-party meetings with annotated speaker turns, including
   short turns and overlap. Measure diarization error, speaker fragmentation
   and incorrect known-person matches; do not reuse synthetic figures as proof.
6. If simultaneous live transcription and diarization cannot keep pace, defer
   speaker processing to finalization and show the actual available mode.

Main files: `Mila/Transcription/LiveSpeakerDiarizer.swift`,
`SpeakerDiarizer.swift`, `Mila/Models/SpeakerProfileStore.swift`,
`RecognisedSpeakerAssigner.swift`, and speaker presentation views.

Exit gate: real annotated examples demonstrate useful multi-speaker labels;
manual correction survives regeneration/relaunch. Recognized names are not
inferred from calendar lists, and uncertainty is represented honestly.

## Phase 6 — Summaries, exports and existing-library import

Complexity: high. Import depends on Phase 2 schema; UI on Phase 3.
Summary/export work can begin once those interfaces are stable.

Summary/export parity:

- Map ScribeBot templates and per-template saved summaries onto Mila's summary
  orchestration. Retain local Ollama and intended Claude/Codex workflows;
  verify actual provider support rather than assuming equal tool names.
- Preserve language behavior, technical terms, long-transcript chunking,
  cancellation and visible errors. Never overwrite a different template's
  summary or import old output as newly generated output.
- Preserve exports and real timestamps. Existing plain-text transcripts may
  have no timing; mark timing unavailable and retain readable text instead of
  inventing precise segment times. New decoding creates a separate revision.

Importer design:

1. Read a selected legacy source library without modifying it. ScribeBot uses
   per-recording `<id>.json`, `.txt`, `<id>.wav`, `<id>-you.wav` and
   `<id>.summary[.<template>].md` files, not Mila's aggregate metadata format.
2. Produce a dry-run inventory: records, both tracks, missing files, summaries,
   invalid paths, duplicates and estimated destination disk use. Read calendar/
   meeting metadata separately if available; it is not embedded in each record.
3. Copy files to staging in the new library, verify sizes/hashes and commit
   metadata only after the required files are durable. Do not use hard links
   or symlinks back to original audio. Reject escaping paths and unsafe links.
4. Persist source provenance, an old-ID to new-ID map and an import journal.
   Re-running the import is idempotent; an interrupted run resumes cleanly.
   If the source changes during copying, retry/report it rather than silently
   committing an inconsistent snapshot.
5. Preserve titles, dates, durations, both tracks, text and every summary.
   Missing audio may still yield a useful transcript-only record. Import must
   not automatically trigger transcription, summaries or cloud requests.
6. Use generated fixtures and copied test libraries first. Validate a selected
   real-library import before making it the everyday library. Rollback affects
   only newly created destination records and files.

Exit gate: count/hash audit demonstrates lossless import of present artifacts;
restart and repeated import do not duplicate records. Old ScribeBot still reads
the original library, and deleting an imported copy cannot affect that library.

## Phase 7 — Release candidate and switch of daily use

Complexity: medium. Depends on: all prior exit gates.

1. Build a distributable ScribeBot app with its own identity, icons, permissions,
   third-party notices and verified runtime/model setup. Keep upstream update
   delivery disabled until ScribeBot has its own intentional release channel.
2. Run package tests and app tests from Mila, adapted ScribeBot glossary/export/
   language tests, import/recovery tests and lifecycle integration tests.
   The old `./check` remains a legacy regression gate; it does not validate the
   new Swift pipeline by itself. Replace source-string assertions with behavior
   tests where the architecture changes instead of mechanically porting them.
3. Test the installed build from Finder with a minimal PATH. Verify permission
   refusal, missing model/runtime, download interruption, disk-full behavior,
   cancellation and finalization failure all produce actionable app states.
4. Drive actual app recordings: mic only, system only, meeting, quiet speech,
   Hebrew/English switching, multiple speakers, pause/resume and a long meeting.
   Confirm playback and complete on-disk final transcripts without repair runs.
5. Review the new UI and benchmark report. Switch the daily app only after
   these gates pass. Keep the old app/library as a rollback path; export any
   new-only recordings before a rollback so work is not stranded.

Exit gate: an installed release candidate satisfies recording, accuracy,
live responsiveness, speaker, import and UI acceptance. A successful build or
unit-test run alone is insufficient.

## Work sequence and completion tracking

| Milestone | Result | Status |
|---|---|---|
| A: Foundation | Isolated runnable Mila-derived ScribeBot | Planned |
| B: Recording core | Independent tracks, immutable originals, correct finalization | Planned |
| C: Product shell | ScribeBot interface and workflow parity | Planned |
| D: Intelligence | Validated ASR/live settings and speaker features | Planned |
| E: Compatibility | Summary/export parity and verified legacy importer | Planned |
| F: Replacement release | Installed app validated; daily-use switch ready | Planned |

Start with A, then B. UI work and summary parity can progress once their model
interfaces are stable. Accuracy and speakers require the track/timeline work;
full import requires the final schema. This is a substantial migration, with
capture/persistence and speaker validation likely the most demanding work.
Set calendar estimates after the baseline build and runtime measurements.

No additional product choice is needed to begin implementation. Real-meeting
benchmarking may require selecting recordings and establishing ground-truth
transcripts/speaker labels with the user; existing benchmark notes do not prove
that a suitable held-out corpus is available. Public release credentials and
distribution destinations are only needed at the release stage.

## Mila integration points requiring special attention

- `Mila/Models/RecordingStore.swift`: legacy-root moves, original-file
  compression/deletion, single-file metadata and injectable test root.
- `Mila/Actions/QuickActionsController.swift`: finalization policy, live-edit
  preservation and automatic compression trigger.
- `Mila/App/MilaApp.swift`: updater startup, recovery and lifecycle wiring.
- `Mila/Models/KeychainHelper.swift`: fixed credential-service namespace.
- `Mila/Models/SpeakerProfileStore.swift`: profile storage root.
- `Mila/Transcription/DiarizationBootstrap.swift`: writable runtime root and
  architecture-specific dependencies.
- `Packages/MilaKit/Sources/MilaKit/StoreLocationPointer.swift`: MCP storage
  discovery, which must point only at the new app's intended library.

Planning validation: source inspection and a separate planning review were
completed. No Mila build, migration, launch, model download or benchmark was
performed in this planning task.
