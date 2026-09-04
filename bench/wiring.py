#!/usr/bin/env python3
"""Assert the app actually spawns the capture helpers it needs.

bench/e2e.py runs the real helper against real hardware, but it spawns that
helper ITSELF - so it passes whether or not the app does. The first fault ever
reported from real use was a missing startMic() call in Recorder.swift, and
e2e.py would not catch it being reintroduced tomorrow.

This reads the app's own source and asserts the wiring. It is a weaker check
than driving the UI, and it is honest about that: it proves the calls exist,
not that they run.
"""
import re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REC = ROOT / "app/Sources/Recorder.swift"

CHECKS = [
    ("microphone capture is started",
     lambda s: re.search(r"^\s*startMic\(\)", s, re.M)),
    ("startMic spawns the helper in `mic` mode",
     lambda s: re.search(r'arguments\s*=\s*\["mic",', s)),
    ("the mic helper streams as well as writing its file",
     lambda s: '"--stream"' in s),
    ("system audio is captured with `stream`",
     lambda s: re.search(r'arguments\s*=\s*\["stream"', s)),
    ("the tap stream is NOT mixed with the mic",
     lambda s: '["stream", "--mic"]' not in s),
    ("both helper processes are terminated on stop",
     lambda s: "tap?.terminate()" in s and "micProc?.terminate()" in s),
    ("the recording is re-transcribed after stopping",
     lambda s: "finalize(" in s),
    # The accurate transcript must reach disk BEFORE the main-actor hop.
    # Persisting only inside DispatchQueue.main.async meant a quit during the
    # ~1s decode lost it, leaving the live preview's first fragment as the
    # permanent record - the user's transcripts were truncated by up to 75%
    # and every other check stayed green.
    ("the finalized transcript is written before the UI hop",
     lambda s: _writes_before_main_hop(s)),
    # A Finder-launched app does not inherit the shell PATH, so `env python3`
    # finds Apple's 3.9 and this project needs 3.10+. Every finalize died on a
    # SyntaxError, silently, and the live preview stayed as the transcript.
    ("python is resolved explicitly, not via env",
     lambda s: "Paths.python" in s and
               not re.search(r'executableURL\s*=\s*URL\(fileURLWithPath:\s*"/usr/bin/env"', s)),
    ("a failed transcription is reported, not swallowed",
     lambda s: "terminationStatus != 0" in s),
]


def _writes_before_main_hop(src: str) -> bool:
    i = src.find("private func finalize")
    if i < 0: return False
    body = src[i:i + 6000]
    w = body.find("writeTranscript")
    # Anchor on the UI update itself, not on any main-queue hop - error
    # reporting also hops, and comparing against the first one made this check
    # fail on correct code.
    m = body.find("self.library.save")
    return w >= 0 and m >= 0 and w < m


def main() -> int:
    if not REC.exists():
        print(f"FAIL  missing {REC}")
        return 1
    src = REC.read_text()
    bad = []
    for name, test in CHECKS:
        ok = bool(test(src))
        print(f"  {'ok  ' if ok else 'FAIL'}  {name}")
        if not ok: bad.append(name)
    print()
    if bad:
        print(f"app wiring: {len(bad)} broken")
        return 1
    print(f"app wiring: {len(CHECKS)}/{len(CHECKS)} — the app spawns both capture paths")
    return 0


if __name__ == "__main__":
    sys.exit(main())
