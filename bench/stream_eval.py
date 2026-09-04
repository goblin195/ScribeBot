#!/usr/bin/env python3
"""Measure streaming coverage honestly: recall of reference words, not commits.

Commit counts flatter a streaming system - duplicates inflate them and dropped
speech is invisible. This replays audio at real-time pace and reports what
fraction of the reference words actually reached the reader, plus the delay
before the first word appeared.
"""
import sys, time, wave
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT)); sys.path.insert(0, str(ROOT / "bench"))
from stream import Stream
from score import norm
import json

def reference_words() -> list[str]:
    t = json.loads((ROOT / "bench/diar/truth.json").read_text())
    return norm(" ".join(x["text"] for x in t["turns"])).split()

def recall(ref: list[str], hyp: list[str]) -> float:
    """Fraction of reference words matched in order (LCS-based, so repeats and
    reordering cannot inflate the score)."""
    n, m = len(ref), len(hyp)
    prev = [0] * (m + 1)
    for i in range(1, n + 1):
        cur = [0]
        for j in range(1, m + 1):
            cur.append(prev[j - 1] + 1 if ref[i - 1] == hyp[j - 1]
                       else max(prev[j], cur[j - 1]))
        prev = cur
    return prev[m] / n if n else 0.0

def main() -> None:
    wav = ROOT / "bench/diar/meeting.wav"
    with wave.open(str(wav)) as w:
        pcm = w.readframes(w.getnframes()); sr = w.getframerate()
    dur = len(pcm) / (sr * 2)
    s = Stream()
    first = None
    t0 = time.time(); chunk = sr * 2 // 10; last_step = t0
    for i in range(0, len(pcm), chunk):
        s.feed(pcm[i:i + chunk])
        target = t0 + (i + chunk) / (sr * 2)
        if time.time() - last_step >= 1.0:
            got = s.step()
            last_step = time.time()
            if got and first is None:
                first = time.time() - t0
        time.sleep(max(0.0, target - time.time()))
    while s.seconds_buffered() > 1.0:
        if not s.step(): break
    s.flush()
    if first is None and s.confirmed: first = time.time() - t0

    ref = reference_words()
    hyp = norm(s.text()).split()
    r = recall(ref, hyp)
    print(f"audio            {dur:.1f}s")
    print(f"reference words  {len(ref)}")
    print(f"committed words  {len(hyp)}")
    print(f"recall           {r*100:.1f}%   (reference words that reached the reader)")
    print(f"first word after {first:.1f}s" if first else "first word       never")
    print()
    print("transcript:")
    print("  " + s.text()[:400])

if __name__ == "__main__":
    main()
