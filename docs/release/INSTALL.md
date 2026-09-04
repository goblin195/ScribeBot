# Scribebot 0.1

Requires an Apple Silicon Mac running macOS 14.2 or later.

1. Drag Scribebot into Applications.
2. Open Scribebot from Applications.
3. Allow system audio recording and microphone access when requested.

The app includes Python, whisper.cpp, the Hebrew ivrit-ai large-v3-turbo model,
and the technical glossary. No Homebrew installation or source checkout is
needed for recording and transcription. The model makes the download large.

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
