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
import providers
from pathlib import Path

DEFAULT_MODEL = providers.DEFAULT_OLLAMA_MODEL
CHUNK_WORDS = 1500     # comfortably inside qwen3's context, keeps chunk count sane
OVERLAP_WORDS = 150    # enough that a sentence isn't split across chunk halves

TERM_RULE = (
    "חוקי ברזל: כל מונח טכני באנגלית (כמו SIEM, DLP, API, deploy, Kubernetes) "
    "חייב להישאר באותיות לועזיות בדיוק כפי שהוא מופיע במקור. "
    "אסור בהחלט לתעתק אותו לעברית (לדוגמה 'אס-אי-אם' אסור, יש לכתוב 'SIEM'). "
    "שאר הטקסט צריך להיות בעברית תקנית."
)

# The Hebrew rule says "write the rest in proper Hebrew", which is right for a
# Hebrew meeting and wrong for every other one - an English transcript came back
# with English headings over a Hebrew body. The rule follows the transcript now.
TERM_RULE_EN = (
    "Hard rule: every technical term that appears in Latin script in the source "
    "(SIEM, DLP, API, deploy, Kubernetes) must stay in Latin script, spelled "
    "exactly as it appears. Never transliterate it into another script. Write "
    "everything else in the same language as the transcript."
)

CHUNK_PROMPT_EN = """{rule}

This is one section of a meeting transcript. In 2-3 sentences, summarise the \
main points, decisions and tasks mentioned in this section only. Do not invent \
anything that is not in the text.

Transcript section:
{chunk}
"""


def term_rule(lang: str) -> str:
    return TERM_RULE if lang == "he" else TERM_RULE_EN


CHUNK_PROMPT = """{rule}

זהו קטע מתוך תמלול של פגישה. סכם בקצרה (2-3 משפטים) את הנקודות המרכזיות, ההחלטות \
והמשימות שהוזכרו בקטע הזה בלבד. אל תמציא מידע שלא מופיע בטקסט.

קטע התמלול:
{chunk}
"""

TEMPLATES_FILE = Path(__file__).resolve().parent / "templates.json"
# Where the app writes templates the user made. Read-only from here.
USER_TEMPLATES_FILE = (Path.home() / "Library/Application Support/Scribebot"
                       / "templates.user.json")
DEFAULT_TEMPLATE = "standard"


def load_templates() -> dict:
    """Every template by id, built-ins first, user templates layered on top.

    Both this file and the app read templates.json. The section list used to be
    written out twice - here and in Transcript.swift, which parsed the output by
    looking for three specific Hebrew headings - so adding a section in one
    place silently produced a summary the other could not read.
    """
    out = {}
    for path in (TEMPLATES_FILE, USER_TEMPLATES_FILE):
        if not path.exists():
            continue
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
        except (json.JSONDecodeError, OSError) as e:
            # A broken user file must not take the built-ins down with it.
            print(f"[warning: ignoring {path.name}: {e}]", file=sys.stderr)
            continue
        for t in data.get("templates", []):
            if t.get("id") and t.get("sections"):
                out[t["id"]] = t
    return out


def heading(section: dict, lang: str) -> str:
    """A section's heading in the language the summary is being written in."""
    return section.get(lang) or section.get("en") or ""


FINAL_PROMPT = """{rule}

{intro}

{sections}

{closing}

{label}
{summaries}
"""

_HE = {
    "intro": "להלן סיכומי קטעים מתוך תמלול של פגישה אחת. אחד אותם לסיכום פגישה "
             "מלא, בדיוק בפורמט הבא:",
    "closing": "אל תוסיף כותרות שאינן מופיעות למעלה, ואל תמציא מידע שלא נאמר.",
    "label": "סיכומי הקטעים:",
    "empty": 'אם לא הוזכר דבר, כתוב "לא צוין"',
}
_EN = {
    "intro": "Below are summaries of sections of one meeting transcript. Merge "
             "them into a single meeting summary, in exactly this format:",
    "closing": "Do not add headings that are not listed above, and do not "
               "invent anything that was not said.",
    "label": "Section summaries:",
    "empty": 'if nothing was mentioned, write "not stated"',
}


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


def build_chunk_prompt(chunk: str, lang: str = "he") -> str:
    template = CHUNK_PROMPT if lang == "he" else CHUNK_PROMPT_EN
    return template.format(rule=term_rule(lang), chunk=chunk)


def build_final_prompt(summaries: list[str], template: dict | None = None,
                       lang: str = "he", instructions: str = "") -> str:
    if template is None:
        template = load_templates().get(DEFAULT_TEMPLATE)
    words = _HE if lang == "he" else _EN
    body = "\n\n".join(
        f"## {heading(s, lang)}\n({s.get('guidance', '')}; {words['empty']})"
        for s in template["sections"])
    joined = "\n\n".join(f"[{i + 1}]\n{s}" for i, s in enumerate(summaries))
    closing = words["closing"]
    if instructions.strip():
        # The user's own words about style go last, where they are least
        # likely to be crowded out by the section list above them.
        closing += "\n\n" + instructions.strip()
    return FINAL_PROMPT.format(rule=term_rule(lang), intro=words["intro"],
                               sections=body, closing=closing,
                               label=words["label"], summaries=joined)


def call_ollama(prompt: str, model: str = DEFAULT_MODEL,
                provider: str = providers.DEFAULT_PROVIDER) -> str:
    """One prompt through whichever engine was chosen.

    Kept under the old name because it is the only model call in the project
    and every caller already says `call_ollama`; `providers` decides what that
    actually means now.
    """
    try:
        return providers.run(prompt, provider, model)
    except RuntimeError as e:
        sys.exit(str(e))


