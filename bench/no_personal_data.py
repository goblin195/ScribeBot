#!/usr/bin/env python3
"""Refuse to let the user's own data become a tracked file.

bench/meetings.json - 439 real meetings, 850 attendee names - was committed in
the first public commit and stayed reachable for two days. Two files from the
same calendar scan went with it. Removing them took a history rewrite, a forced
push and deleting a release, and the objects were still fetchable by SHA
afterwards.

The first response to that was three .gitignore lines, which is the weakest
possible fix: it names three paths that have already gone wrong. Rename the
file, or write a new one, and the rule stops applying. This looks at CONTENT
instead, so bench/attendees-2026.json is caught on its first commit rather than
its first publication.

Every rule has to survive the tree as it stands, which is full of Hebrew, full
of the word "attendees" in prose, and full of technical vocabulary. A guard
that cries wolf gets switched off, so each rule keys on a shape only real
personal data has, and says what it is for.

    python3 bench/no_personal_data.py           check tracked files
    python3 bench/no_personal_data.py --staged  check what is about to commit
"""
import json, re, subprocess, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

# Keys only a calendar export has. Source files talk *about* attendees; a JSON
# object that *has* an attendees list is an index.
CALENDAR_KEYS = {"attendees", "organizer", "invitees", "participants"}

# Filenames that were personal data before and must not come back, in any
# directory.
BANNED_NAMES = re.compile(
    r"^(meetings|vocab|vocab_clean|attendees|contacts|calendar|people)"
    r"[-_a-z0-9]*\.json$", re.I)

# A real address. Placeholders and the addresses this project legitimately
# ships are fine - the target is someone's actual mailbox, not a docs sample.
EMAIL = re.compile(r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b")
EMAIL_OK = re.compile(
    r"(example\.(com|org|net)|@example|noreply@|localhost|"
    r"your-?email|user@|name@)", re.I)

# Binaries excluded by extension rather than by sniffing, so the check stays
# fast and predictable.
SKIP_SUFFIX = {".png", ".jpg", ".jpeg", ".gif", ".icns", ".bin", ".wav", ".caf",
               ".dmg", ".zip", ".gz", ".pdf", ".mp4", ".pyc", ".iconset"}


def placeholder(addr: str) -> bool:
    """Synthetic addresses used in comments and fixtures.

    "a@b.co.il" and "x@y.com" appear in a doc comment and a name-cleaning test.
    Both were flagged on the first run, and a guard that flags the codebase it
    guards is a guard someone deletes. A one- or two-letter mailbox at a one- or
    two-letter domain is nobody's real address; two initials at a real company
    domain still is. No example of that shape is written here - this guard reads
    its own source, and an illustrative address would make it fail on itself.
    """
    local, _, domain = addr.partition("@")
    return len(local) <= 2 and len(domain.split(".")[0]) <= 2


def tracked(staged: bool) -> list[str]:
    cmd = (["git", "diff", "--cached", "--name-only", "--diff-filter=ACM"]
           if staged else ["git", "ls-files"])
    out = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    if out.returncode != 0:
        raise SystemExit(f"git failed: {out.stderr.strip()}")
    return [l for l in out.stdout.splitlines() if l.strip()]


def calendar_shaped(data) -> str | None:
    """The key that makes this a calendar export, if it is one."""
    stack = [data]
    while stack:
        node = stack.pop()
        if isinstance(node, dict):
            for k, v in node.items():
                if k.lower() in CALENDAR_KEYS and isinstance(v, (list, str)) and v:
                    return k
                stack.append(v)
        elif isinstance(node, list):
            stack.extend(node[:200])   # a sample identifies the shape
    return None


def check(paths: list[str]) -> list[str]:
    problems = []
    for rel in paths:
        p = ROOT / rel
        if not p.is_file() or p.suffix.lower() in SKIP_SUFFIX:
            continue

        if BANNED_NAMES.match(p.name):
            problems.append(
                f"{rel}: a filename this project has leaked personal data under "
                f"before. Calendar-derived indexes belong in the support "
                f"directory - see userdata.py.")
            continue

        try:
            text = p.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue

        if p.suffix.lower() == ".json":
            try:
                key = calendar_shaped(json.loads(text))
            except json.JSONDecodeError:
                key = None
            if key:
                problems.append(
                    f"{rel}: has a {key!r} field, which makes it a calendar "
                    f"export. It belongs in the support directory, not the "
                    f"repository - see userdata.py.")
                continue

        for m in EMAIL.finditer(text):
            if EMAIL_OK.search(m.group(0)) or placeholder(m.group(0)):
                continue
            line = text[:m.start()].count("\n") + 1
            # Report the location, never the address itself.
            problems.append(
                f"{rel}:{line}: a real-looking email address "
                f"({m.group(0)[:3]}…). Someone's address does not belong in a "
                f"public repository.")
            break
    return problems


def main() -> int:
    staged = "--staged" in sys.argv
    paths = tracked(staged)
    problems = check(paths)

    # A legacy copy still in the checkout is one `git add -A` away from being
    # tracked again, so mention it even while it is only ignored.
    sys.path.insert(0, str(ROOT))
    import userdata
    strays = userdata.stray()

    if problems:
        print(f"personal data in {len(problems)} tracked file(s):")
        for p in problems:
            print(f"  {p}")
        return 1
    scope = "staged" if staged else "tracked"
    note = (f" · {len(strays)} legacy copy in the checkout, "
            f"run ./userdata.py --migrate") if strays else ""
    print(f"no personal data in {len(paths)} {scope} files{note}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
