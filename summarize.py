#!/usr/bin/env python3
"""summarize.py - summarise a Hebrew/English meeting transcript with local Ollama.

Meeting transcripts here are Hebrew with embedded English technical terms
(SIEM, DLP, deploy). A generic summarizer tends to transliterate those terms
into Hebrew letters, which is wrong and makes the summary unsearchable - so
the prompt explicitly forbids it. Long transcripts are chunked with overlap
so a decision or action item straddling a chunk boundary isn't cut in half,
each chunk gets a short summary, and those summaries are folded into one
final three-section summary (map-reduce) - qwen3's context window is
generous but a two-hour meeting still won't fit in one shot reliably.

Nothing leaves the machine: this only talks to a local Ollama server.

    ./summarize.py transcript.txt
    ./summarize.py transcript.txt --model qwen3:14b
    ./summarize.py --selftest
"""
import re
import argparse, json, sys, urllib.error, urllib.request
from pathlib import Path

OLLAMA_URL = "http://localhost:11434/api/generate"
DEFAULT_MODEL = "gemma4:latest"
CHUNK_WORDS = 1500     # comfortably inside qwen3's context, keeps chunk count sane
OVERLAP_WORDS = 150    # enough that a sentence isn't split across chunk halves

TERM_RULE = (
    "חוקי ברזל: כל מונח טכני באנגלית (כמו SIEM, DLP, API, deploy, Kubernetes) "
    "חייב להישאר באותיות לועזיות בדיוק כפי שהוא מופיע במקור. "
    "אסור בהחלט לתעתק אותו לעברית (לדוגמה 'אס-אי-אם' אסור, יש לכתוב 'SIEM'). "
    "שאר הטקסט צריך להיות בעברית תקנית."
)

CHUNK_PROMPT = """{rule}

זהו קטע מתוך תמלול של פגישה. סכם בקצרה (2-3 משפטים) את הנקודות המרכזיות, ההחלטות \
והמשימות שהוזכרו בקטע הזה בלבד. אל תמציא מידע שלא מופיע בטקסט.

קטע התמלול:
{chunk}
"""

FINAL_PROMPT = """{rule}

להלן סיכומי קטעים מתוך תמלול של פגישה אחת. אחד אותם לסיכום פגישה מלא, בדיוק \
בפורמט הבא (שלוש כותרות, בעברית):

## תקציר
(2-4 משפטים המתארים את מהות הפגישה)

## החלטות
(רשימת החלטות שהתקבלו בפגישה; אם לא הוזכרו החלטות, כתוב "לא צוינו החלטות")

## משימות
(רשימת משימות, עם שם האחראי אם הוזכר; אם לא הוזכרו משימות, כתוב "לא צוינו משימות")

סיכומי הקטעים:
{summaries}
"""


# qwen3:32b intermittently emits CJK tokens mid-Hebrew ("נקבע לה 更新 את הלקוח").
# It is a model artefact, not a prompt defect, but a meeting summary that silently
# contains Chinese is a correctness bug - so it is detected rather than hoped away.
CJK = re.compile(r"[\u3000-\u9fff\uff00-\uffef]")

_LATIN = re.compile(r"[A-Za-z][A-Za-z0-9+.#-]{1,}")


def term_audit(source: str, summary: str) -> tuple[list[str], list[str]]:
    """Which English terms from the transcript survived into the summary.

    Keeping technical terms in Latin script is currently a line of instruction
    in the prompt with nothing checking it, and the model does not always obey:
    on the shipped default it turned SLA into SLI - a different concept - and
    Wazuh into Vault, a real but unrelated security product. Neither is
    detectable by looking for Hebrew, because both are Latin and both look
    plausible.

    Returns (kept, missing). `missing` is advisory: a summary legitimately drops
    detail, so a term absent from it is not necessarily an error - but a term
    that vanishes while a near-miss appears is worth a reader's suspicion.
    """
    # Only acronyms (SLA, DLP) and product names (Wazuh, CrowdStrike) count.
    # Counting every Latin word would flag "the" and "we" as lost terminology.
    def technical(t: str) -> bool:
        return len(t) > 1 and (t.isupper() or (t[0].isupper() and not t.isupper()
                                               and any(c.islower() for c in t[1:])))
    src = {t for t in _LATIN.findall(source) if technical(t)}
    out = {t.lower() for t in _LATIN.findall(summary)}
    kept = sorted({t for t in src if t.lower() in out}, key=str.lower)
    missing = sorted({t for t in src if t.lower() not in out}, key=str.lower)
    return kept, missing


def near_misses(missing: list[str], summary: str) -> list[tuple[str, str]]:
    """Terms that disappeared while something one edit away appeared instead.

    This is the SLA -> SLI shape: the term is gone, and a word that is not in
    the transcript at all has taken its place.
    """
    out_terms = {t for t in _LATIN.findall(summary) if len(t) > 1}
    hits = []
    for m in missing:
        for o in out_terms:
            if o.lower() == m.lower() or abs(len(o) - len(m)) > 1:
                continue
            a, b = m.lower(), o.lower()
            if len(a) == len(b):
                if sum(x != y for x, y in zip(a, b)) == 1: hits.append((m, o)); break
            else:
                lo, hi = (a, b) if len(a) < len(b) else (b, a)
                i = 0
                while i < len(lo) and lo[i] == hi[i]: i += 1
                if lo[i:] == hi[i + 1:]: hits.append((m, o)); break
    return hits


def strip_foreign_script(text: str) -> tuple[str, int]:
    """Remove CJK characters that leak in from multilingual models.

    Returns the cleaned text and how many characters were removed, so the caller
    can surface it instead of shipping silently corrupted output.
    """
    n = len(CJK.findall(text))
    if not n:
        return text, 0
    cleaned = CJK.sub("", text)
    cleaned = re.sub(r"[ \t]{2,}", " ", cleaned)
    return cleaned, n


