#!/usr/bin/env python3
"""scribebot - capture system audio, transcribe on-device, restore English terms.

Nothing leaves the machine. No bot joins the call.

    ./scribebot.py record 60           capture 60s of system audio and transcribe
    ./scribebot.py file a.wav          transcribe an existing file
    ./scribebot.py record 60 --pid 123 capture one app only
"""
import argparse, json, subprocess, sys, time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
CAPTURE = ROOT / "capture/ScribebotCapture.app/Contents/MacOS/ScribebotCapture"
MODEL = ROOT / "models/ivrit-large-v3-turbo.bin"
sys.path.insert(0, str(ROOT / "bench"))
from glossary import Restorer
from toolpaths import WHISPER


def load_glossary():
    """Known Hebrew spellings of English technical terms, matched exactly.

    Harvested contact names are deliberately NOT loaded here either - a Hebrew
    name written in Hebrew is already correct. They are still used in
    attribute.py to name diarized speakers, which is a lookup rather than a
    rewrite of the transcript.

    Only known Hebrew spellings are loaded, and they are matched EXACTLY.

    Fuzzy romanization was removed after it was measured against 324 real
    strings from the user's own calendar: it rewrote 15.4% of them, turning
    "מטריקס" - the partner company Matrix - into "metrics" seventeen times, and
    "הכאב דוקר לי בצד" ("the pain stabs me") into "הכאב Docker לי בצד". The
    matcher cannot tell Hebrew that transliterates an English term from Hebrew
    that is simply a word or a name, and no blocklist fixes that: the previous
    one was fitted to the exact words that had already failed.

    Exact matching costs term preservation (78.7% -> 70.2%) and is still far
    ahead of raw decoding (46.8%). Mangling the user's own vocabulary is not a
    trade worth making for eight points.
    """
    aliases = {}
    ap = ROOT / "bench/aliases.json"
    if ap.exists(): aliases = json.loads(ap.read_text())
    terms = list(aliases)
    return (Restorer(terms, aliases=aliases, exact_only=set(terms)), len(terms))


def capture(seconds: float, out: Path, pid: int | None) -> None:
    if not CAPTURE.exists():
        sys.exit(f"capture binary missing: {CAPTURE}\nbuild it first (see capture/)")
    cmd = [str(CAPTURE), "record", str(seconds), str(out)]
    if pid: cmd.append(str(pid))
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"capture failed:\n{r.stderr.strip()}")
    for line in r.stdout.splitlines():
        if line.startswith(("frames=", "first-audio", "WARNING")):
            print(f"  {line}", file=sys.stderr)


