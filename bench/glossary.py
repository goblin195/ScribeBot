#!/usr/bin/env python3
"""Restore Latin-script technical terms that the ASR transliterated into Hebrew.

The decoder is left alone - it transcribes Hebrew at full accuracy, and this
pass repairs the terms afterwards. Deterministic, so it cannot hallucinate the
way prompt-biasing did, and it degrades to a no-op when nothing matches.

Matching is phonetic: a term is romanised into the Hebrew letters a speaker
would produce for it, then fuzzy-matched against the hypothesis. That means a
term the model spells slightly differently than expected still gets repaired.
"""
import json, re, unicodedata
from difflib import SequenceMatcher
from pathlib import Path

# How each English sound tends to land in Hebrew transliteration.
# Multi-letter graphemes first - order matters.
_ROM = [
    ("tion","שן"),("sion","שן"),("ough","או"),("ch","צ'"),("sh","ש"),("th","ת'"),
    ("ph","פ"),("ck","ק"),("qu","קוו"),("oo","ו"),("ee","י"),("ea","י"),("ou","או"),
    ("ai","יי"),("ay","יי"),("ei","יי"),("au","או"),("aw","או"),("oa","ו"),
    ("a","א"),("b","ב"),("c","ק"),("d","ד"),("e","י"),("f","פ"),("g","ג"),
    ("h","ה"),("i","י"),("j","ג'"),("k","ק"),("l","ל"),("m","מ"),("n","נ"),
    ("o","ו"),("p","פ"),("q","ק"),("r","ר"),("s","ס"),("t","ט"),("u","ו"),
    ("v","ו"),("w","ו"),("x","קס"),("y","י"),("z","ז"),
]
_FINALS = str.maketrans("םןץףך", "מנצפכ")
_NIQQUD = re.compile(r"[֑-ׇ]")
# Hebrew attaches these as single-letter proclitics: ה ו ב כ ל מ ש
_PREFIX1 = "הובכלמש"
_PREFIX2 = ("ולה", "שה", "וה", "לה", "בה", "כה", "מה", "ול", "וב", "ומ")

def strip_prefix(word: str):
    """Split a leading Hebrew proclitic off a word. Returns (prefix, rest)."""
    for p in _PREFIX2:
        if word.startswith(p) and len(word) - len(p) >= 2:
            return p, word[len(p):]
    if word and word[0] in _PREFIX1 and len(word) >= 3:
        return word[0], word[1:]
    return "", word
_LETTER_NAMES = {  # how acronyms get spelled out letter-by-letter in Hebrew
    "a":"איי","b":"בי","c":"סי","d":"די","e":"אי","f":"אף","g":"ג'י","h":"אייץ",
    "i":"איי","j":"ג'יי","k":"קיי","l":"אל","m":"אם","n":"אן","o":"או","p":"פי",
    "q":"קיו","r":"אר","s":"אס","t":"טי","u":"יו","v":"וי","w":"דאבליו",
    "x":"אקס","y":"וואי","z":"זד",
}

# Closed-class Hebrew. Substituting over any of these can invert or destroy the
# meaning of a sentence, which is strictly worse than leaving a term
# transliterated - the reader gets no signal that anything went wrong.
PROTECTED = {
    "לא","לי","לו","לה","לך","לנו","להם","וגם","גם","את","של","זה","זאת","הוא",
    "היא","הם","הן","אני","אתה","את","אנחנו","אתם","יש","אין","כן","או","אם",
    "כי","עם","על","אל","מה","מי","למה","איך","כל","רק","עוד","כבר","אבל","אז",
    "מאוד","יותר","פחות","הכי","שלי","שלך","שלו","שלה","שלנו","היה","יהיה",
    # Ordinary words that fuzzy-matched technical terms and destroyed meaning:
    # "כולל" (including) -> "כ-pull", "סיימה" (she finished) -> "SIEM".
    "כולל","כוללת","סיים","סיימה","סיימו","סיימנו","שאול","מאור","דודי","נאור",
    "אמר","אמרה","אמרו","מים","ים","בית","הבית","בוקר","ערב","לילה","יום","שנה",
    "חודש","שבוע","שעה","דקה","כסף","שקל","שקלים","אלף","מאה","מיליון","הכל",
    "הכול","עוד","אולי","בבקשה","תודה","שלום","בסדר","נכון","טוב","רע","גדול",
    "קטן","חדש","ישן","קשה","קל","מהר","לאט","כאן","שם","היום","מחר","אתמול",
}
# (normalized below, once _norm_he exists - final letters fold, so the raw
#  spellings above would never match a normalized hypothesis token)

