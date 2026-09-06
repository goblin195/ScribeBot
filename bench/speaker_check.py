#!/usr/bin/env python3
"""Speaker assignment behavior with synthetic timing fixtures; no accuracy claims."""
import json
from pathlib import Path
import subprocess
import sys
import os
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from speaker_transcript import assemble, speaker_at, speech_windows
import scribebot


def main():
    turns = [(i * 3, i * 3 + 2, f"remote-{i + 1}") for i in range(8)]
    words = [dict(start=i * 3 + 0.1, end=i * 3 + 1, text=f"עברית {i}") for i in range(8)]
    result = assemble(words, turns, "system")
    assert len({s["speaker"] for s in result}) == 8
    assert [s["rawText"] for s in result] == [w["text"] for w in words]
    assert speaker_at(0, 2, [(0, 2, "a"), (0.5, 2, "b")]) == "remote-unknown"
    assert speaker_at(10, 12, turns[:1]) == "remote-unknown"
    assert speaker_at(0, 10, [(0, 1, "a")]) == "remote-unknown"
    local = assemble(words, turns, "microphone", lambda s: s.replace("עברית", "English"))
    assert all(s["speaker"] == "local" for s in local)
    assert local[0]["rawText"].startswith("עברית") and local[0]["text"].startswith("English")
    assert speech_windows([(1, 2, 'a'), (1.5, 3, 'b'), (10, 11, 'a')], 12) == [(0.8, 3.2), (9.8, 11.2)]
    windows = speech_windows([(0, 157, 'a')], 157)
    assert max(b-a for a,b in windows) <= 20
    assert sum(b-a for a,b in windows) == 157
    bounded = assemble([dict(start=i*5,end=i*5+5,text='Synthetic sentence.') for i in range(30)], [], 'microphone')
    assert max(s['end']-s['start'] for s in bounded) <= 15
    try:
        assemble([dict(start=2, end=2, text='zero')], [], 'system')
        raise AssertionError('zero duration accepted')
    except ValueError:
        pass
    try:
        assemble([dict(start=float('nan'), end=2, text="bad")], [], "system")
        raise AssertionError("invalid timestamp accepted")
    except ValueError:
        pass

    # ASR sidecars live in a temporary directory and requested language reaches
    # the decoder. A subprocess failure must never look like successful silence.
    output_path = None
    def decode(argv, **kwargs):
        nonlocal output_path
        assert argv[argv.index('-l') + 1] == 'he'
        assert argv[argv.index('-ml') + 1] == '1'
        output_path = Path(argv[argv.index('-of') + 1] + '.json')
        assert output_path.parent != ROOT
        output_path.write_text(json.dumps({'transcription': [dict(text='שלום', offsets={'from': 100, 'to': 800})]}))
        return subprocess.CompletedProcess(argv, 0, '', '')
    with patch.object(scribebot.languages, 'resolve', return_value=(ROOT / 'scribebot.py', 'he')), \
         patch.object(scribebot.languages, 'upgrade', return_value=None), \
         patch.object(scribebot.subprocess, 'run', side_effect=decode):
        assert scribebot.transcribe_segments(ROOT / 'unused.wav', 'he', words=True)[0]['start'] == .1
    assert not output_path.exists()
    with patch.object(scribebot.languages, 'resolve', return_value=(ROOT / 'scribebot.py', 'he')), \
         patch.object(scribebot.languages, 'upgrade', return_value=None), \
         patch.object(scribebot.subprocess, 'run', return_value=subprocess.CompletedProcess([], 1, '', 'decoder failed')):
        try:
            scribebot.transcribe_segments(ROOT / 'unused.wav', 'he')
            raise AssertionError('failed decode accepted')
        except RuntimeError:
            pass
    print('speaker self-check passed (8 synthetic voices, uncertainty, raw text, process handling)')


if __name__ == '__main__':
    with tempfile.TemporaryDirectory() as temp, patch.dict(os.environ, SCRIBEBOT_SUPPORT=temp):
        main()
