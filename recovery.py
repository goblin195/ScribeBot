"""Build a decoder-readable temporary WAV without modifying saved audio.

Only Scribebot's PCM16 mono/16 kHz format is recoverable here. Interrupted
writers may leave a zero or stale RIFF/data size, but the format chunk and
sample bytes must exist. Unknown or ambiguous layouts fail explicitly.
"""
from contextlib import contextmanager
import os
from pathlib import Path
import stat
import struct
import tempfile
import wave
from userdata import processing_dir


@contextmanager
def recovered_audio(source: Path):
    fd = os.open(source, os.O_RDONLY | os.O_NOFOLLOW)
    with os.fdopen(fd, "rb") as src:
        before = os.fstat(src.fileno())
        if not stat.S_ISREG(before.st_mode):
            raise ValueError("Recovery requires a regular audio file")
        header = src.read(12)
        if len(header) != 12 or header[:4] != b"RIFF" or header[8:] != b"WAVE":
            raise ValueError("Recovery requires a RIFF WAV header")
        riff_size = struct.unpack_from("<I", header, 4)[0]
        fmt = None
        offset = 12
        while offset + 8 <= before.st_size:
            src.seek(offset)
            chunk = src.read(8)
            if len(chunk) != 8:
                raise ValueError("Audio changed during recovery")
            kind, size = struct.unpack("<4sI", chunk)
            payload = offset + 8
            if kind == b"fmt ":
                if size < 16 or size > 4096:
                    raise ValueError("Invalid WAV format chunk")
                body = src.read(16)
                if len(body) != 16:
                    raise ValueError("Truncated WAV format")
                fmt = struct.unpack("<HHIIHH", body)
            if kind == b"data":
                if fmt != (1, 1, 16000, 32000, 2, 16):
                    raise ValueError("Only Scribebot PCM16 mono/16 kHz audio can be recovered")
                available = before.st_size - payload
                # Healthy WAVs may have metadata after data. Keep their declared
                # data length. Expand a stale header only when data was last.
                if size == 0 or riff_size == 0:
                    count = available
                elif payload + size > before.st_size:
                    count = available
                elif riff_size + 8 < before.st_size:
                    if payload + size != riff_size + 8:
                        raise ValueError("Ambiguous WAV tail; refusing to treat metadata as speech")
                    count = available
                else:
                    count = size
                count -= count % 2  # a crash may leave one incomplete PCM sample
                if not count:
                    raise ValueError("No saved audio samples to recover")
                with tempfile.TemporaryDirectory(prefix="recover-", dir=processing_dir()) as temp:
                    out = Path(temp) / "audio.wav"
                    src.seek(payload)
                    with wave.open(str(out), "wb") as dst:
                        dst.setnchannels(1)
                        dst.setsampwidth(2)
                        dst.setframerate(16000)
                        remaining = count
                        while remaining:
                            data = src.read(min(remaining, 1024 * 1024))
                            if not data:
                                raise ValueError("Audio changed during recovery")
                            dst.writeframesraw(data)
                            remaining -= len(data)
                    after = os.fstat(src.fileno())
                    if (before.st_size, before.st_mtime_ns) != (after.st_size, after.st_mtime_ns):
                        raise ValueError("Audio is still changing; stop recording before retrying")
                    yield out
                return
            if payload + size > before.st_size:
                raise ValueError("Truncated WAV chunk before audio")
            offset = payload + size + size % 2
        raise ValueError("No recoverable WAV data chunk")