def chunk_text(text: str, chunk_words: int = CHUNK_WORDS,
               overlap_words: int = OVERLAP_WORDS) -> list[str]:
    """Split into overlapping word-windows. A transcript that already fits in
    one chunk is returned untouched, so the common short-meeting case skips
    chunking (and its extra model call) entirely."""
    words = text.split()
    if len(words) <= chunk_words:
        return [text]
    chunks = []
    step = chunk_words - overlap_words
    for i in range(0, len(words), step):
        chunk = words[i:i + chunk_words]
        if not chunk:
            break
        chunks.append(" ".join(chunk))
        if i + chunk_words >= len(words):
            break
    return chunks


def build_chunk_prompt(chunk: str) -> str:
    return CHUNK_PROMPT.format(rule=TERM_RULE, chunk=chunk)


def build_final_prompt(summaries: list[str]) -> str:
    joined = "\n\n".join(f"[קטע {i + 1}]\n{s}" for i, s in enumerate(summaries))
    return FINAL_PROMPT.format(rule=TERM_RULE, summaries=joined)


def call_ollama(prompt: str, model: str = DEFAULT_MODEL) -> str:
    payload = json.dumps({"model": model, "prompt": prompt, "stream": False}).encode()
    req = urllib.request.Request(OLLAMA_URL, data=payload,
                                  headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=600) as r:
            data = json.loads(r.read())
    except urllib.error.URLError as e:
        sys.exit(f"cannot reach Ollama at {OLLAMA_URL} ({e.reason}).\n"
                  f"is it running? try: ollama serve  (or: ollama list)")
    if "error" in data:
        sys.exit(f"ollama error: {data['error']}\n"
                  f"is the model pulled? try: ollama pull {model}")
    return data["response"].strip()


def summarize(text: str, model: str = DEFAULT_MODEL) -> str:
    chunks = chunk_text(text)
    if len(chunks) == 1:
        # small enough to skip straight to the final formatting pass
        partials = chunks
    else:
        partials = [call_ollama(build_chunk_prompt(c), model) for c in chunks]
    return call_ollama(build_final_prompt(partials), model)


def selftest() -> None:
    """No Ollama required: exercises chunking and prompt construction only."""
    # short transcript stays a single chunk, untouched
    short = "מילה " * 10
    assert chunk_text(short, chunk_words=1500) == [short]

    # long transcript splits with the requested overlap
    words = [f"w{i}" for i in range(100)]
    text = " ".join(words)
    chunks = chunk_text(text, chunk_words=30, overlap_words=10)
    assert len(chunks) > 1
    assert chunks[0].split()[0] == "w0"
    assert chunks[-1].split()[-1] == "w99"
    for i in range(len(chunks) - 1):
        assert chunks[i].split()[-10:] == chunks[i + 1].split()[:10], (
            f"chunk {i} and {i + 1} do not overlap correctly")

    # prompts state the English-terms rule and land in the right shape
    assert "SIEM" in TERM_RULE and "אסור" in TERM_RULE
    cp = build_chunk_prompt("צריך לעשות deploy")
    assert "צריך לעשות deploy" in cp and "SIEM" in cp
    fp = build_final_prompt(["סיכום קטע אחד", "סיכום קטע שני"])
    assert "## תקציר" in fp and "## החלטות" in fp and "## משימות" in fp
    assert "סיכום קטע אחד" in fp and "סיכום קטע שני" in fp

    k, m = term_audit("we discussed the SLA and the DLP", "דיברנו על ה-SLA")
    assert k == ["SLA"] and m == ["DLP"], (k, m)
    assert near_misses(["SLA"], "דיברנו על ה-SLI החדש") == [("SLA", "SLI")]
    assert near_misses(["SLA"], "דיברנו על משהו אחר") == []

    clean, n = strip_foreign_script("נקבע לה 更新 את הלקוח")
    assert n == 2 and "更" not in clean and "נקבע לה" in clean, (clean, n)
    same, z = strip_foreign_script("ה-DLP בארגון לא מכסה הכול")
    assert z == 0 and same == "ה-DLP בארגון לא מכסה הכול"

    print("summarize self-check passed")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("transcript", nargs="?", help="path to a transcript text file")
    ap.add_argument("--model", default=DEFAULT_MODEL, help=f"ollama model (default: {DEFAULT_MODEL})")
    ap.add_argument("--selftest", action="store_true", help="run the offline self-check and exit")
    a = ap.parse_args()

    if a.selftest:
        selftest()
        return
    if not a.transcript:
        ap.error("transcript file required (or use --selftest)")

    path = Path(a.transcript)
    if not path.exists():
        sys.exit(f"no such file: {path}")

    out = summarize(path.read_text(encoding="utf-8"), model=a.model)
    out, dropped = strip_foreign_script(out)
    kept, missing = term_audit(path.read_text(encoding="utf-8"), out)
    misses = near_misses(missing, out)
    if dropped:
        print(f"[warning: removed {dropped} stray CJK character(s) — {a.model} "
              f"leaked non-Hebrew script into the summary]", file=sys.stderr)
    print(out)
    if kept or missing:
        print(f"\n[terms kept in Latin: {len(kept)}/{len(kept)+len(missing)}"
              + (f" · absent: {', '.join(missing[:8])}" if missing else "") + "]",
              file=sys.stderr)
    for src_term, wrong in misses:
        print(f"[warning: '{src_term}' is absent while '{wrong}' appears — "
              f"the model may have altered it]", file=sys.stderr)


if __name__ == "__main__":
    main()
