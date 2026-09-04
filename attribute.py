#!/usr/bin/env python3
"""Attach speaker identity to transcript segments.

Three sources, each supplying what the others cannot:
  diarization  tells us WHEN the speaker changed, but only ever "speaker 0/1/2"
  transcript   tells us WHAT was said and when
  calendar     tells us WHO was invited - the only source of actual names

Anonymous "Speaker 1" labels are the thing people complain about most in meeting
transcripts, and the calendar has been sitting on the answer the whole time.
When the diarized speaker count matches the invitee count, the mapping is
offered; otherwise labels stay anonymous rather than guessing a name onto a
voice, because a wrong name is worse than no name.
"""
import json, sys
from dataclasses import dataclass, asdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent


@dataclass
class Segment:
    start: float
    end: float
    text: str
    speaker: str | None = None


def load_rttm(path: Path) -> list[tuple[float, float, str]]:
    out = []
    for line in path.read_text().splitlines():
        f = line.split()
        if len(f) >= 8 and f[0] == "SPEAKER":
            s, d = float(f[3]), float(f[4])
            out.append((s, s + d, f[7]))
    return sorted(out)


def overlap(a0: float, a1: float, b0: float, b1: float) -> float:
    return max(0.0, min(a1, b1) - max(a0, b0))


def attribute(segments: list[Segment],
              turns: list[tuple[float, float, str]]) -> list[Segment]:
    """Assign each transcript segment the speaker it overlaps most."""
    out = []
    for s in segments:
        best, best_ov = None, 0.0
        for t0, t1, spk in turns:
            ov = overlap(s.start, s.end, t0, t1)
            if ov > best_ov:
                best, best_ov = spk, ov
        # require the overlap to cover a real share of the segment, otherwise
        # a passing turn boundary would claim it
        dur = max(1e-6, s.end - s.start)
        out.append(Segment(s.start, s.end, s.text,
                           best if best_ov / dur >= 0.35 else None))
    return out


def name_speakers(segments: list[Segment], names: list[str]) -> list[Segment]:
    """Map anonymous speaker ids onto invitee names, in first-speaking order.

    Only applied when the counts agree. Guessing which voice belongs to which
    invitee when the numbers differ produces confident, wrong attributions.
    """
    order, seen = [], set()
    for s in segments:
        if s.speaker and s.speaker not in seen:
            seen.add(s.speaker); order.append(s.speaker)
    if not order or len(order) != len(names):
        return segments
    mapping = dict(zip(order, names))
    return [Segment(s.start, s.end, s.text, mapping.get(s.speaker, s.speaker))
            for s in segments]


def selftest() -> None:
    segs = [Segment(0.0, 3.0, "a"), Segment(3.5, 6.0, "b"), Segment(6.5, 9.0, "c")]
    turns = [(0.0, 3.1, "s0"), (3.4, 6.1, "s1"), (6.4, 9.1, "s0")]
    got = attribute(segs, turns)
    assert [g.speaker for g in got] == ["s0", "s1", "s0"], [g.speaker for g in got]

    # a segment that barely grazes a turn stays unattributed
    grazed = attribute([Segment(0.0, 10.0, "x")], [(9.6, 10.0, "s9")])
    assert grazed[0].speaker is None, grazed[0].speaker

    named = name_speakers(got, ["Gavriel", "Amir"])
    assert [n.speaker for n in named] == ["Gavriel", "Amir", "Gavriel"]

    # counts disagree -> stay anonymous rather than invent an attribution
    same = name_speakers(got, ["Gavriel", "Amir", "Orna"])
    assert [n.speaker for n in same] == ["s0", "s1", "s0"]
    print("attribute self-check passed")


def main() -> None:
    if "--selftest" in sys.argv:
        selftest(); return
    if len(sys.argv) < 3:
        sys.exit("usage: attribute.py <segments.json> <diarization.rttm> [name ...]")
    segs = [Segment(**s) for s in json.loads(Path(sys.argv[1]).read_text())]
    turns = load_rttm(Path(sys.argv[2]))
    out = attribute(segs, turns)
    names = sys.argv[3:]
    if names:
        out = name_speakers(out, names)
    print(json.dumps([asdict(s) for s in out], ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
