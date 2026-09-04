#!/usr/bin/env python3
"""Diarize with sherpa-onnx and emit RTTM.

pyannote's published 3.1 pipeline is gated and its 4.x default pulls a gated
community model, so the same architecture is assembled here from ONNX weights
that are not gated: pyannote segmentation 3.0 plus a speaker embedding model.
Runs fully offline once fetched, which is the point of the product.
"""
import sys
from pathlib import Path
import sherpa_onnx
import wave, numpy as np

ROOT = Path(__file__).resolve().parent.parent
SEG = ROOT / "models/diar/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
# 3dspeaker eres2net. Counter-intuitively this beat the English VoxCeleb models
# on the bilingual clip (29.2% DER against 42-44%), so it stays until a larger
# multi-speaker set says otherwise.
EMB = ROOT / "models/diar/emb.onnx"

def read_wav(p: Path):
    with wave.open(str(p)) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2
        sr = w.getframerate()
        d = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return d.astype(np.float32) / 32768.0, sr

def main():
    audio = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "bench/diar/meeting.wav"
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "bench/diar/ours.rttm"
    nspk = int(sys.argv[3]) if len(sys.argv) > 3 else 0
    thr = float(sys.argv[4]) if len(sys.argv) > 4 else 0.5
    on = float(sys.argv[5]) if len(sys.argv) > 5 else 0.2
    off = float(sys.argv[6]) if len(sys.argv) > 6 else 0.3

    cfg = sherpa_onnx.OfflineSpeakerDiarizationConfig(
        segmentation=sherpa_onnx.OfflineSpeakerSegmentationModelConfig(
            pyannote=sherpa_onnx.OfflineSpeakerSegmentationPyannoteModelConfig(
                model=str(SEG))),
        embedding=sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMB)),
        clustering=sherpa_onnx.FastClusteringConfig(
            num_clusters=nspk if nspk > 0 else -1,
            threshold=thr),
        min_duration_on=on,
        min_duration_off=off,
    )
    if not cfg.validate():
        sys.exit("invalid sherpa-onnx diarization config")
    sd = sherpa_onnx.OfflineSpeakerDiarization(cfg)
    samples, sr = read_wav(audio)
    assert sr == sd.sample_rate, f"need {sd.sample_rate} Hz, got {sr}"
    result = sd.process(samples).sort_by_start_time()
    with out.open("w") as f:
        for seg in result:
            f.write(f"SPEAKER meeting 1 {seg.start:.3f} {seg.end - seg.start:.3f} "
                    f"<NA> <NA> spk{seg.speaker} <NA> <NA>\n")
    print(f"{len({s.speaker for s in result})} speakers, {len(result)} segments "
          f"-> {out}", file=sys.stderr)

if __name__ == "__main__":
    main()
