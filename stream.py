#!/usr/bin/env python3
"""Streaming transcription with LocalAgreement-2, done with absolute time.

The earlier attempt compared consecutive hypotheses in window-relative time, so
every buffer trim shifted the text underneath the comparison and agreement broke
down - coverage oscillated between a third and a half of the speech depending on
which bug was being patched at the time.

Here every decoded word carries an absolute timestamp (buffer offset + its
in-window offset). A word is confirmed when two consecutive decodes agree on it
at the same place in the stream, and the buffer is then trimmed at the last
confirmed word so the next decode starts on unconfirmed speech. Because the
timestamps are absolute, trimming does not disturb the comparison.

Reference: Machacek, Dabre & Bojar, "Turning Whisper into Real-Time Transcription
System" (2023) - the confirmed/unconfirmed discipline, not the code.
"""
from __future__ import annotations
import array, json, re, subprocess, sys, tempfile, wave
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent
from toolpaths import WHISPER
import languages
SR = 16_000
# Whisper loops on near-silence, emitting runs like "פסססססססס".
_RUN = re.compile(r"(.)\1{4,}")


@dataclass(frozen=True)
class Word:
    start: float      # absolute seconds from the start of the stream
    end: float
    text: str


def is_garbage(text: str) -> bool:
    """Fragments not worth showing a reader.

    Besides whisper's silence loops, a decode can emit a lone comma or full
    stop when the window holds almost nothing - a line containing only
    punctuation is noise on screen.
    """
    if _RUN.search(text):
        return True
    return not any(c.isalnum() for c in text)


def decode(pcm: bytes, offset: float, prompt: str = "") -> list[Word]:
    """Decode a PCM buffer into words carrying absolute timestamps."""
    with tempfile.TemporaryDirectory() as d:
        wav = Path(d) / "w.wav"
        with wave.open(str(wav), "wb") as w:
            w.setnchannels(1); w.setsampwidth(2); w.setframerate(SR)
            w.writeframes(pcm)
        # The live preview cannot afford the batch path's second pass, so it
        # runs whatever the configured language resolves to. Leaving the
        # language on `auto` means the general model here; naming the language
        # (SCRIBEBOT_LANG=he) puts the fine-tune in the preview too. Either
        # way the transcript saved at the end is re-decoded properly.
        model, flag = languages.require()
        cmd = [WHISPER, "-m", str(model), "-f", str(wav), "-l", flag,
               "-ml", "1", "-sow", "-oj", "-np"]
        if prompt:
            cmd += ["--prompt", " ".join(prompt.split()[-40:])]
        r = subprocess.run(cmd, capture_output=True, text=True)
        js = wav.with_suffix(".wav.json")
        # A failed decode is not silence. Say so on stderr - live.py's stderr
        # now reaches <id>.capture.log - rather than returning "no words" and
        # leaving the live view blank with no explanation anywhere.
        if r.returncode != 0 or not js.exists():
            detail = (r.stderr or r.stdout or "").strip().splitlines()[-1:]
            print(f"decode failed (exit {r.returncode}): "
                  f"{detail[0] if detail else 'no output'}", file=sys.stderr)
            return []
        try:
            data = json.loads(js.read_text())
        except json.JSONDecodeError:
            return []
    out = []
    for seg in data.get("transcription", []):
        t = seg.get("text", "").strip()
        o = seg.get("offsets", {})
        if t and not is_garbage(t):
            out.append(Word(offset + o.get("from", 0) / 1000.0,
                            offset + o.get("to", 0) / 1000.0, t))
    return out


def agree(prev: list[Word], cur: list[Word], tol: float = 0.35) -> list[Word]:
    """Words the two hypotheses agree on: same text at nearly the same time.

    Matching on time as well as text is what stops a repeated word later in the
    stream from being mistaken for the earlier one.
    """
    out = []
    for a, b in zip(prev, cur):
        if a.text != b.text or abs(a.start - b.start) > tol:
            break
        out.append(b)
    return out