def is_silent(wav: Path, threshold: float = 0.004) -> bool:
    """True when a file holds no real signal.

    Whisper hallucinates confidently on silence - a silent microphone track came
    back as "תודה רבה לך, אדוני היושב-ראש", a parliamentary phrase nobody said.
    Better to return nothing than to invent a sentence.
    """
    import array, wave as _w
    try:
        with _w.open(str(wav)) as w:
            if w.getnframes() == 0: return True
            d = w.readframes(w.getnframes())
    except Exception:
        return False
    a = array.array("h"); a.frombytes(d[: len(d) // 2 * 2])
    if not a: return True
    return max((abs(v) for v in a[::13]), default=0) / 32768.0 < threshold


def transcribe_segments(wav: Path) -> list[dict]:
    """Transcribe with real per-segment timestamps.

    Export used to fabricate timings by splitting the recording duration across
    lines in proportion to their character count - and because the plain
    transcript collapses to a single line, every SRT was two cues: a 30-minute
    meeting rendered as a 19-minute subtitle, printed to the millisecond. The
    decoder can give real boundaries, so it does.
    """
    js = wav.with_suffix(".wav.json")
    r = subprocess.run(
        [WHISPER, "-m", str(MODEL), "-f", str(wav), "-l", "he",
         "-sow", "-oj", "-np"],
        capture_output=True, text=True)
    if r.returncode != 0 or not js.exists():
        return []
    try:
        data = json.loads(js.read_text())
    finally:
        js.unlink(missing_ok=True)
    out = []
    for seg in data.get("transcription", []):
        text = seg.get("text", "").strip()
        o = seg.get("offsets", {})
        if text:
            out.append({"start": o.get("from", 0) / 1000.0,
                        "end": o.get("to", 0) / 1000.0, "text": text})
    return out


def transcribe(wav: Path) -> str:
    if not MODEL.exists():
        sys.exit(f"model missing: {MODEL}")
    r = subprocess.run(
        [WHISPER, "-m", str(MODEL), "-f", str(wav), "-l", "he", "-nt", "-np"],
        capture_output=True, text=True)
    if r.returncode != 0:
        sys.exit(f"transcription failed:\n{r.stderr.strip()[:400]}")
    return " ".join(r.stdout.split())


LIBRARY = Path.home() / "Library/Application Support/Scribebot/recordings"


def rebuild(restorer, dry: bool = False) -> None:
    """Re-transcribe saved recordings from their audio.

    The app writes a live preview first and replaces it with an accurate pass
    once recording stops. If the app is quit during that second the preview is
    what survives - the user's transcripts read as one truncated fragment while
    the full text sat in the audio all along. This recovers them.
    """
    if not LIBRARY.exists():
        sys.exit(f"no library at {LIBRARY}")
    tapes = sorted(w for w in LIBRARY.glob("*.wav") if not w.stem.endswith("-you"))
    if not tapes:
        print("no recordings found"); return
    print(f"{len(tapes)} recordings in {LIBRARY}\n")
    for wav in tapes:
        rid = wav.stem
        you = wav.with_name(f"{rid}-you.wav")
        lines = []
        for label, f in (("Them", wav), ("You", you)):
            if not f.exists() or is_silent(f):
                continue
            raw = transcribe(f)
            if not raw:
                continue
            lines.append(f"{label}: {restorer.restore(raw)}")
        txt = LIBRARY / f"{rid}.txt"
        before = txt.read_text(encoding="utf-8").strip() if txt.exists() else ""
        after = "\n".join(lines)
        status = "same" if before == after else ("empty" if not after else
                 f"{len(before)} -> {len(after)} chars")
        print(f"  {rid}  {status}")
        if after and after != before and not dry:
            txt.write_text(after, encoding="utf-8")
    print("\n(dry run, nothing written)" if dry else "\ndone")


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    rec = sub.add_parser("record", help="capture system audio then transcribe")
    rec.add_argument("seconds", type=float)
    rec.add_argument("--pid", type=int, help="capture only this process")
    rec.add_argument("--keep-audio", action="store_true")
    rb = sub.add_parser("rebuild",
                        help="re-transcribe every saved recording and rewrite its transcript")
    rb.add_argument("--dry-run", action="store_true")

    fil = sub.add_parser("file", help="transcribe an existing audio file")
    fil.add_argument("path")
    fil.add_argument("--segments", action="store_true",
                     help="emit JSON segments with real timestamps, for export")
    for p in (rec, fil):
        p.add_argument("--raw", action="store_true",
                       help="skip English-term restoration")
    a = ap.parse_args()

    restorer, n_terms = load_glossary()

    if a.cmd == "rebuild":
        rebuild(restorer, dry=a.dry_run)
        return

    if a.cmd == "record":
        wav = ROOT / "out" / f"tape-{int(time.time())}.wav"
        wav.parent.mkdir(exist_ok=True)
        print(f"recording {a.seconds:g}s of system audio...", file=sys.stderr)
        capture(a.seconds, wav, a.pid)
    else:
        wav = Path(a.path)
        if not wav.exists(): sys.exit(f"no such file: {wav}")

    # Attach the recording to whatever meeting it belongs to. The attendee list
    # is both the transcript's header and the roster of names to expect.
    ctx = None
    try:
        from meeting import load as load_meetings, find as find_meeting
        from datetime import datetime
        ms = load_meetings()
        if ms:
            ctx = find_meeting(datetime.now().astimezone(), ms)
    except Exception:
        ctx = None
    if ctx:
        print(f"# {ctx.title}", file=sys.stderr)
        print(f"# {ctx.start:%Y-%m-%d %H:%M} · {len(ctx.speakers)} invited",
              file=sys.stderr)

    if getattr(a, "segments", False):
        segs = transcribe_segments(wav)
        if not a.raw:
            for seg in segs:
                seg["text"] = restorer.restore(seg["text"])
        print(json.dumps(segs, ensure_ascii=False, indent=1))
        return

    if is_silent(wav):
        print("", end="")
        print("[no speech in this recording]", file=sys.stderr)
        return

    t0 = time.time()
    raw = transcribe(wav)
    elapsed = time.time() - t0

    out = raw if a.raw else restorer.restore(raw)
    print(out)
    print(f"\n[{n_terms} glossary terms · transcribed in {elapsed:.1f}s"
          f"{'' if a.raw else ' · terms restored'}]", file=sys.stderr)
    if a.cmd == "record" and not a.keep_audio:
        wav.unlink(missing_ok=True)
    elif a.cmd == "record":
        print(f"[audio kept at {wav}]", file=sys.stderr)


if __name__ == "__main__":
    main()
