#!/usr/bin/env python3
"""Read-only bundle checks plus decoder tests using temporary public sample audio.

Usage: smoke_release.py <Scribebot.app> <sample.wav> [models-dir]

The models directory defaults to the checkout's own models/. Nothing here reads
or writes the real support directory: SCRIBEBOT_SUPPORT points the decode test
at a temporary one, exactly as first-run setup would have filled it in.
"""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
app = Path(sys.argv[1]).resolve()
sample = Path(sys.argv[2]).resolve()
models = Path(sys.argv[3]).resolve() if len(sys.argv) > 3 else ROOT / 'models'
runtime = app / 'Contents/Resources/Runtime'
python = runtime / 'python/bin/python3'
assert python.is_file()
# 0.1 shipped the model inside the bundle and the DMG was 1.4 GB. It is
# downloaded at first run now, and putting it back would break the signature
# checked below - so its absence is an invariant, not an omission.
assert not (runtime / 'models').exists(), 'A model was staged into the bundle.'
assert not (runtime / 'bench/meetings.json').exists()
assert not (runtime / 'bench/vocab.json').exists()
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(app)], check=True)
with tempfile.TemporaryDirectory(prefix='scribebot-release-') as temp:
    # Stand in for a finished first-run download. Symlinked, not copied: 1.5 GB
    # per smoke run is absurd, and the decoder only reads it.
    support = Path(temp) / 'Support'
    (support / 'models').mkdir(parents=True)
    for name in ['ivrit-large-v3-turbo.bin', 'vanilla-large-v3-turbo.bin']:
        if (models / name).is_file():
            (support / 'models' / name).symlink_to(models / name)
    assert any((support / 'models').iterdir()), f'no model to test the decoder with in {models}'
    env = {'HOME': temp, 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'PYTHONDONTWRITEBYTECODE': '1',
           'SCRIBEBOT_SUPPORT': str(support)}
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
