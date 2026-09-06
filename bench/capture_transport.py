#!/usr/bin/env python3
"""Exercise production Swift Recorder with synthetic helpers in a temp library."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import textwrap

ROOT = Path(__file__).resolve().parent.parent


def main():
    swift = shutil.which("swiftc")
    if not swift:
        raise SystemExit("swiftc required for capture transport checks")
    with tempfile.TemporaryDirectory(prefix="scribebot-capture-check-") as temp, \
            tempfile.TemporaryDirectory(prefix="scribebot-test-support-") as support:
        root = Path(temp)
        (root / "recordings").mkdir()
        # No model, microphone, system tap, user library, or network is involved.
        helper = root / "capture"
        helper.write_text(f"#!{sys.executable}\n" + textwrap.dedent('''\
            import os, signal, sys, time, wave
            from pathlib import Path
            mic = sys.argv[1] == 'mic'
            if not mic and Path(__file__).with_name('exit-tap').exists():
                raise SystemExit(7)
            wav = None
            def stop(*args):
                if wav:
                    time.sleep(0.3)  # force the old stop/header race
                    wav.close()
                raise SystemExit(0)
            signal.signal(signal.SIGTERM, stop)
            if mic:
                wav = wave.open(sys.argv[2], 'wb')
                wav.setnchannels(1); wav.setsampwidth(2); wav.setframerate(16000)
            data = b'\\x10\\x01' * 2048
            for _ in range(256):
                if wav: wav.writeframesraw(data)
                os.write(1, data)
            while True: time.sleep(0.05)
        '''))
        helper.chmod(0o755)
        shutil.copy2(ROOT / "recovery.py", root / "recovery.py")
        shutil.copy2(ROOT / "userdata.py", root / "userdata.py")
        (root / "live.py").write_text("import time\ntime.sleep(60)\n")
        (root / "scribebot.py").write_text(textwrap.dedent('''\
            import sys, wave
            from contextlib import nullcontext
            from pathlib import Path
            from recovery import recovered_audio
            audio = Path(sys.argv[2])
            if audio.stem.endswith('-you') and Path('fail-mic').exists():
                raise SystemExit('simulated microphone decode failure')
            with (recovered_audio(audio) if '--recover' in sys.argv else nullcontext(audio)) as source, wave.open(str(source), 'rb') as wav:
                assert wav.getnframes() >= 524288, 'audio header not finalized'
                assert len(wav.readframes(wav.getnframes())) >= 1048576
            print('verified saved audio')
        '''))
        binary = root / "capture-check"
        build = subprocess.run([
            swift, "-parse-as-library", "-module-cache-path", str(root / "modules"),
            "-o", str(binary), str(ROOT / "app/Sources/CaptureTransport.swift"),
            str(ROOT / "app/Sources/Recorder.swift"),
            str(ROOT / "app/Sources/RecordingState.swift"),
            str(ROOT / "app/Sources/SpeakerTranscript.swift"),
            str(ROOT / "app/Sources/SavedTranscription.swift"),
            str(ROOT / "app/capture-selftest/main.swift"),
        ], capture_output=True, text=True, timeout=120)
        if build.returncode:
            print(build.stderr)
            return build.returncode
        env = dict(os.environ, SCRIBEBOT_CAPTURE_TEST_ROOT=temp,
                   SCRIBEBOT_SUPPORT=support,
                   SCRIBEBOT_CAPTURE_TEST_PYTHON=sys.executable)
        result = subprocess.run([str(binary)], env=env, capture_output=True,
                                text=True, timeout=90)
        print(result.stdout.strip())
        if result.returncode:
            print(result.stderr[-4000:])
        return result.returncode


if __name__ == "__main__":
    sys.exit(main())
