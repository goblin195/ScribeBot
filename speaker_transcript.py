#!/usr/bin/env python3
"""Local speaker turns and chronological ASR. Originals are opened read-only.

Speaker numbers are scoped to one analysis, not identities across meetings.
Names must be assigned explicitly by a person, never inferred from invitations.
"""
import argparse
import json
import math
from pathlib import Path
import sys
import uuid
import wave
import tempfile

ROOT = Path(__file__).resolve().parent


def diarize(audio, count=0, threshold=0.5):
    try:
        import numpy as np
        import sherpa_onnx
    except ImportError as error:
        raise RuntimeError("Speaker separation needs the local sherpa-onnx Python runtime.") from error
    segmentation = ROOT / "models/diar/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
    embedding = ROOT / "models/diar/wespeaker_en_voxceleb_resnet34_LM.onnx"
    if not segmentation.is_file() or not embedding.is_file():
        raise RuntimeError("Speaker separation models are missing from models/diar.")
    config = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(model=str(segmentation))),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(embedding)),
        clustering=sherpa_onnx.FastClusteringConfig(num_clusters=count if count else -1, threshold=threshold),
        min_duration_on=0.2, min_duration_off=0.3,
    )
    if not config.validate():
        raise RuntimeError("Invalid local speaker model configuration.")
    model = sherpa_onnx.OfflineSpeakerDiarization(config)
    with wave.open(str(audio)) as wav:
        if (wav.getnchannels(), wav.getsampwidth(), wav.getframerate()) != (1, 2, model.sample_rate):
            raise ValueError("Speaker separation requires mono PCM16 at 16 kHz.")
        samples = np.frombuffer(wav.readframes(wav.getnframes()), dtype=np.int16).astype(np.float32) / 32768
    turns = model.process(samples).sort_by_start_time()
    durations = {}
    for turn in turns:
        durations[turn.speaker] = durations.get(turn.speaker, 0) + turn.end - turn.start
    # Cluster integers are implementation details; number by first appearance.
    labels = {}
    result = []
    for turn in turns:
        # Tiny clusters often come from overlap/noise. Keep their speech but do
        # not present a new identity supported by less than two seconds of voice.
        label = (labels.setdefault(turn.speaker, f"remote-{len(labels) + 1}")
                 if durations[turn.speaker] >= 2 else "remote-unknown")
        result.append((float(turn.start), float(turn.end), label))
    return result


def speaker_at(start, end, turns):
    scores = {}
    for a, b, speaker in turns:
        overlap = max(0, min(end, b) - max(start, a))
        scores[speaker] = scores.get(speaker, 0) + overlap
    ranked = sorted(scores.items(), key=lambda item: item[1], reverse=True)
    duration = max(end - start, 0.001)
    if not ranked or ranked[0][1] < duration * 0.5:
        return "remote-unknown"
    if len(ranked) > 1 and ranked[1][1] > duration * 0.25:
        return "remote-unknown"
    return ranked[0][0]


def assemble(words, turns, source, restore=lambda value: value):
    out = []
    for word in words:
        start, end = float(word["start"]), float(word["end"])
        raw = word["text"].strip()
        if not raw:
            continue
        if not math.isfinite(start) or not math.isfinite(end) or start < 0 or end <= start:
            raise ValueError("Invalid recognition timestamps")
        speaker = "local" if source == "microphone" else speaker_at(start, end, turns)
        if (out and out[-1]["speaker"] == speaker and 0 <= start - out[-1]["end"] <= 0.8
                and end - out[-1]["start"] <= 15):
            out[-1]["rawText"] += " " + raw
            out[-1]["end"] = end
        else:
            out.append(dict(id=f"{source}-{len(out)}", source=source, speaker=speaker,
                            start=start, end=end, rawText=raw, text=""))
    for segment in out:
        segment["text"] = restore(segment["rawText"])
    return out


def speech_windows(turns, duration, maximum=20):
    """Union detected speech; preserve real gaps and bound decoder context.

    Overlapping voices are decoded once, never duplicated into both labels.
    Padding protects quiet starts/ends. The source timeline remains unchanged.
    """
    merged = []
    for start, end, _ in sorted(turns):
        start, end = max(0, start - 0.2), min(duration, end + 0.2)
        if end <= start:
            continue
        if merged and start <= merged[-1][1] + 0.3:
            merged[-1][1] = max(end, merged[-1][1])
        else:
            merged.append([start, end])
    windows = []
    for start, end in merged:
        while end - start > maximum:
            windows.append((start, start + maximum))
            start += maximum
        if end > start:
            windows.append((start, end))
    return windows


def decode_speech(audio, turns):
    from scribebot import transcribe_segments
    from userdata import processing_dir
    result = []
    with wave.open(str(audio)) as source:
        rate = source.getframerate()
        windows = speech_windows(turns, source.getnframes() / rate)
        with tempfile.TemporaryDirectory(prefix="speech-", dir=processing_dir()) as temp:
            clip = Path(temp) / "speech.wav"
            for start, end in windows:
                first, last = int(start * rate), int(end * rate)
                source.setpos(first)
                with wave.open(str(clip), "wb") as out:
                    out.setparams(source.getparams())
                    out.writeframes(source.readframes(last - first))
                # Normal ASR segments, not -ml 1 fragments. The latter assigns
                # zero duration to many words and is not forced alignment.
                for item in transcribe_segments(clip):
                    a, b = max(0, item['start']), min(end - start, item['end'])
                    if b <= a:
                        raise RuntimeError("Decoder returned invalid speech timing; keeping the previous transcript.")
                    result.append(dict(start=start + a, end=start + b, text=item['text']))
    return result


def analyze(system, microphone, count=0):
    from recovery import recovered_audio
    from scribebot import is_silent, load_glossary
    restorer, _ = load_glossary()
    segments = []
    for source, path in [("system", system), ("microphone", microphone)]:
        with recovered_audio(path) as copy:
            if is_silent(copy):
                continue
            turns = diarize(copy, count if source == "system" else 1)
            if not turns:
                continue
            words = decode_speech(copy, turns)
            if not words:
                raise RuntimeError(f"No timestamped text returned for the non-silent {source} track; keeping the previous transcript.")
            segments.extend(assemble(words, turns, source, restorer.restore))
    segments.sort(key=lambda item: (item["start"], item["source"], item["end"]))
    speakers = {item["speaker"] for item in segments}
    names = {speaker: ("You" if speaker == "local" else "Uncertain speaker" if speaker == "remote-unknown"
                       else "Speaker " + speaker.split("-")[1]) for speaker in speakers}
    warnings = ["Speaker labels and timestamps are estimates. Short voice clusters and overlapping speech may remain uncertain."]
    if not count:
        warnings.append("Speaker count is automatic; set the number of remote speakers if voices are split or merged.")
    return dict(version=1, revision=str(uuid.uuid4()), segments=segments, names=names,
                engine="speech-windows-v2/sherpa-onnx/pyannote-3.0/wespeaker-resnet34; threshold=0.5",
                remoteSpeakerCount=count, warnings=warnings)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("system", type=Path)
    parser.add_argument("microphone", type=Path)
    parser.add_argument("--remote-speakers", type=int, default=0)
    args = parser.parse_args()
    if not 0 <= args.remote_speakers <= 100:
        parser.error("Remote speaker count must be 0 (automatic) or 1–100")
    try:
        print(json.dumps(analyze(args.system, args.microphone, args.remote_speakers), ensure_ascii=False))
    except Exception as error:
        sys.exit(f"Speaker separation failed: {error}")


if __name__ == "__main__":
    main()
