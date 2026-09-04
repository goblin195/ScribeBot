#!/usr/bin/env python3
"""Run the transcription pipeline the way a Finder-launched app runs it.

Three separate bugs shipped because the app's environment is not the shell's.
An app launched from Finder gets PATH=/usr/bin:/bin:/usr/sbin:/sbin and nothing
else - no Homebrew python, no whisper-cli - so the pipeline failed there while
every terminal test passed. This reproduces that environment exactly, so the
next dependency resolved through the shell fails here instead of in a meeting.
"""
import os, subprocess, sys, wave, array, math, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FINDER_PATH = "/usr/bin:/bin:/usr/sbin:/sbin"


def _speechlike_wav(path: Path, seconds: float = 2.0, sr: int = 16_000) -> None:
    """Not real speech - just enough signal to get past the silence guard."""
    n = int(sr * seconds)
    samples = array.array("h", (
        int(9000 * math.sin(2 * math.pi * 140 * t / sr) *
            (1 + 0.5 * math.sin(2 * math.pi * 3 * t / sr)))
        for t in range(n)))
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
        w.writeframes(samples.tobytes())


def main() -> int:
    python = sys.executable  # the app resolves an absolute python the same way
    with tempfile.TemporaryDirectory() as d:
        wav = Path(d) / "probe.wav"
        _speechlike_wav(wav)
        r = subprocess.run(
            [python, str(ROOT / "scribebot.py"), "file", str(wav)],
            cwd=ROOT, capture_output=True, text=True,
            env={"HOME": os.environ["HOME"], "PATH": FINDER_PATH},
        )
    if r.returncode != 0:
        tail = (r.stderr or "").strip().splitlines()[-1:] or ["(no stderr)"]
        print(f"FAIL transcription dies without the shell PATH: {tail[0]}")
        print("     a Finder-launched app has exactly this environment.")
        return 1
    print("ok   transcription survives a Finder-launched app's environment")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
