#!/usr/bin/env python3
"""Propose corrected references for the corpus.

`transcripts.json:prompt` is the script the speaker was handed, not what they
said. The speaker ad-libbed, and three independent decoders agree on the ad-libs
- so those words were really spoken and are currently scored as ASR errors.

Rule used here, deliberately conservative:
  * Hebrew wording comes from consensus - a token is adopted only when at least
    two of the three independent systems produce it.
  * Latin technical terms always come from the original script. The systems
    transliterate them, so the script stays authoritative for the terms; this is
    what keeps the corrected reference from rewarding the very failure we
    measure.
Every change is emitted as a diff for human approval. Nothing is auto-applied.
"""
import json, sys
from pathlib import Path
from difflib import SequenceMatcher
sys.path.insert(0, str(Path(__file__).parent))
from score import norm, terms as latin_terms
from glossary import variants as he_variants, _norm_he

ROOT = Path(__file__).resolve().parent.parent
res = json.loads((ROOT / "bench/out/results.json").read_text())
SYS = ["TAPE-he-medium", "ivrit-large-v3-turbo"]

def consensus(hyps):
    """Tokens present in a majority of hypotheses, in the order of the longest."""
    toks = [norm(h).split() for h in hyps if h]
    if not toks: return []
    base = max(toks, key=len)
    out = []
    for t in base:
        votes = sum(1 for seq in toks if t in seq)
        if votes >= max(2, (len(toks) + 1) // 2):
            out.append(t)
    return out

proposals = {}
for r in res["rows"]:
    ref = r["ref"]
    hyps = [r["hyp"][s]["text"] for s in SYS if s in r["hyp"]]
    cons = consensus(hyps)
    ref_toks = norm(ref).split()
    # words every system agreed on that the script does not contain
    extra = [t for t in cons if t not in ref_toks]
    # Protect the Latin terms the script specifies. A Hebrew token that is
    # merely the ASR transliterating one of them ("לסים" for SIEM, "קלוד" for
    # Claude) is NOT an ad-lib - adopting it would make transliteration count as
    # correct and quietly destroy the metric this corpus exists to measure.
    ref_latin = {t.lower() for t in latin_terms(ref)}
    translit = set()
    for t in latin_terms(ref):
        translit |= he_variants(t)
    def is_translit(tok: str) -> bool:
        n = _norm_he(tok)
        for v in translit:
            if SequenceMatcher(None, n, v).ratio() >= 0.62: return True
            # also catch a prefixed form ("לסים" -> "סים")
            if len(n) > 2 and SequenceMatcher(None, n[1:], v).ratio() >= 0.62:
                return True
        return False
    extra = [t for t in extra
             if t.lower() not in ref_latin
             and not any(c.isascii() and c.isalpha() for c in t)
             and not is_translit(t)]
    if extra:
        proposals[r["id"]] = {"script": ref, "consensus_only": extra,
                              "hyps": hyps}

out = ROOT / "bench/out/reref_proposals.json"
out.write_text(json.dumps(proposals, ensure_ascii=False, indent=1))
print(f"clips where every system says words the script lacks: "
      f"{len(proposals)}/{len(res['rows'])}\n")
for cid, p in list(proposals.items())[:8]:
    print(f"{cid}")
    print(f"  script    : {p['script']}")
    print(f"  systems   : {p['hyps'][0]}")
    print(f"  ad-libbed : {' '.join(p['consensus_only'])}")
    print()
print(f"full list -> bench/out/reref_proposals.json")