# Invisible bidi/formatting controls leak in from RTL text and break search,
# diffing and exact-match evaluation.
_BIDI = re.compile(r"[\u200e\u200f\u202a-\u202e\u2066-\u2069]")

def _norm_he(s: str) -> str:
    s = _BIDI.sub("", unicodedata.normalize("NFKC", s))
    s = _NIQQUD.sub("", s)
    return s.translate(_FINALS)

PROTECTED = {_norm_he(w) for w in PROTECTED}

def romanize(term: str) -> str:
    t = term.lower()
    # soft c: "CISO" is spoken סיסו, not קיסו. Without this it loses to SSO.
    t = re.sub(r"c(?=[iey])", "s", t)
    out = []
    i = 0
    while i < len(t):
        for src, dst in _ROM:
            if t.startswith(src, i):
                out.append(dst); i += len(src); break
        else:
            i += 1
    return _norm_he("".join(out))

def spell_out(term: str) -> str:
    """ASR often renders an acronym as its Hebrew letter names: DLP -> די אל פי."""
    return _norm_he("".join(_LETTER_NAMES.get(c, "") for c in term.lower()))

# A romanized form shorter than this matches almost any Hebrew word: "VM" -> ומ,
# "OCR" -> וקר, "IAM" -> יאמ. Those short forms are what turned "בוקר טוב" into
# "ב-OCR טוב". Anything below the floor is dropped rather than guessed at.
MIN_VARIANT = 4

def variants(term: str):
    v = {romanize(term)}
    if term.isupper() and 2 <= len(term) <= 5:
        # Acronyms surface two ways: read as a word (SIEM -> סים) and spelled
        # out letter by letter (DLP -> די אל פי). Keep both, then length-filter.
        v.add(spell_out(term))
    return {x for x in v if len(x) >= MIN_VARIANT}

# A Latin-token "correction" pass once lived here: it rewrote a token that sat
# one edit from exactly one curated term, so "SIM" became "SIEM". It was removed
# rather than tuned. It bought +2.1 points of term preservation on a jargon-dense
# benchmark while destroying ordinary English at a rate of roughly 1% of
# lowercase and 3% of uppercase dictionary words - "please act on this at once"
# came back as "please APT OS this APT once", and a real SIM card became a SIEM.
# The benchmark could not see that cost because every one of its clips is
# jargon-dense; english_control() in negative_control.py now can.


class Restorer:
    def __init__(self, terms, threshold: float = 0.90, aliases: dict | None = None,
                 exact_only=None):
        """`aliases` maps a term to Hebrew spellings observed in real transcripts.
        Romanization cannot safely reach every name - "CrowdStrike" only matches
        "קראודסטרייק" at a threshold low enough to corrupt ordinary Hebrew - so
        known spellings are supplied exactly instead of guessed at."""
        self.threshold = threshold
        self.index = []   # (variant, canonical_term, word_span_hint)
        aliases = aliases or {}
        exact_only = set(exact_only or ())
        for t in terms:
            # A known spelling needs no fuzziness - and fuzziness on names is
            # actively harmful, because harvested names collide with ordinary
            # Hebrew ("Amir"/אמר, "Pini"/לפני, "דוקר"/בוקר).
            for a in aliases.get(t, []):
                self.index.append((_norm_he(a), t, max(1, round(len(a) / 3)), True))
            is_exact = t in exact_only
            for v in variants(t):
                self.index.append((v, t, max(1, round(len(v) / 3)), is_exact))
        # longest variants first so "OpenAI" wins over "AI"
        self.index.sort(key=lambda x: -len(x[0]))
        self._terms = list(terms)
        self._known_lower = {t.lower() for t in self._terms}

    def restore(self, text: str) -> str:
        """Collect every candidate match, then take the best non-overlapping set.

        First-match-wins is wrong here: a partial hit on a long term (DLP over
        two of its three words) leaves the remainder free to false-match a
        shorter term, inventing words the speaker never said.
        """
        # Bidi marks are stripped for MATCHING only. Removing them from the
        # output silently rewrites the user's text - a calendar entry written
        # "\u200f\u200fבוטלה:" came back without its marks, which is a mutation
        # nobody asked for and nothing disclosed.
        words = text.split()
        norm = [_norm_he(_BIDI.sub("", w).strip(".,!?;:")) for w in words]
        cands = []
        for variant, term, span, needs_exact in self.index:
            for n in range(1, min(5, len(words)) + 1):
                for i in range(len(words) - n + 1):
                    span_words = norm[i:i + n]
                    joined = "".join(span_words)
                    if len(joined) < 3: continue
                    pre, stripped = strip_prefix(joined)
                    # A span covering closed-class Hebrew does not get blocked
                    # outright - a spelled-out acronym legitimately swallows
                    # words like "אל". It has to clear a much higher bar, so an
                    # approximate match can never overwrite meaning-bearing
                    # words the way "לא" -> "SLA" inverted a sentence.
                    touches_protected = any(
                        w in PROTECTED or strip_prefix(w)[1] in PROTECTED
                        for w in span_words)
                    r_bare = SequenceMatcher(None, joined, variant).ratio()
                    r_str = SequenceMatcher(None, stripped, variant).ratio() if stripped else 0.0
                    r = max(r_bare, r_str)
                    if needs_exact:
                        # exact spelling, bare or behind one proclitic
                        if joined != variant and stripped != variant: continue
                    else:
                        need = 0.95 if touches_protected else self.threshold
                        if r < need: continue
                    cands.append((r, n, i, term, pre if r_str > r_bare else ""))
        # best ratio first; on a tie prefer the longer span, so DLP beats its own fragment
        cands.sort(key=lambda c: (-c[0], -c[1]))
        used = [False] * len(words)
        out = list(words)
        for r, n, i, term, pre in cands:
            if any(used[i:i + n]): continue
            # keep whatever punctuation closed the span - dropping it destroys
            # sentence boundaries, which downstream chunking depends on
            tail = ""
            last = words[i + n - 1]
            while last and last[-1] in ".,!?;:\u05f4\"'" :
                tail = last[-1] + tail
                last = last[:-1]
            out[i] = ((pre + "-" + term) if pre else term) + tail
            for j in range(i + 1, i + n): out[j] = ""
            for j in range(i, i + n): used[j] = True

        # A restored term can leave a Latin fragment of itself behind
        # ("ProxySG" followed by a stray "SG"). Drop the redundant tail.
        res = [w for w in out if w]
        cleaned = []
        for w in res:
            if cleaned:
                prev = cleaned[-1].rstrip(".,!?;:").lower()
                cur = w.rstrip(".,!?;:").lower()
                if cur and len(cur) < len(prev) and prev.endswith(cur):
                    continue
            cleaned.append(w)
        return " ".join(cleaned)

