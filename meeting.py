#!/usr/bin/env python3
"""Link a recording to the calendar meeting it belongs to.

Two things fall out of knowing which meeting a tape is: the transcript gets a
title and a date instead of a filename, and the attendee list gives the speaker
names. Diarization can tell voices apart but can never name them - the calendar
can, and it is already on the machine.
"""
import json, re, sys
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent
import userdata
# Not ROOT/"bench" any more: a calendar export inside the repo is what
# got 850 attendee names published. userdata.py owns the location.
MEETINGS = userdata.resolve(userdata.MEETINGS_NAME) or userdata.meetings()
# A recording rarely starts exactly on the hour - people join late and start
# recording once the conversation is under way.
SLACK = timedelta(minutes=15)


# Some invitations carry the address inside the display name
# ("אדם אושר חזן <adamh@example.com>"), and a few are just a bare address.
_EMAIL_IN_NAME = re.compile(r"\s*<[^>]*>\s*")
_BARE_EMAIL = re.compile(r"^[^@\s]+@[^@\s]+$")

def clean_name(raw: str) -> str | None:
    n = _EMAIL_IN_NAME.sub("", raw).strip().strip('"')
    if not n or _BARE_EMAIL.match(n):
        return None
    return n


@dataclass
class Meeting:
    title: str
    start: datetime
    end: datetime
    attendees: list[str]
    organizer: str | None

    @property
    def speakers(self) -> list[str]:
        names, seen = [], set()
        for raw in ([self.organizer] if self.organizer else []) + self.attendees:
            n = clean_name(raw or "")
            if n and n not in seen:
                seen.add(n); names.append(n)
        return names


def _parse(ts: str) -> datetime:
    d = datetime.fromisoformat(ts)
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


def load(path: Path = MEETINGS) -> list[Meeting]:
    if not path.exists():
        return []
    out = []
    for m in json.loads(path.read_text()):
        try:
            out.append(Meeting(m["title"], _parse(m["start"]), _parse(m["end"]),
                               m.get("attendees") or [], m.get("organizer")))
        except (KeyError, ValueError):
            continue
    return out


def find(at: datetime, meetings: list[Meeting]) -> Meeting | None:
    """The meeting a recording started during.

    Overlapping invitations are common, so ties break toward the one with the
    most named attendees - a real meeting beats a personal block.
    """
    if at.tzinfo is None:
        at = at.replace(tzinfo=timezone.utc)
    hits = [m for m in meetings if m.start - SLACK <= at <= m.end + SLACK]
    if not hits:
        return None
    return max(hits, key=lambda m: (len(m.attendees), -abs((m.start - at).total_seconds())))


def selftest() -> None:
    base = datetime(2026, 3, 8, 13, 0, tzinfo=timezone.utc)
    ms = [
        Meeting("solo block", base, base + timedelta(hours=2), [], None),
        Meeting("real meeting", base, base + timedelta(hours=1),
                ["Amir", "Orna"], "Gavriel"),
    ]
    # overlapping invitations: the one with attendees wins
    assert find(base + timedelta(minutes=10), ms).title == "real meeting"
    # started a few minutes before the invite - still that meeting
    assert find(base - timedelta(minutes=5), ms) is not None
    # far outside any invite
    assert find(base + timedelta(hours=9), ms) is None
    # organizer is a speaker, and is not duplicated
    assert ms[1].speakers == ["Gavriel", "Amir", "Orna"]
    assert Meeting("x", base, base, ["Gavriel"], "Gavriel").speakers == ["Gavriel"]
    # an address embedded in the display name is stripped
    dirty = Meeting("x", base, base, ["אדם חזן <a@b.co.il>", "x@y.com"], None)
    assert dirty.speakers == ["אדם חזן"], dirty.speakers
    print("meeting self-check passed")


def main() -> None:
    if "--selftest" in sys.argv:
        selftest(); return
    at = (datetime.fromisoformat(sys.argv[1]) if len(sys.argv) > 1
          else datetime.now().astimezone())
    ms = load()
    if not ms:
        sys.exit(f"no calendar index at {userdata.meetings()}\n"
                 "run the calendar scanner, or ./userdata.py --migrate "
                 "if you have an older copy in bench/")
    m = find(at, ms)
    if not m:
        print(f"no meeting found around {at:%Y-%m-%d %H:%M}"); return
    print(f"{m.title}\n  {m.start:%Y-%m-%d %H:%M} – {m.end:%H:%M}")
    if m.speakers:
        print(f"  speakers ({len(m.speakers)}): {', '.join(m.speakers[:8])}"
              + (" …" if len(m.speakers) > 8 else ""))


if __name__ == "__main__":
    main()
