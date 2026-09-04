#!/usr/bin/env python3
"""Diarization error rate against the synthetic bilingual meeting.

DER = (missed speech + false alarm + speaker confusion) / total reference speech.
Speaker labels are arbitrary, so hypothesis labels are mapped onto reference
labels by the assignment that maximises overlap before confusion is counted.
"""
import itertools, json, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
STEP = 0.01   # 10 ms frames

def load_truth():
    d = json.loads((ROOT / "bench/diar/truth.json").read_text())
    return [(t["start"], t["end"], t["speaker"]) for t in d["turns"]]

def load_rttm(p: Path):
    out = []
    for line in p.read_text().splitlines():
        f = line.split()
        if len(f) >= 8 and f[0] == "SPEAKER":
            start, dur, spk = float(f[3]), float(f[4]), f[7]
            out.append((start, start + dur, spk))
    return out

def frames(segs, end):
    n = int(end / STEP) + 1
    lab = [None] * n
    for s, e, spk in segs:
        for i in range(max(0, int(s / STEP)), min(n, int(e / STEP))):
            lab[i] = spk
    return lab

def der(ref, hyp):
    end = max(max(e for _, e, _ in ref), max((e for _, e, _ in hyp), default=0))
    R, H = frames(ref, end), frames(hyp, end)
    rs = sorted({s for s in R if s}); hs = sorted({s for s in H if s})
    best = None
    # Every injective mapping between hypothesis and reference labels.
    #
    # Both directions have to be enumerated. Permuting only the hypothesis side
    # pins those labels to the first reference speakers alphabetically, so a
    # system that finds FEWER speakers than the reference can never be scored
    # against the later ones - that penalised the competitor on four of six
    # clips and this system on none. Permuting only the reference side has the
    # mirror fault for a system that finds MORE speakers than the reference,
    # which is this system's failure mode. Whichever side is larger is the one
    # that must be permuted.
    if len(hs) >= len(rs):
        candidates = (dict(zip(perm, rs))
                      for perm in itertools.permutations(hs, len(rs)))
    else:
        candidates = (dict(zip(hs, perm))
                      for perm in itertools.permutations(rs, len(hs)))
    for m in candidates:
        miss = fa = conf = 0
        for r, h in zip(R, H):
            hm = m.get(h) if h else None
            if r and not h: miss += 1
            elif h and not r: fa += 1
            elif r and h and hm != r: conf += 1
        tot = sum(1 for r in R if r)
        score = (miss + fa + conf) / tot
        if best is None or score < best[0]:
            best = (score, miss / tot, fa / tot, conf / tot)
    return best

def main():
    ref = load_truth()
    n_ref_spk = len({s for _, _, s in ref})
    print(f"reference: {len(ref)} turns, {n_ref_spk} speakers\n")
    print(f"{'system':<26} {'DER':>8} {'miss':>8} {'FA':>8} {'conf':>8} {'spk':>5}")
    print("-" * 68)
    for name, path in [("Tape SpeakerKit", "bench/diar/tape.rttm"),
                       ("ours (pyannote)", "bench/diar/ours.rttm")]:
        p = ROOT / path
        if not p.exists():
            print(f"{name:<26} {'(not run)':>8}")
            continue
        hyp = load_rttm(p)
        d, m, f, c = der(ref, hyp)
        nspk = len({s for _, _, s in hyp})
        flag = "" if nspk == n_ref_spk else f"  <- found {nspk}, not {n_ref_spk}"
        print(f"{name:<26} {d*100:>7.1f}% {m*100:>7.1f}% {f*100:>7.1f}% "
              f"{c*100:>7.1f}% {nspk:>5}{flag}")

if __name__ == "__main__":
    main()
