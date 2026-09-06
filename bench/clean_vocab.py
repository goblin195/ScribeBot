#!/usr/bin/env python3
"""Filter harvested calendar vocabulary down to terms worth putting in a glossary.

Raw harvest is dominated by meeting-invite boilerplate - join URLs, tenant GUIDs,
locale codes, mail headers. Nobody says those out loud, and a glossary entry that
is never spoken can only ever cause a false substitution.
"""
import json, re
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HEXID = re.compile(r"^[0-9a-f]{6,}$", re.I)
HAS_DIGIT = re.compile(r"\d")
BOILER = {
    "teams","microsoft","mailto","thread","tenantid","calendar","google","zoom",
    "meet","webex","join","meeting","event","email","context","aka","ms","us",
    "en","he","il","co","www","http","https","com","org","net","gmail","outlook",
    "office","live","skype","conf","dial","pin","uuid","guid","utc","gmt",
    "invite","invitation","organizer","attendee","optional","required","accepted",
    "declined","tentative","recurrence","daily","weekly","monthly","yearly",
    "reminder","alarm","busy","free","private","public","click","here","link",
    "url","password","passcode","phone","tel","audio","video","conference",
    "room","location","online","offline","canceled","cancelled","updated","new",
    "fwd","fw","re","subject","body","html","utf","iso","rfc","vcal","ical",
    "vevent","dtstart","dtend","rrule","mailer","modality","platform","browser",
}
MIN_LEN = 3

def keep(term: str, count: int) -> bool:
    low = term.lower()
    if len(term) < MIN_LEN: return False
    if low in BOILER: return False
    if any(c in term for c in "./@_"): return False          # urls, hosts, mail
    if HEXID.match(term) and len(term) > 6: return False      # hex / guid chunks
    if HAS_DIGIT.search(term) and not term.isupper(): return False
    if term.islower() and count < 2: return False             # one-off noise
    return True

def main():
    import userdata
    src = userdata.resolve(userdata.VOCAB_NAME) or userdata.vocab()
    raw = json.loads(src.read_text())
    kept = [t for t in raw["terms"] if keep(t["term"], t["count"])]
    # Split hyphen/underscore compounds harvested from titles ("Palo-Alto"),
    # otherwise the restored text carries punctuation nobody spoke.
    words, seen = [], set()
    for t in kept:
        for part in re.split(r"[-_]", t["term"]):
            if len(part) >= MIN_LEN and part.lower() not in seen and part.lower() not in BOILER:
                seen.add(part.lower()); words.append(part)
    userdata.vocab_clean().parent.mkdir(parents=True, exist_ok=True)
    userdata.vocab_clean().write_text(
        json.dumps(words, ensure_ascii=False, indent=1))
    print(f"raw harvested : {len(raw['terms'])}")
    print(f"after filter  : {len(kept)} entries -> {len(words)} words")
    print("\ntop 35 surviving terms:")
    for t in kept[:35]:
        print(f"  {t['count']:>4}  {t['term']}")

if __name__ == "__main__":
    main()
