#!/usr/bin/env python3
"""Generate a suite of multi-speaker clips, not one.

The 7.3% DER headline came from a single 28-second clip on which both load-
bearing constants were tuned. That is a fitted number, not a measurement. This
varies the things the method is most likely to be brittle about - how many
speakers, which voices, and how much silence sits between turns - so DER can be
reported as a spread rather than a point.

Still synthetic, and still noted as such: TTS voices separate more easily than
real ones. This widens the surface; it does not replace a real recording.
"""
import json, subprocess, sys, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "bench/diar/suite"
SR = 16_000

HE = "Carmit"
EN = ["Daniel", "Samantha", "Karen", "Moira", "Tessa"]

HEB = [
    "בוקר טוב, בואו נתחיל את הפגישה השבועית שלנו",
    "מתי בדיוק זה התחיל, אתמול או היום בבוקר",
    "צריך לבדוק את הלוגים ב SIEM לפני שאנחנו מחליטים משהו",
    "מצוין, תעדכנו אותי עד סוף היום בבקשה",
    "אני חושב שכדאי לפתוח כרטיס ולעקוב אחרי זה",
]
ENG = [
    "Good morning. We are seeing errors from the DLP in production.",
    "It started right after the deploy last night, around eleven.",
    "Agreed. I will pull the logs and open a ticket this morning.",
    "Will do. I will send you both the link when it is ready.",
    "Let us review the dashboard before the next standup.",
]

# name, speakers, inter-turn gap, number of turns
CASES = [
    ("2spk_gap25",  [HE, EN[0]],                 0.25, 8),
    ("2spk_gap05",  [HE, EN[1]],                 0.05, 8),
    ("3spk_gap25",  [HE, EN[0], EN[1]],          0.25, 9),
    ("3spk_gap10",  [HE, EN[2], EN[3]],          0.10, 9),
    ("3spk_female", [HE, EN[1], EN[2]],          0.25, 9),   # all female - hardest
    ("4spk_gap25",  [HE, EN[0], EN[1], EN[4]],   0.25, 12),
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


def build(name: str, voices: list[str], gap: float, turns: int) -> dict:
    d = OUT / name
    d.mkdir(parents=True, exist_ok=True)
    parts, meta, t = [], [], 0.0
    for i in range(turns):
        v = voices[i % len(voices)]
        text = (HEB if v == HE else ENG)[i % 5]
        p = d / f"t{i:02d}.wav"
        dur = synth(v, text, p)
        if dur < 0.4:      # a voice that cannot say this line would be a fake turn
            p.unlink(missing_ok=True)
            continue
        meta.append({"speaker": v, "start": round(t, 3),
                     "end": round(t + dur, 3), "text": text})
        parts.append(p); t += dur + gap

    sil = d / "gap.wav"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi",
                    "-i", f"anullsrc=r={SR}:cl=mono", "-t", str(gap),
                    "-c:a", "pcm_s16le", str(sil)], check=True)
    listing = d / "c.txt"
    listing.write_text("".join(f"file '{p}'\nfile '{sil}'\n" for p in parts))
    mixed = d / "meeting.wav"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "concat", "-safe", "0",
                    "-i", str(listing), "-ar", str(SR), "-ac", "1",
                    "-c:a", "pcm_s16le", str(mixed)], check=True)
    (d / "truth.json").write_text(json.dumps(
        {"audio": "meeting.wav", "sample_rate": SR,
         "speakers": sorted({m["speaker"] for m in meta}), "turns": meta},
        ensure_ascii=False, indent=1))
    for p in parts: p.unlink(missing_ok=True)
    sil.unlink(missing_ok=True); listing.unlink(missing_ok=True)
    with wave.open(str(mixed)) as w:
        total = w.getnframes() / w.getframerate()
    return {"name": name, "seconds": total, "turns": len(meta),
            "speakers": len({m["speaker"] for m in meta}), "gap": gap}


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    rows = [build(*c) for c in CASES]
    print(f"{'clip':<14}{'secs':>7}{'turns':>7}{'spk':>5}{'gap':>7}")
    print("-" * 42)
    for r in rows:
        print(f"{r['name']:<14}{r['seconds']:>7.1f}{r['turns']:>7}"
              f"{r['speakers']:>5}{r['gap']:>7.2f}")


if __name__ == "__main__":
    main()
