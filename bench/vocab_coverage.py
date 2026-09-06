#!/usr/bin/env python3
"""Does the user's real calendar/contacts vocabulary cover the terms we need?

This is the production hypothesis under test. Glossary restoration is worth +36
points of term preservation, but only for terms the glossary contains. If the
vocabulary has to be hand-curated, the feature does not scale. If it falls out
of the user's own calendar, it does.
"""
import json, re, sys
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
LAT = re.compile(r"[A-Za-z][A-Za-z0-9]*")

sys.path.insert(0, str(ROOT))
import userdata
vocab_path = userdata.resolve(userdata.VOCAB_NAME) or userdata.vocab()
if not vocab_path.exists():
    sys.exit(f"no vocabulary index at {userdata.vocab()} - "
             "run the extractor, or ./userdata.py --migrate")

vocab = json.loads(vocab_path.read_text())
harvested = {t["term"] for t in vocab["terms"]}
harvested_l = {t.lower() for t in harvested}

data = json.loads((ROOT / "audio/he-en/transcripts.json").read_text())
needed = {}
for cid, rec in data.items():
    for m in LAT.findall(rec["prompt"]):
        needed.setdefault(m.lower(), m)

covered = {v for k, v in needed.items() if k in harvested_l}
missing = {v for k, v in needed.items() if k not in harvested_l}

print(f"harvested from calendar+contacts : {len(harvested)} terms")
print(f"terms the benchmark needs        : {len(needed)}")
print(f"covered by harvested vocabulary  : {len(covered)}  "
      f"({100*len(covered)/len(needed):.0f}%)")
print()
print("COVERED :", ", ".join(sorted(covered, key=str.lower)) or "(none)")
print()
print("MISSING :", ", ".join(sorted(missing, key=str.lower)) or "(none)")
print()
print("Top harvested terms by frequency:")
for t in vocab["terms"][:30]:
    print(f"  {t['count']:>4}  {t['term']}")
