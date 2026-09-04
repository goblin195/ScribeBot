#!/usr/bin/env python3
"""Build a multi-speaker Hebrew meeting clip with exact turn boundaries.

The 26-clip corpus is single-speaker, so diarization error rate cannot be scored
on it at all. This synthesises a conversation from distinct system voices, which
gives ground-truth turn boundaries that are exact by construction rather than
hand-labelled.

Caveat recorded here so it travels with the number: synthetic voices separate
more easily than real ones, so absolute DER will be optimistic for every system
measured. Both systems face identical audio, so the comparison stays fair; the
absolute value does not transfer to real meetings.
"""
import json, subprocess, sys, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "bench/diar"
SR = 16_000

# A bilingual meeting: the Hebrew speaker uses Hebrew carrying English technical
# terms, the international colleagues speak English. Only Carmit can articulate
# Hebrew - handing Hebrew text to an English voice produces near-silence, which
# would make the turn undetectable and the ground truth a lie.
SCRIPT = [
    ("Carmit",   "בוקר טוב, בואו נתחיל את הפגישה השבועית שלנו"),
    ("Daniel",   "Good morning. We are seeing errors from the DLP in production."),
    ("Carmit",   "מתי בדיוק זה התחיל, אתמול או היום בבוקר"),
    ("Samantha", "It started right after the deploy last night, around eleven."),
    ("Carmit",   "צריך לבדוק את הלוגים ב SIEM לפני שאנחנו מחליטים משהו"),
    ("Daniel",   "Agreed. I will pull the logs and open a ticket this morning."),
    ("Carmit",   "מצוין, תעדכנו אותי עד סוף היום בבקשה"),
    ("Samantha", "Will do. I will send you both the link when it is ready."),
]

def synth(voice: str, text: str, dest: Path) -> float:
    aiff = dest.with_suffix(".aiff")
    subprocess.run(["say", "-v", voice, "-o", str(aiff), text], check=True)
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-i", str(aiff),
                    "-ar", str(SR), "-ac", "1", "-c:a", "pcm_s16le", str(dest)],
                   check=True)
    aiff.unlink(missing_ok=True)
    with wave.open(str(dest)) as w:
        return w.getnframes() / w.getframerate()

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    parts, turns, t = [], [], 0.0
    gap = 0.25   # natural inter-turn pause
    for i, (voice, text) in enumerate(SCRIPT):
        p = OUT / f"turn{i:02d}.wav"
        dur = synth(voice, text, p)
        turns.append({"speaker": voice, "start": round(t, 3),
                      "end": round(t + dur, 3), "text": text})
        parts.append(p)
        t += dur + gap

    listing = OUT / "concat.txt"
    silence = OUT / "gap.wav"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", f"anullsrc=r={SR}:cl=mono", "-t", str(gap),
                    "-c:a", "pcm_s16le", str(silence)], check=True)
    with listing.open("w") as f:
        for p in parts:
            f.write(f"file '{p}'\nfile '{silence}'\n")
    mixed = OUT / "meeting.wav"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat",
                    "-safe", "0", "-i", str(listing), "-ar", str(SR),
                    "-ac", "1", "-c:a", "pcm_s16le", str(mixed)], check=True)

    (OUT / "truth.json").write_text(json.dumps(
        {"audio": mixed.name, "sample_rate": SR,
         "speakers": sorted({t["speaker"] for t in turns}),
         "turns": turns}, ensure_ascii=False, indent=1))
    for p in parts: p.unlink(missing_ok=True)
    silence.unlink(missing_ok=True); listing.unlink(missing_ok=True)
    with wave.open(str(mixed)) as w:
        total = w.getnframes() / w.getframerate()
    print(f"{mixed}  {total:.1f}s  {len(turns)} turns  "
          f"{len({t['speaker'] for t in turns})} speakers")
    for t in turns:
        print(f"  {t['start']:6.2f}-{t['end']:6.2f}  {t['speaker']:<9} {t['text'][:38]}")

if __name__ == "__main__":
    main()
