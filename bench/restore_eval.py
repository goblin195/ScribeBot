#!/usr/bin/env python3
"""Re-score cached hypotheses with glossary restoration.

Reports two numbers, because they answer different questions:
  FULL      glossary contains the org's whole vocabulary - the realistic ceiling
            for a deployed system that indexed the user's docs and calendar.
  HELD-OUT  glossary built only from categories 03+04, scored on 06+07+08.
            Terms it has never seen. This is the generalization floor and the
            only number that is free of leakage.
"""
import json, re, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).parent))
from glossary import Restorer
from score import wer, kept, terms

ROOT = Path(__file__).resolve().parent.parent
res = json.loads((ROOT / "bench/out/results.json").read_text())
full_gloss = json.loads((ROOT / "bench/terms.json").read_text())

TRAIN_CATS = ("03_cybersecurity", "04_ai")
TEST_CATS  = ("06_names", "07_acronyms", "08_mixed_hebrew_english")

def cat(cid): return cid.rsplit("_", 1)[0]

# held-out glossary: only terms that appear in the training categories
train_terms = sorted({t for r in res["rows"] if cat(r["id"]) in TRAIN_CATS
                        for t in r["terms"]})

def evaluate(rows, system, restorer=None, label=""):
    k = n = 0; wers = []
    for r in rows:
        h = r["hyp"].get(system)
        if not h: continue
        text = restorer.restore(h["text"]) if restorer else h["text"]
        got, want = kept(r["ref"], text)
        k += len(got); n += len(want); wers.append(wer(r["ref"], text))
    if not n: return None
    return {"label": label, "tpr": k / n, "kept": k, "terms": n,
            "wer": sum(wers) / len(wers), "clips": len(wers)}

systems = [s for s in res["summary"] if s != "baseline(asr_heb)"]
R_full = Restorer(full_gloss)
R_held = Restorer(train_terms)

print(f"held-out glossary built from {len(train_terms)} terms in {TRAIN_CATS}")
print(f"evaluated on {TEST_CATS}\n")

def show(title, out):
    print(title)
    print(f"  {'system':<34} {'TPR':>8} {'terms':>10} {'WER':>8}")
    print("  " + "-" * 62)
    for o in out:
        if o: print(f"  {o['label']:<34} {o['tpr']*100:>7.1f}% "
                    f"{o['kept']:>4}/{o['terms']:<5} {o['wer']*100:>7.1f}%")
    print()

allrows = res["rows"]
show("ALL 26 CLIPS - full org glossary (deployment ceiling, contains test terms)",
     [evaluate(allrows, s, None, s) for s in systems] +
     [evaluate(allrows, s, R_full, f"{s} + glossary") for s in systems])

testrows = [r for r in allrows if cat(r["id"]) in TEST_CATS]
show("HELD-OUT - glossary never saw these terms (leakage-free)",
     [evaluate(testrows, s, None, s) for s in systems] +
     [evaluate(testrows, s, R_held, f"{s} + held-out glossary") for s in systems])
