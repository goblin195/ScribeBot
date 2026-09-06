# Recordings are user data

`~/Library/Application Support/Scribebot/recordings/` holds the user's own
meeting audio and transcripts. During development ten of them were destroyed by
automated cleanup that used a wildcard delete on the whole directory.

Rules for anything touching this project, human or agent:

- **Never** `rm` inside that directory with a wildcard. Delete a named file you
  created yourself, and nothing else.
- Test fixtures go in a temporary directory, never the real library. Point the
  app elsewhere with `CFFIXED_USER_HOME` if a clean library is needed.
- `SCRIBEBOT_DEMO=1` seeds fixtures in memory only and writes nothing.

There is no undo. The files are not in Trash and local snapshots were not
enabled.

## Interrupted recordings

New recordings have a JSON manifest before capture starts. The app checkpoints
duration and records recording, awaitingTranscription, transcribing, complete,
partial, or failed status. Older manifests without status remain readable.

Use **Retry transcription** in the recording detail to retry an interrupted or
failed job. Recovery reads the original audio and makes a temporary validated
PCM16 mono/16 kHz WAV copy; it never repairs headers in the saved original.
Unrecognized or ambiguous WAV layouts fail explicitly. A library lock prevents
retry while another app instance or an inherited capture helper owns the files.

If either source fails decoding, the previous `.txt` is kept and successful
source text is saved as `.partial.txt`, available through **Reveal partial
transcript**. Successful replacement text is synchronized before atomic rename,
then completion metadata is saved. An interruption between those writes leaves
the job retryable. A capture warning remains visible even if decoding succeeds;
retry cannot reconstruct speech that was never captured.

## Speaker labels

Successful new transcripts also attempt local speaker separation. The system
track can contain many remote voices; the microphone track remains labeled You.
Older calls can use Separate speakers in the detail view. Set Remote speakers to
the number of people on the other end of the call (zero means automatic).

Speaker segments and names are saved in the manifest; `.txt` is their readable
projection, used by summaries and search. Click a speaker name to rename that
voice within the recording. Reanalysis creates new clusters and resets names.
Short or overlapping spans may remain uncertain. Names are never derived from
calendar invitation order, and voices are not recognized across recordings.

The local development runtime uses `.venv/bin/python`, sherpa-onnx and the ONNX
models in `models/diar`. If unavailable, the ordinary transcript is kept and a
speaker-analysis warning is shown. Live preview continues to show source labels.
