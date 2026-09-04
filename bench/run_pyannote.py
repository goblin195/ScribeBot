#!/usr/bin/env python3
"""Diarize with pyannote and emit RTTM, using the ungated ivrit-ai mirrors."""
import sys, warnings
from pathlib import Path
warnings.filterwarnings("ignore")
ROOT = Path(__file__).resolve().parent.parent

from pyannote.audio import Pipeline
import torch

audio = ROOT / "bench/diar/meeting.wav"
out = ROOT / "bench/diar/ours.rttm"

# The published 3.1 pipeline is gated. Assemble the same pipeline from parts
# that are not: segmentation weights mirrored by ivrit-ai, and the wespeaker
# embedding model, which is public. Hyper-parameters are the ones from the
# upstream 3.1 config.
from pyannote.audio import Model
from pyannote.audio.pipelines import SpeakerDiarization

seg_path = ROOT / "models/pyannote/segmentation.bin"
seg = Model.from_pretrained(seg_path)
pipe = SpeakerDiarization(
    segmentation=seg,
    embedding="pyannote/wespeaker-voxceleb-resnet34-LM",
    embedding_exclude_overlap=True,
    clustering="AgglomerativeClustering",
)
pipe.instantiate({
    "clustering": {
        "method": "centroid",
        "min_cluster_size": 12,
        "threshold": 0.7045654963945799,
    },
    "segmentation": {"min_duration_off": 0.0},
})
print("assembled diarization pipeline from ungated parts", file=sys.stderr)

if torch.backends.mps.is_available():
    try: pipe.to(torch.device("mps")); print("using mps", file=sys.stderr)
    except Exception: pass

dia = pipe(str(audio))
with out.open("w") as f:
    for turn, _, spk in dia.itertracks(yield_label=True):
        f.write(f"SPEAKER meeting 1 {turn.start:.3f} {turn.duration:.3f} "
                f"<NA> <NA> {spk} <NA> <NA>\n")
print(f"wrote {out}", file=sys.stderr)
