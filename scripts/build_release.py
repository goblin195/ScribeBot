#!/usr/bin/env python3
"""Build the complete arm64 DMG using prepared, pinned runtime inputs.

See docs/RELEASING.md. All staging happens under .build; user data is never read.
"""
import hashlib
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile

ROOT = Path(__file__).resolve().parent.parent
BUILD = ROOT / '.build'
INPUTS = BUILD / 'release-inputs'
STAGE = BUILD / 'dmg-root'
APP = STAGE / 'Scribebot.app'
RUNTIME = APP / 'Contents/Resources/Runtime'
PYTHON_SHA = '81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b'


def run(*args):
    subprocess.run([str(a) for a in args], check=True, cwd=ROOT)


def copy(source, destination):
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source, destination)


def main():
    archive = INPUTS / 'cpython-3.12.14+20260901-aarch64-apple-darwin-install_only_stripped.tar.gz'
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == PYTHON_SHA, 'Python checksum mismatch'
    if STAGE.exists():
        raise SystemExit('Staging directory already exists. Preserve or remove .build/dmg-root before rebuilding.')
    RUNTIME.mkdir(parents=True)
    copy(ROOT / 'app/Info.plist', APP / 'Contents/Info.plist')
    with (APP / 'Contents/Info.plist').open('rb') as f:
        assert plistlib.load(f)['CFBundleShortVersionString'] == '0.1'
    copy(ROOT / 'app/icon/Scribebot.icns', APP / 'Contents/Resources/Scribebot.icns')
    binary = APP / 'Contents/MacOS/Scribebot'
    binary.parent.mkdir(parents=True)
    run('swiftc', '-target', 'arm64-apple-macos14.2', '-parse-as-library',
        '-module-cache-path', BUILD / 'swift-module-cache', '-o', binary,
        *sorted((ROOT / 'app/Sources').glob('*.swift')))
    for name in ['scribebot.py', 'live.py', 'stream.py', 'toolpaths.py', 'meeting.py', 'summarize.py', 'export.py', 'attribute.py']:
        copy(ROOT / name, RUNTIME / name)
    for name in ['glossary.py', 'aliases.json']:
        copy(ROOT / 'bench' / name, RUNTIME / 'bench' / name)
    # The calendar index and harvested vocabulary are intentionally not shipped.
    copy(ROOT / 'models/ivrit-large-v3-turbo.bin', RUNTIME / 'models/ivrit-large-v3-turbo.bin')
    copy(BUILD / 'whisper-build/bin/whisper-cli', RUNTIME / 'bin/whisper-cli')
    shutil.copytree(INPUTS / 'python', RUNTIME / 'python', symlinks=True)
    helper = RUNTIME / 'capture/ScribebotCapture.app'
    copy(ROOT / 'capture/ScribebotCapture.app/Contents/Info.plist', helper / 'Contents/Info.plist')
    helper_binary = helper / 'Contents/MacOS/ScribebotCapture'
    helper_binary.parent.mkdir(parents=True)
    run('swiftc', '-target', 'arm64-apple-macos14.2', '-O', '-module-cache-path',
        BUILD / 'swift-module-cache', '-o', helper_binary, ROOT / 'capture/tap.swift')
    licenses = APP / 'Contents/Resources/Licenses'
    copy(ROOT / 'LICENSE', licenses / 'Scribebot-MIT')
    copy(BUILD / 'whisper-source/LICENSE', licenses / 'Whisper-MIT')
    copy(ROOT / 'docs/release/THIRD-PARTY.md', licenses / 'THIRD-PARTY.md')
    copy(INPUTS / 'python/lib/python3.12/site-packages/pip/_vendor/packaging/LICENSE.APACHE', licenses / 'Apache-2.0')
    with tarfile.open(INPUTS / 'python-build-licenses.tar.gz') as tar:
        for member in tar.getmembers():
            name = Path(member.name).name
            if member.isfile() and name.startswith('LICENSE') and len(Path(member.name).parts) == 2:
                data = tar.extractfile(member).read()
                destination = licenses / 'Python' / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                destination.write_bytes(data)
    # Sign nested Mach-O files first, including Python extension modules.
    magic = {b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca'}
    for path in sorted(APP.rglob('*')):
        if path.is_file() and not path.is_symlink():
            with path.open('rb') as f:
                is_macho = f.read(4) in magic
            if is_macho:
                run('codesign', '--force', '-s', '-', path)
    run('codesign', '--force', '-s', '-', '-i', 'dev.scribebot.capture', helper)
    run('codesign', '--force', '-s', '-', '-i', 'dev.scribebot.app', APP)
    run('codesign', '--verify', '--deep', '--strict', APP)
    copy(ROOT / 'docs/release/INSTALL.md', STAGE / 'Read Me.md')
    (STAGE / 'Applications').symlink_to('/Applications')
    dmg = BUILD / 'Scribebot-0.1-macOS-arm64.dmg'
    if dmg.exists():
        raise SystemExit('Release DMG already exists; refusing to overwrite it.')
    run('hdiutil', 'create', '-volname', 'Scribebot 0.1', '-srcfolder', STAGE,
        '-format', 'UDZO', '-ov', dmg)
    run('hdiutil', 'verify', dmg)
    checksum = hashlib.sha256(dmg.read_bytes()).hexdigest()
    (BUILD / 'SHA256SUMS').write_text(f'{checksum}  {dmg.name}\n')
    print(f'Release ready: {dmg}')


if __name__ == '__main__':
    main()
