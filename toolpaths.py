#!/usr/bin/env python3
"""Absolute paths to the external tools this project shells out to.

An app launched from Finder inherits none of the shell PATH - it gets
/usr/bin:/bin:/usr/sbin:/sbin - so a bare "whisper-cli" raises FileNotFoundError
there while working perfectly in a terminal. The app saw a failed transcription,
fell back to the live preview, and the recording looked like it "stopped in the
middle". Resolve once, absolutely, and say so plainly when it is missing.
"""
import os, shutil
from pathlib import Path

# Where package managers put binaries that a GUI process will never see.
_EXTRA = ("/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin")


def resolve(name: str, env_var: str) -> str:
    """Absolute path to `name`, honouring `env_var` as an override."""
    override = os.environ.get(env_var)
    if override:
        return override
    bundled = Path(__file__).resolve().parent / "bin" / name
    if bundled.is_file() and os.access(bundled, os.X_OK):
        return str(bundled)
    found = shutil.which(name) or shutil.which(name, path=os.pathsep.join(_EXTRA))
    if found:
        return found
    raise SystemExit(
        f"{name} not found on PATH or in {', '.join(_EXTRA)}.\n"
        f"Install it (brew install whisper-cpp) or set {env_var} to its full path.")


WHISPER = resolve("whisper-cli", "SCRIBEBOT_WHISPER")
