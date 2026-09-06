#!/usr/bin/env python3
"""Where the user's own data lives - never inside the checkout.

bench/meetings.json held 439 real meetings and 850 attendee names, in a
directory git watches, and it was committed and published before anyone
noticed. Two files harvested from the same calendar scan, vocab.json and
vocab_clean.json, went with it. Removing them took a history rewrite, a forced
push and deleting a release, and they were still fetchable by SHA afterwards.

The fix that matters is not another .gitignore line. Those only name paths that
have already gone wrong: rename the file and the rule stops applying. A file
derived from someone's calendar has no business in a directory git can see at
all. It belongs beside the recordings, which git has never been able to reach.

bench/no_personal_data.py enforces the other half - that nothing of this shape
is tracked - and is wired into ./check.

    ./userdata.py            where things are, and whether a legacy copy exists
    ./userdata.py --migrate  move a legacy bench/ copy out of the checkout
"""
import os, shutil, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def support_dir() -> Path:
    """The library root. SCRIBEBOT_SUPPORT moves it, exactly as the app does."""
    env = os.environ.get("SCRIBEBOT_SUPPORT", "").strip()
    if env:
        return Path(env).expanduser()
    return Path.home() / "Library/Application Support/Scribebot"


def index_dir() -> Path:
    """Calendar-derived indexes, beside the recordings rather than in the repo."""
    return support_dir() / "index"


MEETINGS_NAME = "meetings.json"
VOCAB_NAME = "vocab.json"
VOCAB_CLEAN_NAME = "vocab_clean.json"

# Where each file used to live, so a checkout that still has one can be moved
# rather than silently ignored.
LEGACY = {
    MEETINGS_NAME: ROOT / "bench" / MEETINGS_NAME,
    VOCAB_NAME: ROOT / "bench" / VOCAB_NAME,
    VOCAB_CLEAN_NAME: ROOT / "bench" / VOCAB_CLEAN_NAME,
}


def path(name: str) -> Path:
    """The canonical location for one index."""
    return index_dir() / name


def meetings() -> Path: return path(MEETINGS_NAME)
def vocab() -> Path: return path(VOCAB_NAME)
def vocab_clean() -> Path: return path(VOCAB_CLEAN_NAME)


def resolve(name: str) -> Path | None:
    """The file to read, or None. Prefers the canonical location.

    A legacy copy in bench/ is still honoured for reading, because a developer
    who has not migrated should not silently lose their index - but `migrate`
    is what gets it out of the checkout, and ./check complains while one is
    still there.
    """
    canonical = path(name)
    if canonical.exists():
        return canonical
    legacy = LEGACY.get(name)
    return legacy if legacy and legacy.exists() else None


def stray() -> list[Path]:
    """Legacy copies still sitting inside the checkout."""
    return [p for p in LEGACY.values() if p.exists()]


def migrate(verbose: bool = True) -> list[tuple[Path, Path]]:
    """Move any legacy copy out of the checkout. Returns what moved.

    Copy, verify the bytes, then unlink - never a bare rename across what may
    be different volumes, and never a delete not preceded by a verified copy.
    This is the user's own calendar data; losing it to a tidy-up would be its
    own kind of failure.
    """
    moved = []
    index_dir().mkdir(parents=True, exist_ok=True)
    for name, legacy in LEGACY.items():
        if not legacy.exists():
            continue
        target = path(name)
        if target.exists() and target.read_bytes() == legacy.read_bytes():
            legacy.unlink()
            if verbose: print(f"  already migrated, removed checkout copy: {name}")
            continue
        shutil.copy2(legacy, target)
        if target.read_bytes() != legacy.read_bytes():
            raise SystemExit(f"copy of {name} did not match; leaving {legacy} alone")
        legacy.unlink()
        moved.append((legacy, target))
        if verbose: print(f"  moved bench/{name} -> {target}")
    return moved


def selftest() -> None:
    """No real data touched: everything runs under a temporary support dir."""
    import tempfile
    old = os.environ.get("SCRIBEBOT_SUPPORT")
    with tempfile.TemporaryDirectory() as d:
        os.environ["SCRIBEBOT_SUPPORT"] = d
        try:
            assert support_dir() == Path(d)
            assert index_dir() == Path(d) / "index"
            assert meetings() == Path(d) / "index" / MEETINGS_NAME
            index_dir().mkdir(parents=True, exist_ok=True)
            meetings().write_text("[]", encoding="utf-8")
            # The canonical location wins over any legacy one.
            assert resolve(MEETINGS_NAME) == meetings()
            assert resolve("nothing.json") is None
            # The whole point: never inside the repository.
            for p in (meetings(), vocab(), vocab_clean(), index_dir()):
                assert ROOT not in p.parents, f"{p} is inside the repository"
        finally:
            if old is None: os.environ.pop("SCRIBEBOT_SUPPORT", None)
            else: os.environ["SCRIBEBOT_SUPPORT"] = old
    print("userdata self-check passed")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    elif "--migrate" in sys.argv:
        moved = migrate()
        print(f"{len(moved)} file(s) moved out of the checkout" if moved
              else "nothing to migrate")
    else:
        print(f"index directory: {index_dir()}")
        for name in LEGACY:
            found = resolve(name)
            print(f"  {name:20} {found if found else '(absent)'}")
        s = stray()
        if s:
            print("\nstill inside the checkout - run ./userdata.py --migrate:")
            for p in s: print(f"  {p}")