class Stream:
    """Feed it PCM, get confirmed words out. No I/O of its own, so it is testable."""

    def __init__(self, window: float = 18.0, prompt_context: bool = True):
        self.buf = bytearray()
        self.offset = 0.0            # absolute time of buf[0]
        self.prev: list[Word] = []
        self.confirmed: list[Word] = []
        self.window = window
        self.prompt_context = prompt_context

    def feed(self, pcm: bytes) -> None:
        self.buf.extend(pcm)

    def seconds_buffered(self) -> float:
        return len(self.buf) / (SR * 2)

    @staticmethod
    def _peak(pcm: bytes) -> float:
        a = array.array("h"); a.frombytes(pcm[: len(pcm) // 2 * 2])
        if not a: return 0.0
        return max((abs(v) for v in a[::37]), default=0) / 32768.0

    def step(self) -> list[Word]:
        """Decode once. Returns words newly confirmed by this pass."""
        if self.seconds_buffered() < 1.0:
            return []
        # Whisper invents fluent sentences from silence - a silent system-audio
        # stream produced "אדוני היושב-ראש, חבריי חברי הכנסת", a Knesset opening
        # nobody said, and it was stored as the meeting transcript. Never decode
        # a window with no signal in it.
        if self._peak(bytes(self.buf)) < 0.004:
            return []
        # keep at most `window` seconds so decode cost stays bounded
        if self.seconds_buffered() > self.window:
            drop = len(self.buf) - int(self.window * SR * 2)
            self.offset += drop / (SR * 2)
            del self.buf[:drop]
            self.prev = [w for w in self.prev if w.start >= self.offset]

        ctx = " ".join(w.text for w in self.confirmed[-40:]) if self.prompt_context else ""
        cur = decode(bytes(self.buf), self.offset, ctx)
        stable = agree(self.prev, cur)
        self.prev = cur

        cutoff = self.confirmed[-1].end if self.confirmed else -1.0
        fresh = [w for w in stable if w.start > cutoff - 0.05]
        if not fresh:
            return []
        self.confirmed.extend(fresh)

        # trim to the last confirmed word so the next decode starts on new speech
        keep_from = fresh[-1].end - self.offset
        drop = int(max(0.0, keep_from) * SR * 2)
        if drop > 0:
            self.offset += drop / (SR * 2)
            del self.buf[:drop]
            self.prev = []
        return fresh

    def flush(self) -> list[Word]:
        """At end of stream, accept the last hypothesis without a second vote."""
        cutoff = self.confirmed[-1].end if self.confirmed else -1.0
        fresh = [w for w in self.prev if w.start > cutoff - 0.05]
        self.confirmed.extend(fresh)
        return fresh

    def text(self) -> str:
        return " ".join(w.text for w in self.confirmed)


def selftest() -> None:
    W = lambda s, e, t: Word(s, e, t)
    # agreement needs matching text AND time
    a = [W(0, 1, "a"), W(1, 2, "b"), W(2, 3, "c")]
    b = [W(0, 1, "a"), W(1, 2, "b"), W(2, 3, "x")]
    assert [w.text for w in agree(a, b)] == ["a", "b"]
    shifted = [W(0, 1, "a"), W(9, 10, "b")]
    assert [w.text for w in agree(a, shifted)] == ["a"]
    assert is_garbage("פססססססס") and not is_garbage("הפגישה") and not is_garbage("SIEM")

    s = Stream()
    s.confirmed = [W(0, 1.0, "x")]
    s.prev = [W(0, 1.0, "x"), W(1.2, 1.8, "y")]
    assert [w.text for w in s.flush()] == ["y"], "flush must not re-emit confirmed words"
    print("stream self-check passed")


if __name__ == "__main__":
    import sys
    if "--selftest" in sys.argv:
        selftest()
