# CLAUDE.md — working rules for this repository

Read this before touching anything. It records the things that have actually
gone wrong here, not general advice.

## Hard rules

**Treat `~/Library/Application Support/Scribebot/recordings` as untouchable.**
That directory is user data — real meeting audio that exists nowhere else. Ten
files were destroyed by a careless recursive delete during this project. There
is no backup. Never remove, move, truncate, or "clean up" that directory, and
never run a command whose glob could reach it. To repair a bad transcript, use
`./scribebot.py rebuild`, which rewrites `.txt` files and never touches audio.
See `RECORDINGS.md`.

**Run `./check` after every change.** It is fast and it has caught real
regressions. `./check --e2e` additionally exercises real audio hardware.

**Report honestly.** Several claims in this project's history were wrong and had
to be retracted — a benchmark run on text-to-speech audio that did not survive
real speech, and a claim about a competitor's model that was simply false. If a
number comes from synthetic audio, say so next to the number. If a test was
skipped, say it was skipped.

## The bug class that keeps recurring

Three separate shipped bugs had the same root cause: **an app launched from
Finder does not inherit your shell environment.** It gets
`PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing else.

1. `/usr/bin/env python3` resolved to Apple's Python 3.9.6 instead of Homebrew's
   3.14. The code uses `X | None` annotations, which need 3.10, so every
   transcription died on a `SyntaxError`.
2. `scribebot.py` then shelled out to a bare `whisper-cli`, which lives in
   `/opt/homebrew/bin` — not on a GUI app's PATH. `FileNotFoundError`.
3. Both failures were **swallowed**: the exit status was ignored, an empty
   transcript was treated as "nothing to write", and the live preview's first
   few words stayed on disk as the final record. The user saw a recording that
   "stopped transcribing in the middle" while every terminal test passed.

**Consequences for anything you write here:**

- Resolve external binaries through `toolpaths.resolve()`. Never invoke a bare
  command name from code the app can reach.
- Never ignore a subprocess exit status. Surface it.
- `bench/env_isolation.py` runs the pipeline under exactly a Finder-launched
  app's environment and is wired into `./check`. If you add a dependency that is
  resolved through the shell, this is what catches it. Do not weaken it.

## The user's own data is not repository content

`bench/meetings.json` held 439 real meetings and 850 attendee names. It was
committed in the first public commit and stayed reachable for two days. Two
files from the same calendar scan, `vocab.json` and `vocab_clean.json`, went
with it. Removing them took a history rewrite, a forced push, deleting a
release — and the objects were still fetchable by SHA afterwards, because
GitHub keeps unreferenced blobs until it collects them.

It was the third instance, not the first: `docs/progress.html` carried real
transcript text through seventeen commits, and `audio/he-en/transcripts.json`
carried transcripts through one. Each time the fix was another `.gitignore`
line, which only ever names the path that already went wrong.

**Anything derived from the user's calendar, contacts, recordings or transcripts
lives in `~/Library/Application Support/Scribebot/`, never in the checkout.**
`userdata.py` owns those locations and `Paths.support` mirrors it in Swift. A
generated file full of real names inside a directory git watches is one
`git add -A` away from being published, and this project uses `git add -A`.

`bench/no_personal_data.py` is wired into `./check` and reads content, not
filenames: a JSON object carrying an `attendees` or `organizer` field is a
calendar export whatever it is called. Do not weaken it, and do not silence it
by renaming a file.

Before any push, ask what a file is *derived from*, not what it is called.

## Testing reality

Passing `./check` does **not** mean the product works. Every serious defect in
this project was found by the user driving the app, not by the test suite:
silent recordings, transcripts that stopped after two lines, text that never
appeared in the GUI, and the mid-recording truncation above. The suite reads
source code and runs the pipeline directly; it does not drive the UI.

When you believe something is fixed, the standard is: **a recording made from
the app itself whose `.txt` on disk is complete without running `rebuild`.**

## Verify the user is running what you built

`app/build.sh` writes `app/Scribebot.app`, but a running instance keeps the old
binary. Before concluding a fix did not work, check that the app was relaunched
after the build — compare the binary's mtime against the recording's.

## Style

Match the surrounding code. Comments here explain *why*, usually by naming the
bug that motivated the line; keep that habit rather than describing what the
code plainly does.
