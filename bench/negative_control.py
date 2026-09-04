#!/usr/bin/env python3
"""Negative control: the SHIPPED glossary must not touch ordinary Hebrew.

This file previously tested `Restorer(terms.json)` - curated terms only - while
production builds a restorer over curated terms PLUS ~1200 harvested contact
names. The dangerous component was the one not under test, and the check passed
18/18 while the shipped configuration corrupted ordinary speech.

It now loads exactly what `scribebot.load_glossary()` loads, and the sentences
below include ones written by an adversarial reviewer rather than by the author
of the code, plus deliberate homophones of harvested names ("שאול" is both a
name and "borrowed"; "מאור" is both a name and "light of").
"""
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

# Everyday and business Hebrew containing no technical terms at all.
CLEAN = [
    "אני הולך הביתה עכשיו וגם אחי בא",
    "הבית שלנו נמצא ברחוב הרצל",
    "תשלח לי את הקובץ בבקשה",
    "אני רוצה מים קרים",
    "מה שלומך היום",
    "בוא נלך לים בסוף השבוע",
    "בוקר טוב, אני רוצה להתחיל את הפגישה",
    "שילמנו שלושים אלף שקלים",
    "נרשמו מיליון משתמשים",
    "הוא אמר לי שהוא לא מספיק זמן",
    "אני שמח להיות כאן היום ולדבר איתכם",
    "אפשר בבקשה לחזור על מה שאמרת? לא הצלחתי לשמוע",
    "תודה רבה על הזמן שהקדשתם לנו",
    "הלקוח ביקש שנציג את ההצעה עד סוף החודש",
    "צריך לתאם פגישה עם הצוות המשפטי לפני החתימה",
    "היעדים שהצבנו לשנה הזאת שאפתניים אבל אפשריים",
    "יש לנו עיכוב באספקה ואנחנו צריכים לעדכן את הלקוח",
    "נראה לי שכדאי שנמשיך את השיחה הזאת בשבוע הבא",
]

# Written by an adversarial reviewer, not by the author of the restoration code.
ADVERSARIAL = [
    "אמיר סיפר לי על הטיול שלו בהודו",
    "פיני מהמוסך אמר שהאוטו יהיה מוכן מחר",
    "המחיר הוא אלף שמונה מאות שקלים כולל",
    "היא סיימה את הקורס בהצטיינות יתרה",
    "הכסף הזה שאול מהבנק ולא שלנו",
    "יש מאור פנים אצל האנשים כאן",
    "דודי נסע לחוץ לארץ בשבוע שעבר",
    "הוא נאור ופתוח לרעיונות חדשים",
    "זה כולל הכל, אין תוספות",
    "ההצגה מתחילה בשמונה בערב בתיאטרון",
    "קניתי ירקות ופירות בשוק הבוקר",
    "הילדים חוזרים מבית הספר בארבע",
    "הרכבת לתל אביב יוצאת מהרציף השני",
    "אנחנו גרים כאן כבר שתים עשרה שנה",
]

# Ordinary English. Meetings here are bilingual, so English prose passes through
# the restorer constantly and must come out untouched.
ENGLISH = [
    "he said the cat is out of the bag",
    "please act on this at once",
    "the base is secure",
    "put it in my bag",
    "I will send the file now",
    "we need to run the test today",
    "open the app and log in",
    "the new API is good",
    "let us talk about the roadmap",
]

# Latin tokens that are real words and must not be rewritten into acronyms.
LATIN_TRAPS = [
    "צריך להחליף SIM בטלפון",
    "החברה נקראת SALE ולא משהו אחר",
    "קניתי מכונית מסוג AUDI",
    "שלחתי מייל ל-Dana",
]

ALL = CLEAN + ADVERSARIAL + ENGLISH + LATIN_TRAPS


def main() -> int:
    from scribebot import load_glossary          # the SHIPPED configuration
    restorer, n_terms = load_glossary()
    bad = [(s, restorer.restore(s)) for s in ALL if restorer.restore(s) != s]
    for src, got in bad:
        print(f"CORRUPTED: {src}\n       ->  {got}")
    ok = len(ALL) - len(bad)
    print(f"\nnegative control ({n_terms} shipped glossary terms): "
          f"{ok}/{len(ALL)} sentences untouched")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