def load_terms(path: Path):
    return json.loads(path.read_text())

if __name__ == "__main__":
    # Two regimes, deliberately tested separately.
    #
    # Romanization alone is fuzzy and is held to a high threshold, because a
    # loose match corrupts ordinary Hebrew ("בוקר טוב" -> "ב-OCR טוב"). That
    # threshold puts some names out of reach: "קלוד" scores 0.80 against the
    # romanized "קלאודי" and is correctly refused.
    #
    # Known spellings are supplied as aliases and matched exactly, which is how
    # those names are actually restored in production.
    bare = Restorer(["DLP", "XDR", "SIEM", "SASE", "MCP", "Claude", "Kubernetes"])
    # Spelled-out acronyms still reach through the fuzzy path at 0.90.
    for src, want in [("מדיניות הדי אל פי בארגון", "DLP")]:
        got = bare.restore(src)
        assert want in got, f"{src!r} -> {got!r} (wanted {want})"

    # Out of reach of fuzzy matching at the shipped 0.90 bar. Asserted so that a
    # future loosening - which is what corrupted ordinary Hebrew before - is
    # caught here rather than in production.
    assert "Claude" not in bare.restore("המודל של קלוד נותן תוצאות")
    assert "SIEM" not in bare.restore("התראה לסים")

    # Known spellings are matched exactly, which is how these are restored in
    # production. In a shipped product this table grows from user corrections,
    # not from reading a benchmark.
    aliased = Restorer(["Claude", "CrowdStrike", "Docker", "SIEM"],
                       aliases={"Claude": ["קלוד"], "CrowdStrike": ["קראודסטרייק"],
                                "Docker": ["דוקר"], "SIEM": ["סים"]},
                       exact_only={"Claude", "CrowdStrike", "Docker", "SIEM"})
    assert "Claude" in aliased.restore("המודל של קלוד נותן תוצאות")
    assert "CrowdStrike" in aliased.restore("עובדים עם קראודסטרייק")
    assert "SIEM" in aliased.restore("התראה לסים")

    # meaning-bearing Hebrew is never overwritten
    keep = Restorer(["SLA", "CLI", "VM", "MCP"])
    for sent in ["ה-performance לא מספיק טוב", "תשלח לי את הקובץ",
                 "פאלו אלטו וגם קראודסטרייק"]:
        assert keep.restore(sent) == sent, f"corrupted: {keep.restore(sent)!r}"

    print("glossary self-check passed")
