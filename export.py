#!/usr/bin/env python3
"""export.py - turn a transcript into Markdown, SRT or JSON.

Input schema: a JSON list of segments -

    [
      {"start": 12.3, "end": 15.8, "text": "...", "speaker": "Dana"},
      ...
    ]

`start`/`end` are seconds (float), `text` is required, `speaker` is optional
(omit it entirely for single-speaker audio).

Hebrew is RTL, but SRT and Markdown are plain text - the terminal or player
applies direction at render time, not this script. Inserting bidi control
characters here would just get echoed back and often breaks players (and
already-restored terms like "SIEM" would get wrapped), so text is written
through untouched.

    ./export.py transcript.json --format srt
    ./export.py transcript.json --format md -o notes.md
    ./export.py --selftest
"""
import argparse, json, sys
from pathlib import Path


def load_segments(path: Path) -> list[dict]:
    data = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(data, list):
        sys.exit(f"{path}: expected a JSON list of segments, got {type(data).__name__}")
    return data


def srt_timestamp(seconds: float) -> str:
    """HH:MM:SS,mmm. Round to whole milliseconds first, then split into
    fields - rounding after splitting is what turns 59.9996s into the
    invalid '00:00:59,1000' instead of correctly rolling into the next second."""
    ms_total = round(seconds * 1000)
    h, rem = divmod(ms_total, 3_600_000)
    m, rem = divmod(rem, 60_000)
    s, ms = divmod(rem, 1000)
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"


def to_srt(segments: list[dict]) -> str:
    cues = [f"{i}\n{srt_timestamp(s['start'])} --> {srt_timestamp(s['end'])}\n{s['text']}"
            for i, s in enumerate(segments, 1)]
    return "\n\n".join(cues) + "\n"


def _clock(seconds: float) -> str:
    return f"[{int(seconds // 60):02d}:{int(seconds % 60):02d}]"


def to_markdown(segments: list[dict]) -> str:
    """Consecutive segments from the same speaker become one paragraph under
    one heading, so a five-second-per-segment transcript doesn't read as
    fifty choppy one-line entries. Without speaker info each segment stays
    its own paragraph, since there's no natural turn boundary to merge on."""
    has_speakers = any(seg.get("speaker") for seg in segments)
    blocks = []
    i = 0
    while i < len(segments):
        speaker = segments[i].get("speaker")
        j = i + 1
        if has_speakers:
            while j < len(segments) and segments[j].get("speaker") == speaker:
                j += 1
        run = segments[i:j]
        para = f"{_clock(run[0]['start'])} " + " ".join(seg["text"] for seg in run)
        blocks.append(f"## {speaker or 'ללא זיהוי דובר'}\n\n{para}" if has_speakers else para)
        i = j
    return "\n\n".join(blocks) + "\n"


def to_json(segments: list[dict]) -> str:
    return json.dumps(segments, ensure_ascii=False, indent=2) + "\n"


FORMATS = {"srt": to_srt, "md": to_markdown, "json": to_json}


def selftest() -> None:
    # SRT timestamp boundaries
    assert srt_timestamp(0) == "00:00:00,000"
    assert srt_timestamp(59.999) == "00:00:59,999"
    assert srt_timestamp(3661) == "01:01:01,000"

    # SRT structure: sequential index, correct cue arrow, blank line between
    # cues, and no bidi control characters sneaking into RTL text
    segs = [
        {"start": 0.0, "end": 1.5, "text": "שלום עולם"},
        {"start": 1.5, "end": 3.0, "text": "צריך לעשות deploy"},
    ]
    srt = to_srt(segs)
    assert srt.startswith("1\n00:00:00,000 --> 00:00:01,500\nשלום עולם")
    assert "\n\n2\n00:00:01,500 --> 00:00:03,000\nצריך לעשות deploy" in srt
    assert not any(c in srt for c in "‎‏‪‫‬‭‮")

    # Hebrew round-trips through JSON unchanged (ensure_ascii=False)
    hebrew = "צריך לעשות deploy לפרודקשן, וה-DLP בארגון לא מכסה הכל"
    dumped = to_json([{"start": 0, "end": 1, "text": hebrew}])
    assert hebrew in dumped, "Hebrew got \\u-escaped instead of written raw"
    assert json.loads(dumped)[0]["text"] == hebrew

    # Markdown: speaker headings, paragraph merge on consecutive turns, [MM:SS]
    segs3 = [
        {"start": 5, "end": 8, "text": "הי", "speaker": "דנה"},
        {"start": 8, "end": 10, "text": "מה נשמע", "speaker": "דנה"},
        {"start": 65, "end": 68, "text": "בסדר", "speaker": "משה"},
    ]
    md = to_markdown(segs3)
    assert "## דנה" in md and "## משה" in md
    assert "[00:05] הי מה נשמע" in md  # merged into one paragraph
    assert "[01:05]" in md

    # Markdown without speakers: one paragraph per segment
    md_no_speaker = to_markdown([{"start": 0, "end": 1, "text": "א"},
                                  {"start": 1, "end": 2, "text": "ב"}])
    assert md_no_speaker == "[00:00] א\n\n[00:01] ב\n"

    print("export self-check passed")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("transcript", nargs="?", help="path to a transcript JSON file")
    ap.add_argument("--format", choices=sorted(FORMATS), default="md")
    ap.add_argument("-o", "--output", help="write to this path instead of stdout")
    ap.add_argument("--selftest", action="store_true", help="run the self-check and exit")
    a = ap.parse_args()

    if a.selftest:
        selftest()
        return
    if not a.transcript:
        ap.error("transcript file required (or use --selftest)")

    path = Path(a.transcript)
    if not path.exists():
        sys.exit(f"no such file: {path}")

    result = FORMATS[a.format](load_segments(path))
    if a.output:
        Path(a.output).write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)


if __name__ == "__main__":
    main()
