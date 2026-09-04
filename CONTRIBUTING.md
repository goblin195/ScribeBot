# Contributing to Scribebot

Thanks for being here. This project is small, opinionated, and honest about what
it does not yet do — all three make it a good one to contribute to.

## The fastest useful contribution

**Teach it a term.** Hebrew speech recognition transliterates English technical
vocabulary: `SSE` becomes `אס אס אי`, `Kubernetes` becomes `קוברנטיס`. Every
term restored makes real transcripts more searchable, and it requires no Swift,
no audio programming, and no model training.

1. Add the term and its transliterations to `bench/aliases.json`:

   ```json
   {
     "Kubernetes": ["קוברנטיס", "קוברנטס"],
     "Postgres":   ["פוסטגרס"]
   }
   ```

   List every spelling you have actually seen. Whisper is not consistent.

2. Run the checks:

   ```sh
   ./check
   ```

3. Open a PR with the term and **one real sentence it appeared in**. That
   sentence is the evidence, and it often becomes a test case.

This scales beyond Hebrew and beyond security vocabulary. Any language that
code-switches into English has the same problem.

## Setting up

```sh
brew install whisper-cpp
git clone https://github.com/goblin195/ScribeBot.git && cd ScribeBot
# place models/ivrit-large-v3-turbo.bin (~1.6 GB, gitignored)
./check
```

To work on the app itself:

```sh
./capture/build.sh    # audio capture helper
./app/build.sh        # menu bar app
```

Requires macOS 14.2+ on Apple Silicon and Python 3.10 or newer — the codebase
uses `X | None` annotations throughout.

## The rules that matter

These are not style preferences. Each one is here because breaking it shipped a
bug or lost user data.

### 1. Run `./check` before opening a PR

It takes seconds and it has caught real regressions. `./check --e2e` also
exercises real audio hardware.

### 2. A benchmark gain that fails the negative control is a regression

`bench/negative_control.py` holds 45 sentences — adversarial Hebrew, ordinary
English prose, Latin-script traps — that the glossary must leave byte-for-byte
unchanged.

It exists because an earlier fuzzy-matching restorer scored *better* on the
benchmark while corrupting 15.4% of a sample of real strings, rewriting `מטריקס`
into `metrics` seventeen times. The fuzzy matcher was deleted and the benchmark
score was allowed to fall. **Prefer adding aliases over making the matcher
cleverer.**

### 3. Never swallow a subprocess exit status

Every silent-failure bug in this project's history came from ignoring an exit
code and treating an empty result as "nothing to do". Users experienced it as
transcripts that stopped mid-recording.

### 4. Resolve external binaries absolutely

Use `toolpaths.resolve()`. Never invoke a bare command name from code the app
can reach: an app launched from Finder gets
`PATH=/usr/bin:/bin:/usr/sbin:/sbin` and nothing else. This has caused three
separate shipped bugs. `bench/env_isolation.py` runs the pipeline under exactly
that environment — do not weaken it.

### 5. Never touch the recordings directory

`~/Library/Application Support/Scribebot/recordings` is irreplaceable user data.
Ten files were destroyed by a careless recursive delete during development, with
no backup. Do not write tests or scripts whose globs could reach it. See
[RECORDINGS.md](RECORDINGS.md).

### 6. Report results honestly

If a number comes from synthetic audio, say so next to the number. If a test was
skipped, say it was skipped. This project has publicly retracted two claims that
turned out to be wrong; that is a feature of how it is run, not an embarrassment.

## Testing reality

**`./check` passing does not mean the product works.** The suite reads Swift
source and runs the pipeline directly — it does not drive the UI. Every serious
defect so far was found by a human using the app: silent recordings, transcripts
that stopped after two lines, text that never appeared in the window.

If you change the transcription path, the standard of proof is **a recording
made from the app itself whose `.txt` on disk is complete without running
`rebuild`**. And confirm the app you are testing is the binary you just built —
a running instance keeps the old one.

## Code style

Match the surrounding code.

- **Comments explain *why*,** usually by naming the bug that motivated the line.
  Do not describe what the code plainly does.
- Small, focused files. Prefer clarity over cleverness.
- Python: standard library first. Swift: idiomatic SwiftUI, no Xcode project.

## Commit messages

Write what changed and why it mattered, in prose. The existing history is the
reference — commits explain the failure they fix, often with the observed
symptom, because that is what a future reader needs.

## Reporting bugs

Please include:

- macOS version and chip
- What you did, what you expected, what happened
- Whether the audio itself is intact:
  `./scribebot.py file <the-wav>` — if that prints the full text, the audio was
  fine and only the write failed
- Whether the app was relaunched after the last build

[docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md) covers the failure modes
already known, with the diagnostic for each. Checking there first may save you
the report entirely.

## What this project will not become

- It will not join calls as a participant.
- It will not upload audio, transcripts, or telemetry anywhere.
- It will not add a cloud component, an account, or a paid tier.

PRs that add any of those will be declined regardless of quality.

## License

By contributing you agree that your contributions are licensed under the
[MIT License](LICENSE).
