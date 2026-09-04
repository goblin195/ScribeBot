#!/usr/bin/env python3
"""Live transcript from system audio and microphone.

Thin driver over `stream.Stream`, which owns the LocalAgreement-2 stabilisation
in absolute time. This file used to own that logic and got it wrong: hypotheses
were compared in window-relative time, so every buffer trim shifted the text
underneath the comparison and the transcript fell silent after a couple of
lines. The app hit exactly that in real use.

Output protocol, relied on by the SwiftUI app:
  a plain line          committed text, never revised
  a line starting "~"   the unstable tail, replaces whatever tail was shown
"""
import subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT))
from stream import Stream, SR

CAPTURE = ROOT / "capture/ScribebotCapture.app/Contents/MacOS/ScribebotCapture"
STEP_SEC = 1.0


def source(pids: list[str], use_stdin: bool):
    """PCM16 mono 16 kHz, either from stdin or from our own capture helper."""
    if use_stdin:
        return None, sys.stdin.buffer
    if not CAPTURE.exists():
        sys.exit(f"missing {CAPTURE}")
    p = subprocess.Popen([str(CAPTURE), "stream", "--mic", *pids],
                         stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    return p, p.stdout


def run(pids: list[str], restorer=None, duration: float | None = None,
        stdin_pcm: bool = False, provisional: bool = False,
        label: str = "") -> None:
    proc, pcm_in = source(pids, stdin_pcm)
    s = Stream()
    started = time.time()
    last_step = started
    first_at = None
    print("listening… (ctrl-c to stop)", file=sys.stderr, flush=True)
    try:
        while True:
            if duration and time.time() - started > duration:
                break
            chunk = pcm_in.read(4096)
            if not chunk:
                break
            s.feed(chunk)
            if time.time() - last_step < STEP_SEC:
                continue
            fresh = s.step()
            # stamp AFTER the decode: stamping before let the ~1s decode count
            # toward the interval, so the next pass fired immediately on a
            # barely-changed buffer and the model hallucinated on the repeat.
            last_step = time.time()
            if fresh:
                text = " ".join(w.text for w in fresh)
                if restorer: text = restorer.restore(text)
                print(f"{label}{text}", flush=True)
                if first_at is None: first_at = time.time() - started
            elif provisional:
                # everything decoded but not yet agreed on twice
                cut = s.confirmed[-1].end if s.confirmed else -1.0
                tail = " ".join(w.text for w in s.prev if w.start > cut - 0.05)
                if tail:
                    print("~" + tail, flush=True)
    except KeyboardInterrupt:
        pass
    finally:
        # Decode whatever is still buffered before giving up on it. Without this
        # a stream that ends before the next scheduled step - a short recording,
        # or a file replayed faster than real time - transcribed to nothing at
        # all, because flush() can only accept what a decode already produced.
        while s.seconds_buffered() > 1.0:
            if not s.step():
                break
        # accept the final hypothesis rather than discarding the last utterance
        fresh = s.flush()
        if fresh:
            text = " ".join(w.text for w in fresh)
            if restorer: text = restorer.restore(text)
            print(f"{label}{text}", flush=True)
        if proc: proc.terminate()
        heard = s.offset + s.seconds_buffered()
        if first_at is not None:
            print(f"\n[first word after {first_at:.1f}s · "
                  f"{len(s.confirmed)} words over {heard:.0f}s of audio]",
                  file=sys.stderr, flush=True)
        else:
            print("\n[nothing was committed]", file=sys.stderr, flush=True)


if __name__ == "__main__":
    args = sys.argv[1:]
    stdin_pcm = "--stdin" in args
    provisional = "--provisional" in args
    args = [a for a in args if a not in ("--stdin", "--provisional")]
    label = ""
    for a in list(args):
        if a.startswith("--label="):
            label = a.split("=", 1)[1] + " "
            args.remove(a)
    dur = None
    if args and args[0].startswith("--seconds="):
        dur = float(args[0].split("=", 1)[1]); args = args[1:]
    from scribebot import load_glossary
    r, _ = load_glossary()
    run(args, restorer=r, duration=dur, stdin_pcm=stdin_pcm,
        provisional=provisional, label=label)