_HEBREW_RANGE = re.compile(r"[\u0590-\u05FF]")


def transcript_language(text: str) -> str:
    """"he" when the transcript is substantially Hebrew, else "en".

    The summary has to be written in the language of the meeting, and its
    headings with it. This only has to separate Hebrew from everything else -
    Hebrew is the language with translated headings in templates.json.
    """
    hebrew = len(_HEBREW_RANGE.findall(text))
    letters = sum(1 for c in text if c.isalpha())
    return "he" if letters and hebrew / letters > 0.2 else "en"


def summarize(text: str, model: str = DEFAULT_MODEL,
              template: dict | None = None, lang: str | None = None,
              instructions: str = "",
              provider: str = providers.DEFAULT_PROVIDER) -> str:
    lang = lang or transcript_language(text)
    if template is None:
        template = load_templates().get(DEFAULT_TEMPLATE)
    chunks = chunk_text(text)
    if len(chunks) == 1:
        # small enough to skip straight to the final formatting pass
        partials = chunks
    else:
        partials = [call_ollama(build_chunk_prompt(c, lang), model, provider)
                    for c in chunks]
    return call_ollama(build_final_prompt(partials, template, lang, instructions),
                       model, provider)


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

    # --- templates -----------------------------------------------------
    ts = load_templates()
    assert DEFAULT_TEMPLATE in ts, "the default template must always exist"
    for tid, t in ts.items():
        assert t.get("name"), f"{tid} has no name"
        assert t.get("sections"), f"{tid} has no sections"
        for s in t["sections"]:
            # Every section must be renderable in both languages, or a Hebrew
            # meeting silently gets English headings in the middle of it.
            assert s.get("en") and s.get("he"), f"{tid} section missing a heading"
            assert heading(s, "he") == s["he"] and heading(s, "en") == s["en"]
    # the nine the UI offers
    for tid in ("standard", "one-on-one", "standup", "interview", "client-call",
                "lecture", "session", "consultation", "investor-meeting"):
        assert tid in ts, f"the app offers {tid} but templates.json does not"

    # a template's own headings, in the language of the meeting
    standup = ts["standup"]
    he = build_final_prompt(["x"], standup, "he")
    en = build_final_prompt(["x"], standup, "en")
    assert "## חסמים" in he and "## Blockers" in en
    assert "## Blockers" not in he and "## חסמים" not in en
    # and no leakage from a different template
    assert "## תקציר" not in he, "standup must not carry Standard's sections"

    # the user's own styling note reaches the prompt, and only when given
    assert "keep it to three bullets" in build_final_prompt(
        ["x"], ts["standard"], "en", "keep it to three bullets")
    assert "\n\n\n" not in build_final_prompt(["x"], ts["standard"], "en", "   ")

    # an English meeting must not be told to write Hebrew
    assert "בעברית" in build_final_prompt(["x"], ts["standard"], "he")
    assert "בעברית" not in build_final_prompt(["x"], ts["standard"], "en")
    assert "same language as the transcript" in build_chunk_prompt("x", "en")
    assert "SIEM" in term_rule("he") and "SIEM" in term_rule("en")

    assert transcript_language("שלום, מה מצב ה-SSE?") == "he"
    assert transcript_language("Let's review the SSE rollout today.") == "en"
    assert transcript_language("") == "en"

    # An unreadable user file is ignored, not fatal.
    import tempfile as _tf
    with _tf.TemporaryDirectory() as d:
        bad = Path(d) / "templates.user.json"
        bad.write_text("{not json", encoding="utf-8")
        global USER_TEMPLATES_FILE
        keep, USER_TEMPLATES_FILE = USER_TEMPLATES_FILE, bad
        try:
            assert DEFAULT_TEMPLATE in load_templates()
        finally:
            USER_TEMPLATES_FILE = keep

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
    ap.add_argument("--model", default=None,
                    help="model name; defaults to the provider's own "
                         f"(ollama: {DEFAULT_MODEL})")
    ap.add_argument("--template", default=DEFAULT_TEMPLATE, metavar="ID",
                    help=f"summary template (default: {DEFAULT_TEMPLATE})")
    ap.add_argument("--provider", default=providers.DEFAULT_PROVIDER,
                    choices=sorted(providers.PROVIDERS),
                    help=f"summary engine (default: {providers.DEFAULT_PROVIDER})")
    ap.add_argument("--list-providers", action="store_true",
                    help="print installed providers and Ollama models as JSON")
    ap.add_argument("--instructions", default="", metavar="TEXT",
                    help="extra guidance on how the summary should be written")
    ap.add_argument("--list-templates", action="store_true",
                    help="print the available templates as JSON and exit")
    ap.add_argument("--selftest", action="store_true", help="run the offline self-check and exit")
    a = ap.parse_args()

    if a.selftest:
        selftest()
        return

    if a.list_providers:
        print(json.dumps(providers.status(), indent=2))
        return

    templates = load_templates()
    if a.list_templates:
        print(json.dumps({"templates": list(templates.values())},
                         ensure_ascii=False, indent=2))
        return
    if a.template not in templates:
        sys.exit(f"no such template: {a.template}\n"
                 f"available: {', '.join(sorted(templates))}")
    if not a.transcript:
        ap.error("transcript file required (or use --selftest)")

    path = Path(a.transcript)
    if not path.exists():
        sys.exit(f"no such file: {path}")

    out = summarize(path.read_text(encoding="utf-8"),
                    template=templates[a.template], instructions=a.instructions,
                    provider=a.provider,
                    model=a.model if a.model is not None
                          else providers.default_model(a.provider))
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
