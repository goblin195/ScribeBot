#!/usr/bin/env python3
"""Score ASR hypotheses against the he-en corpus.

Two metrics that matter here:
  TPR  term preservation rate - of the Latin-script terms in the reference,
       how many survive in the hypothesis. This is the primary KPI.
  WER  word error rate over the whole utterance, so we catch a system that
       wins TPR by mangling the Hebrew around it.
"""
import json, re, subprocess, sys, unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
CORPUS = ROOT / "audio" / "he-en"
NIQQUD = re.compile(r"[֑-ׇ]")
PUNCT = re.compile(r"[^\w֐-׿]+", re.UNICODE)
LATIN_TERM = re.compile(r"[A-Za-z][A-Za-z0-9]*")

def norm(s: str) -> str:
    s = unicodedata.normalize("NFKC", s)
    s = NIQQUD.sub("", s)
    s = PUNCT.sub(" ", s)          # '-' becomes a separator: "ה-DLP" -> "ה DLP"
    return " ".join(s.split())

def tokens(s: str): return norm(s).split()

def wer(ref: str, hyp: str) -> float:
    r, h = tokens(ref), tokens(hyp)
    if not r: return 0.0
    # Levenshtein over tokens
    prev = list(range(len(h) + 1))
    for i, rt in enumerate(r, 1):
        cur = [i]
        for j, ht in enumerate(h, 1):
            cur.append(min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (rt != ht)))
        prev = cur
    return prev[-1] / len(r)

def terms(s: str):
    """Latin-script terms in the reference, lowercased, deduped, order kept."""
    seen, out = set(), []
    for m in LATIN_TERM.findall(s):
        k = m.lower()
        if k not in seen:
            seen.add(k); out.append(m)
    return out

def kept(ref: str, hyp: str):
    hyp_l = norm(hyp).lower()
    hyp_terms = {t.lower() for t in LATIN_TERM.findall(hyp_l)}
    want = terms(ref)
    got = [t for t in want if t.lower() in hyp_terms]
    return got, want

def transcribe(model: Path, wav: Path, prompt: str | None = None) -> str:
    """Dispatch on model kind: a .bin is whisper.cpp, a directory is WhisperKit
    (which is how Tape's own CoreML models are packaged)."""
    if model.is_dir():
        cmd = ["whisperkit-cli", "transcribe", "--model-path", str(model),
               "--audio-path", str(wav), "--language", "he"]
        r = subprocess.run(cmd, capture_output=True, text=True)
        # When stdout is not a TTY the CLI prints only the transcript;
        # interactively it prefixes a "Transcription of <file>:" banner.
        out = r.stdout
        marker = f"Transcription of {wav.name}:"
        if marker in out:
            out = out.split(marker, 1)[1]
        return " ".join(out.split())
    cmd = ["whisper-cli", "-m", str(model), "-f", str(wav), "-l", "he", "-nt", "-np"]
    if prompt: cmd += ["--prompt", prompt]
    r = subprocess.run(cmd, capture_output=True, text=True)
    return " ".join(r.stdout.split())

def find_wav(clip_id: str) -> Path | None:
    cat = clip_id.rsplit("_", 1)[0]
    p = CORPUS / cat / f"{clip_id}.wav"
    return p if p.exists() else None

def main():
    data = json.loads((CORPUS / "transcripts.json").read_text())
    systems = {}
    for arg in sys.argv[1:]:
        name, path = arg.split("=", 1)
        systems[name] = Path(path)

    rows, agg = [], {}
    for cid, rec in sorted(data.items()):
        wav = find_wav(cid)
        if not wav: continue
        ref = rec["prompt"]
        hyps = {"baseline(asr_heb)": rec.get("asr_heb", "")}
        for name, model in systems.items():
            hyps[name] = transcribe(model, wav)
        row = {"id": cid, "ref": ref, "terms": terms(ref), "hyp": {}}
        for name, hyp in hyps.items():
            got, want = kept(ref, hyp)
            row["hyp"][name] = {"text": hyp, "wer": wer(ref, hyp),
                                "kept": got, "n_kept": len(got), "n_terms": len(want)}
            a = agg.setdefault(name, {"kept": 0, "terms": 0, "wer": [], "n": 0})
            a["kept"] += len(got); a["terms"] += len(want)
            a["wer"].append(wer(ref, hyp)); a["n"] += 1
        rows.append(row)

    out = {"rows": rows, "summary": {
        n: {"tpr": (a["kept"] / a["terms"] if a["terms"] else 0.0),
            "kept": a["kept"], "terms": a["terms"],
            "wer": sum(a["wer"]) / len(a["wer"]), "clips": a["n"]}
        for n, a in agg.items()}}
    (ROOT / "bench" / "out" / "results.json").write_text(
        json.dumps(out, ensure_ascii=False, indent=2))

    print(f"{'system':<24} {'TPR':>8} {'terms':>10} {'WER':>8} {'clips':>6}")
    print("-" * 60)
    for n, s in sorted(out["summary"].items(), key=lambda kv: -kv[1]["tpr"]):
        print(f"{n:<24} {s['tpr']*100:>7.1f}% {s['kept']:>4}/{s['terms']:<5} "
              f"{s['wer']*100:>7.1f}% {s['clips']:>6}")

if __name__ == "__main__":
    main()
