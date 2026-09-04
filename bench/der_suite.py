#!/usr/bin/env python3
"""DER for both systems across the whole clip suite, reported as a spread.

A single fitted number says nothing about whether the method generalises. This
runs every clip in bench/diar/suite and prints per-clip and aggregate DER, so a
constant tuned on one clip shows up as variance here.
"""
import json, subprocess, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "bench"))
from der import der, load_rttm     # scoring logic untouched

SUITE = ROOT / "bench/diar/suite"
SPEAKERKIT = Path.home() / ("Library/Application Support/app.tape.Tape/"
                            "models/argmaxinc/speakerkit-coreml")


def truth(d: Path):
    t = json.loads((d / "truth.json").read_text())
    return [(x["start"], x["end"], x["speaker"]) for x in t["turns"]]


def run_tape(wav: Path, out: Path, nspk: int = 0) -> bool:
    """Run the competitor. When a speaker count is known it is passed, because
    this system gets the same hint from the calendar - comparing a tuned system
    against a stock one is not a comparison."""
    cmd = ["whisperkit-cli", "diarize", "--audio-path", str(wav),
           "--model-path", str(SPEAKERKIT), "--rttm-path", str(out)]
    if nspk > 0: cmd += ["--num-speakers", str(nspk)]
    subprocess.run(cmd, capture_output=True, text=True)
    return out.exists()


def run_ours(wav: Path, out: Path, nspk: int = 0) -> bool:
    cmd = [str(ROOT / ".venv/bin/python"), str(ROOT / "bench/run_diar.py"),
           str(wav), str(out)]
    if nspk > 0: cmd.append(str(nspk))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if not out.exists():
        print(f"    ours failed: {r.stderr.strip()[:160]}", file=sys.stderr)
    return out.exists()


HINT = "--hint" in sys.argv     # give BOTH systems the attendee count

def main() -> None:
    dirs = sorted(p for p in SUITE.iterdir() if (p / "meeting.wav").exists())
    if not dirs:
        sys.exit("no suite clips - run bench/make_diar_suite.py first")
    print(("with speaker count from the calendar" if HINT
           else "no speaker hint - both systems run unaided") + "\n")
    print(f"{'clip':<14}{'ref spk':>8}{'Tape DER':>10}{'spk':>5}"
          f"{'ours DER':>10}{'spk':>5}")
    print("-" * 54)
    tape_all, ours_all = [], []
    for d in dirs:
        ref = truth(d)
        nref = len({s for _, _, s in ref})
        wav = d / "meeting.wav"
        nspk = nref if HINT else 0
        row = [d.name, nref]
        for label, fn, name in (("tape", run_tape, "tape.rttm"),
                                ("ours", run_ours, "ours.rttm")):
            out = d / name
            if not fn(wav, out, nspk):
                row += ["n/a", "-"]; continue
            hyp = load_rttm(out)
            if not hyp:
                row += ["n/a", "-"]; continue
            score = der(ref, hyp)[0]
            nspk = len({s for _, _, s in hyp})
            (tape_all if label == "tape" else ours_all).append(score)
            row += [f"{score*100:.1f}%", str(nspk)]
        print(f"{row[0]:<14}{row[1]:>8}{row[2]:>10}{row[3]:>5}{row[4]:>10}{row[5]:>5}")
    print("-" * 54)
    def summ(v):
        return f"{sum(v)/len(v)*100:.1f}% (worst {max(v)*100:.1f}%)" if v else "n/a"
    print(f"{'mean':<14}{'':>8}{summ(tape_all):>15}{summ(ours_all):>24}")


if __name__ == "__main__":
    main()
