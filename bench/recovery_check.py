#!/usr/bin/env python3
"""Recovery preserves source bytes and rejects unknown WAV layouts."""
import hashlib
import struct
import sys
import tempfile
from pathlib import Path
import wave

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from recovery import recovered_audio


def main():
    with tempfile.TemporaryDirectory(prefix="scribebot-recovery-check-") as temp:
        root = Path(temp)
        path = root / "audio.wav"
        pcm = b"\x02\x01" * 32000
        with wave.open(str(path), "wb") as wav:
            wav.setnchannels(1)
            wav.setsampwidth(2)
            wav.setframerate(16000)
            wav.writeframes(pcm)
        healthy = path.read_bytes()
        cases = [healthy]
        blank = bytearray(healthy)
        struct.pack_into("<I", blank, 4, 36)
        struct.pack_into("<I", blank, 40, 0)
        cases.append(bytes(blank))
        stale = bytearray(healthy)
        struct.pack_into("<I", stale, 4, 36 + 4000)
        struct.pack_into("<I", stale, 40, 4000)
        cases.append(bytes(stale))
        # A healthy WAV with a trailing metadata chunk must not decode metadata.
        metadata = b"LIST" + struct.pack("<I", 4) + b"test"
        trailing = bytearray(healthy + metadata)
        struct.pack_into("<I", trailing, 4, len(trailing) - 8)
        cases.append(bytes(trailing))
        for data in cases:
            path.write_bytes(data)
            before = hashlib.sha256(data).digest()
            with recovered_audio(path) as copy:
                assert copy != path
                with wave.open(str(copy), "rb") as wav:
                    assert wav.getnframes() == 32000
                    assert wav.readframes(32000) == pcm
            assert not copy.exists()
            assert hashlib.sha256(path.read_bytes()).digest() == before

        for invalid in [b"not a WAV", healthy[:24], healthy[:12]]:
            path.write_bytes(invalid)
            try:
                with recovered_audio(path):
                    raise AssertionError("invalid input was accepted")
            except ValueError:
                pass
            assert path.read_bytes() == invalid
        other_rate = bytearray(healthy)
        struct.pack_into("<I", other_rate, 24, 48000)
        path.write_bytes(other_rate)
        try:
            with recovered_audio(path):
                raise AssertionError("unknown format was accepted")
        except ValueError:
            pass
        link = root / "linked.wav"
        link.symlink_to(path)
        try:
            with recovered_audio(link):
                raise AssertionError("symlink was followed")
        except OSError:
            pass
    print("recovery self-check passed (synthetic PCM; originals unchanged)")


if __name__ == "__main__":
    main()
