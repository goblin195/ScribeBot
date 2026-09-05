# Scribebot 0.1

Requires an Apple Silicon Mac running macOS 14.2 or later.

1. Drag Scribebot into Applications.
2. Open Scribebot from Applications.
3. Setup opens on first launch. It downloads a speech model, asks which engine
   should write summaries, and explains the four macOS permissions.

The app includes Python, whisper.cpp and the technical glossary. No Homebrew
installation or source checkout is needed.

**The speech model is not in this download.** Setup fetches it on first launch,
which is why the installer is small. Two are offered and you can take either or
both — about 1.5 GB each:

- Hebrew, the ivrit-ai fine-tune of large-v3-turbo. The better decoder for
  Hebrew, including Hebrew carrying English technical terms.
- Multilingual, the stock whisper.cpp large-v3-turbo. The better decoder for
  every other language, and what language auto-detection runs on.

They are stored in `~/Library/Application Support/Scribebot/models/`, not inside
the app, so replacing Scribebot does not make you download them again. A
download that is interrupted resumes where it stopped; nothing is installed
until its size and SHA-256 both match, so a partial or failed download can never
be left behind pretending to be a model. If a download will not complete, setup
shows the exact URL and the exact path to put the file at.

Recording will not work until one model is installed. System audio recording
and Microphone are two separate macOS permissions — allowing one does not allow
the other. Without system audio you record only yourself; without the
microphone, only everybody else.

This release is ad-hoc signed, not Apple-notarized. macOS may block its first
launch. If you trust this release, use System Settings > Privacy & Security >
Open Anyway after attempting to launch it. Do not disable Gatekeeper globally.

Summaries are optional and require Ollama running locally with gemma4:latest.
The installer does not include Ollama or its model. The People screen needs a
calendar index; this release deliberately includes no personal calendar data.

Recordings remain in ~/Library/Application Support/Scribebot/recordings.
Replacing the app does not replace your recordings. Delete actions move the
selected files to macOS Trash; no recordings are removed during installation.

Source and releases: https://github.com/goblin195/ScribeBot
