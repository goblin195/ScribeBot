#!/usr/bin/env python3
"""Read-only bundle checks plus decoder tests using temporary public sample audio."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

app = Path(sys.argv[1]).resolve()
sample = Path(sys.argv[2]).resolve()
runtime = app / 'Contents/Resources/Runtime'
python = runtime / 'python/bin/python3'
assert python.is_file()
assert (runtime / 'models/ivrit-large-v3-turbo.bin').stat().st_size > 1_000_000_000
assert not (runtime / 'bench/meetings.json').exists()
assert not (runtime / 'bench/vocab.json').exists()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
with tempfile.TemporaryDirectory(prefix='scribebot-release-') as temp:
    env = {'HOME': temp, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'PYTHONDONTWRITEBYTECODE': '1'}
    wav = Path(temp) / 'sample.wav'
    shutil.copy2(sample, wav)
    def run(*args):
        result = subprocess.run([str(python), '-B', *map(str, args)], cwd=temp,
                                env=env, capture_output=True, text=True, timeout=120)
        if result.returncode:
            raise RuntimeError(result.stderr[-3000:])
        return result.stdout
    run('-c', 'import ssl, sqlite3, ctypes, lzma, bz2; print("stdlib OK")')
    transcript = run(runtime / 'scribebot.py', 'file', wav, '--raw')
    assert len(transcript.strip()) > 20, 'Empty transcription'
    print('Bundled decode OK with a minimal PATH and temporary HOME')
    run(runtime / 'summarize.py', '--selftest')
    run(runtime / 'export.py', '--selftest')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
print('Bundle signature intact after running Python; no personal data bundled')
