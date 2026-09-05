# Troubleshooting

Symptoms, and what actually caused them. Every entry here was a real bug found
by using the app, not a hypothetical.

## "It transcribes the first two or three sentences, then stops"

The transcript on disk is the **live preview**, left in place because
finalization failed silently. The audio is almost always complete — check it
before suspecting the recording:

```sh
./scribebot.py file ~/Library/Application\ Support/Scribebot/recordings/<id>-you.wav
```

If that prints the full text, the audio was fine and only the write failed.
Repair every stored transcript with:

```sh
./scribebot.py rebuild
```

Two distinct causes produced this exact symptom, both from the same root:

**A Finder-launched app inherits none of your shell environment.** It gets
`PATH=/usr/bin:/bin:/usr/sbin:/sbin`.

1. `/usr/bin/env python3` found Apple's Python 3.9.6 rather than Homebrew's.
   The code uses `X | None`, which needs 3.10, so every finalization died on a
   `SyntaxError`. Fixed by resolving an interpreter that is actually ≥3.10
   (`Paths.python` in `Store.swift`).
2. `scribebot.py` then invoked a bare `whisper-cli`, which lives in
   `/opt/homebrew/bin` — not on that PATH. `FileNotFoundError`. Fixed by
   `toolpaths.py`, which resolves binaries absolutely.

Both were invisible because the exit status was ignored and an empty result was
treated as "nothing to write". `bench/env_isolation.py` now runs the pipeline
under that exact environment as part of `./check`.

**Diagnostic that settles it in one step** — compare mtimes:

```sh
cd ~/Library/Application\ Support/Scribebot/recordings
stat -f "%Sm %N" -t "%H:%M:%S" <id>.wav <id>.txt
```

If the `.txt` shares a second with the `.wav`, it was written at stop and
finalization never ran. Finalization takes about a second per file.

## "The other side is missing, and every line says You:"

One defect produces both halves of this. Compare the two files:

```sh
cd ~/Library/Application\ Support/Scribebot/recordings
afinfo <id>.wav | grep duration        # them
afinfo <id>-you.wav | grep duration    # you
```

They should match. If the tap file is much shorter, the CoreAudio tap stalled
during the call: a tap-bearing aggregate only runs IO while something is
playing, and the stream carries no timeline, so a stall used to erase its own
gap rather than record silence. Everything after the first stall then sat at
the wrong timestamp, attribution handed it to the local speaker, and the
surviving audio was spliced mid-word into something the decoder could not read
- it answers with repeated filler rather than words.

A real 72.5 s Zoom call came back as a 26.9 s tap file this way.

The gap is now padded with silence and the two files always agree, so
attribution survives a stall. The stall itself is still worth chasing - read
the log written beside the recording:

```sh
grep -E "stalled|clock source|preflight|WARNING" <id>.capture.log
```

`tap stalled 8.3s` marks each one. `clock source` names the device the
aggregate was clocked by; an output device that reconfigures mid-call - a
Bluetooth headset switching profile, or a virtual device belonging to another
conferencing app - is the leading suspect. Audio the tap never delivered is
not recoverable for that call; `rebuild` cannot invent it.

## "I can't hear myself in the recording"

Check the peak level of your side:

```sh
python3 - <<'PY'
import wave, array, sys
with wave.open(sys.argv[1]) as w:
    a = array.array('h'); a.frombytes(w.readframes(w.getnframes()))
print("peak", max(map(abs, a))/32768)
PY
```

A peak around `0.0024` is not silence — it is a **Bluetooth headset on the
hands-free profile**, running at 16 kHz. Switch the input to the built-in
microphone in System Settings > Sound. The capture helper prints the device name
and warns when the input rate is ≤16 kHz.

A peak of exactly `0.0000` on the *system audio* side is normal when nothing was
playing during the recording.

**Another app can hold the audio device.** If a competing recorder is running,
Scribebot's microphone reads near zero. Quit it.

## "Nothing shows up in the app's window"

The transcript cache used to be keyed only by recording ID, so a `.txt` repaired
on disk kept displaying the stale text. It is now invalidated by file
modification date. If you see this again, that invalidation has regressed.

## "The recording is completely silent"

WAV headers are written when the file is closed. If the helper is killed without
running its signal handlers, the header says zero frames and the file is
structurally empty even though the samples were written. `tap.swift` installs
`SIGTERM`/`SIGINT` handlers for this. A zero-length or header-only WAV means
they did not run.

## Capture hangs and never returns

`AudioDeviceCreateIOProcIDWithBlock` blocks forever inside `mach_msg` when
`kTCCServiceAudioCapture` has not been granted. There is no error and no
timeout. Grant Scribebot **Screen & System Audio Recording** in System Settings
— note this is a different permission from Microphone, and granting the
microphone does nothing for it.

Re-signing the capture bundle (`capture/build.sh`) can invalidate an existing
grant, so a hang immediately after a rebuild usually means re-approving it.

## The fix didn't work

Confirm the app you are running is the one you built. A running instance keeps
its old binary across a rebuild:

```sh
stat -f "binary %Sm" -t "%H:%M:%S" app/Scribebot.app/Contents/MacOS/Scribebot
ps -o lstart -p "$(pgrep -f Scribebot.app/Contents/MacOS/Scribebot | head -1)"
```

If the process started before the binary was written, quit and reopen the app.

## Terms come out transliterated

`SSE` appearing as `אס אס אי` means the term is not in `bench/aliases.json`.
Add the alias. Do not make the matcher fuzzier — that was tried, and it
corrupted 15.4% of real strings, rewriting `מטריקס` to `metrics` seventeen
times. After editing, run `./check`; `bench/negative_control.py` will fail if
the new alias damages ordinary Hebrew.
