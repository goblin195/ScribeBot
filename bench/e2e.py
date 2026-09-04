#!/usr/bin/env python3
"""End-to-end test of the CAPTURE PIPELINE - not of the app.

This spawns the real, signed capture helper against a real CoreAudio tap and a
real microphone, and asserts that both sides end up captured and transcribed.
That is worth having: a silent recording passes every other check in this repo.

What it does NOT do, stated plainly because it was once claimed otherwise: it
never touches `app/`. Deleting the application would not change the result. It
spawns the microphone helper itself, so the first fault ever reported from real
use - a missing `startMic()` call in the app - would pass here. That wiring is
asserted separately in bench/wiring.py by reading the app's source.

A further limit: on speakers the microphone picks up the far side as echo, so
"both sides captured" can be one source counted twice. The peak gate is weak
enough that fan noise has passed it. Treat a pass as "the pipeline moves audio",
not as "the product works".
"""
import json, subprocess, sys, time, wave
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "capture/ScribebotCapture.app/Contents/MacOS/ScribebotCapture"
OUT = Path("/tmp/scribebot-e2e")
SECS = 8


def peak(wav: Path) -> float:
    import array
    with wave.open(str(wav)) as w:
        d = w.readframes(w.getnframes())
    a = array.array("h"); a.frombytes(d[: len(d) // 2 * 2])
    return max((abs(v) for v in a[::13]), default=0) / 32768.0


def seconds(wav: Path) -> float:
    with wave.open(str(wav)) as w:
        return w.getnframes() / w.getframerate()


def transcribe(wav: Path) -> str:
    r = subprocess.run([sys.executable, str(ROOT / "scribebot.py"), "file", str(wav)],
                       capture_output=True, text=True, cwd=ROOT)
    return " ".join(r.stdout.split())


def main() -> int:
    OUT.mkdir(exist_ok=True)
    them, you = OUT / "them.wav", OUT / "you-you.wav"
    for f in (them, you): f.unlink(missing_ok=True)

    # exactly what Recorder.start() does: startMic() then the tap stream
    micp = subprocess.Popen([str(HELPER), "mic", str(you)],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    time.sleep(0.4)
    tapp = subprocess.Popen([str(HELPER), "stream"],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    player = subprocess.Popen(["afplay", "/tmp/probe_long.wav"],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    pcm = bytearray()
    deadline = time.time() + SECS
    while time.time() < deadline:
        chunk = tapp.stdout.read(4096)
        if not chunk: break
        pcm.extend(chunk)
    player.terminate(); tapp.terminate(); micp.terminate()
    time.sleep(1.5)

    with wave.open(str(them), "wb") as w:
        w.setnchannels(1); w.setsampwidth(2); w.setframerate(16000)
        w.writeframes(bytes(pcm))

    fails = []
    print(f"{'stream':<10}{'seconds':>9}{'peak':>8}   transcript")
    print("-" * 74)
    for label, f in (("them", them), ("you", you)):
        if not f.exists():
            print(f"{label:<10}{'MISSING':>9}"); fails.append(f"{label}: no file"); continue
        s, p = seconds(f), peak(f)
        t = transcribe(f)
        print(f"{label:<10}{s:>9.2f}{p:>8.4f}   {t[:40]}")
        if s < SECS * 0.6: fails.append(f"{label}: only {s:.1f}s of {SECS}s")
        if p < 0.002:      fails.append(f"{label}: silent (peak {p:.4f})")
        if not t:          fails.append(f"{label}: no transcript")
    # The live path is what the user actually reads, and it is where invented
    # sentences appeared. Assert that a SILENT stream produces no text at all.
    print()
    print("live path")
    # raw PCM frames, NOT the .wav bytes - live.py reads its stdin as raw PCM,
    # and a RIFF header fed as samples is a loud click that defeats any gate
    silent_pcm = b"\x00\x00" * 16000 * 6
    r = subprocess.run([sys.executable, str(ROOT / "live.py"), "--stdin"],
                       input=silent_pcm, capture_output=True, cwd=ROOT)
    invented = [l for l in r.stdout.decode().split("\n") if l.strip()]
    if invented:
        print(f"  silent stream produced text: {invented[:1]}")
        fails.append("live: invented text from silence")
    else:
        print("  silent stream produced nothing  ✓")

    # and that real speech DOES come through the live path
    with wave.open(str(them)) as w:
        them_pcm = w.readframes(w.getnframes())
    r = subprocess.run([sys.executable, str(ROOT / "live.py"), "--stdin"],
                       input=them_pcm, capture_output=True, cwd=ROOT)
    spoke = [l for l in r.stdout.decode().split("\n") if l.strip()]
    if spoke:
        print(f"  speech through live path      ✓  {spoke[0][:44]}")
    else:
        fails.append("live: no text from real speech")

    print()
    if fails:
        for f in fails: print(f"  FAIL  {f}")
        print("\ne2e FAILED")
        return 1
    print("e2e passed — both sides captured and transcribed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
