#!/usr/bin/env python3
"""Diarize by clustering our own embedding windows, not pyannote's speaker labels.

run_sherpa_diar.py hands the whole job to sherpa's pipeline and loses: 29.2% DER,
two speakers where there are three. Threshold sweeps and four embedding models did
not move it, because neither was the problem. Two measurements found the real one:

  1. Ask segmentation-3.0 directly what it thinks. On the 10s window starting at
     8.0s it emits ONE local speaker for 8.03-17.95s - Carmit, then Samantha, then
     Carmit - and does not even mark the digital silences at 10.24s and 13.92s. Its
     per-window speaker labels merge the two female voices before clustering ever
     runs, so no pure embedding for either voice is ever extracted. Clustering
     cannot separate speakers it is never shown apart.
  2. Embed the ground-truth turns and compare. eres2net separates all three
     cleanly: within-speaker cosine >= 0.846, cross-speaker <= 0.523 with a 0.32
     margin. The embedding model was never the weak link.

So the segmentation model is used for what it is good at - speech vs non-speech -
and the speaker decision is made here: slice speech into 1.5s windows, embed each,
agglomerate on cosine distance. This finds three speakers unaided at 7.3% DER.

Window length is the load-bearing constant. At 2.0s a window straddles a turn
boundary often enough to produce blended embeddings and the two female voices
collapse back into one cluster (29.3%). 1.25-1.5s is a flat plateau; 1.5s is the
conservative end of it. This clip's turns are separated by clean 0.25s pauses, so
expect windows to straddle more often on real overlapping speech.

Deliberately NOT done: gating windows on frame energy. An absolute -80dBFS gate
scores 0.4% here by finding the synthetic clip's literal digital silence, but
-70dBFS scores 33.2%. That is a cliff, not a parameter, and real rooms have a
noise floor that would put the gate on the wrong side of it.
"""
import sys
import wave
from pathlib import Path

import numpy as np
import onnxruntime as ort
import sherpa_onnx
from sklearn.cluster import AgglomerativeClustering

ROOT = Path(__file__).resolve().parent.parent
SEG = ROOT / "models/diar/sherpa-onnx-pyannote-segmentation-3-0/model.onnx"
EMB = ROOT / "models/diar/emb.onnx"

FRAME = 0.01          # RTTM resolution
WINDOW = 1.5          # embedding window; see docstring before touching
HOP = 0.5
THRESHOLD = 0.48      # cosine distance to merge; flat from 0.44 to 0.52
VAD_THRESHOLD = 0.5   # P(speech) from the segmentation model
MIN_REGION = 0.2      # ignore speech islands shorter than this
MAX_BRIDGE = 0.3      # close same-speaker gaps up to this long


def read_wav(path: Path):
    with wave.open(str(path)) as w:
        assert w.getnchannels() == 1 and w.getsampwidth() == 2, "need 16-bit mono"
        sr = w.getframerate()
        data = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    return data.astype(np.float32) / 32768.0, sr


def speech_mask(audio, sr, n_frames):
    """P(speech) per 10ms frame, averaged over the model's overlapping windows.

    Class 0 of the powerset head is "nobody talking", so 1 - P(class 0) is speech
    probability without ever trusting which speaker the model picked.
    """
    sess = ort.InferenceSession(str(SEG))
    meta = sess.get_modelmeta().custom_metadata_map
    size = int(meta["window_size"])
    shift = int(meta["receptive_field_shift"])
    field = int(meta["receptive_field_size"])

    total = np.zeros(n_frames)
    count = np.zeros(n_frames)
    starts = list(range(0, max(1, len(audio) - size + 1), int(size * 0.1)))
    if starts[-1] + size < len(audio):
        starts.append(len(audio) - size)
    for start in starts:
        window = np.zeros(size, dtype=np.float32)
        chunk = audio[start:start + size]
        window[:len(chunk)] = chunk
        logits = sess.run(None, {"x": window[None, None, :]})[0][0]
        probs = np.exp(logits - logits.max(1, keepdims=True))
        probs /= probs.sum(1, keepdims=True)
        for i in range(len(probs)):
            if start + shift * i >= len(audio):
                break
            f = int((start + shift * i + field / 2) / sr / FRAME)
            if 0 <= f < n_frames:
                total[f] += 1 - probs[i, 0]
                count[f] += 1
    return np.where(count > 0, total / np.maximum(count, 1), 0) > VAD_THRESHOLD


def runs(mask):
    """Contiguous True spans of a boolean frame mask, as (start_s, end_s)."""
    out = []
    for i, on in enumerate(mask):
        if on and (i == 0 or not mask[i - 1]):
            out.append([i * FRAME, (i + 1) * FRAME])
        elif on:
            out[-1][1] = (i + 1) * FRAME
    return [(a, b) for a, b in out if b - a >= MIN_REGION]


def windows(regions):
    """Tile each speech region with WINDOW-long slices, absorbing short tails.

    A stub tail would get an embedding built from too little audio, which is
    exactly the noisy vector that fragments a cluster.
    """
    out = []
    for start, end in regions:
        if end - start <= WINDOW:
            out.append((start, end))
            continue
        t = start
        while True:
            stop = min(t + WINDOW, end)
            if end - stop < WINDOW * 0.5:
                stop = end
            out.append((t, stop))
            if stop >= end:
                break
            t += HOP
    return out


def embed(audio, sr, spans):
    extractor = sherpa_onnx.SpeakerEmbeddingExtractor(
        sherpa_onnx.SpeakerEmbeddingExtractorConfig(model=str(EMB)))
    out = []
    for start, end in spans:
        stream = extractor.create_stream()
        stream.accept_waveform(sr, audio[int(start * sr):int(end * sr)])
        stream.input_finished()
        v = np.array(extractor.compute(stream))
        out.append(v / np.linalg.norm(v))
    return np.array(out)


def bridge_gaps(labels):
    """Fill unlabelled runs whose two sides agree, up to MAX_BRIDGE long.

    Both neighbours name the same speaker, so filling can only recover missed
    speech - it can never introduce confusion. That asymmetry is why the length
    limit is a comfort rather than a tuned parameter.
    """
    labels = labels.copy()
    i = 0
    while i < len(labels):
        if labels[i] != -1:
            i += 1
            continue
        j = i
        while j < len(labels) and labels[j] == -1:
            j += 1
        if 0 < i < j < len(labels) and labels[i - 1] == labels[j] \
                and (j - i) * FRAME <= MAX_BRIDGE:
            labels[i:j] = labels[i - 1]
        i = j
    return labels


def diarize(audio, sr, n_speakers=0):
    n_frames = int(len(audio) / sr / FRAME) + 1
    mask = speech_mask(audio, sr, n_frames)
    regions = runs(mask)
    assert regions, "segmentation model found no speech"
    spans = windows(regions)
    vectors = embed(audio, sr, spans)

    # n_speakers > 0 pins the count from the calendar attendee list (meetings.json
    # carries one per meeting). It buys nothing on clean audio - identical 7.3% to
    # letting the threshold decide - but it is what holds the system up in noise:
    # at 10dB SNR the fixed threshold over-splits into 5 clusters for 24.6% DER,
    # and pinning the count brings that back to 6.9%. Pass it whenever it is known.
    kwargs = ({"n_clusters": n_speakers} if n_speakers > 0
              else {"n_clusters": None, "distance_threshold": THRESHOLD})
    cluster = AgglomerativeClustering(
        metric="cosine", linkage="average", **kwargs).fit_predict(vectors)

    votes = np.zeros((n_frames, cluster.max() + 1))
    for (start, end), c in zip(spans, cluster):
        votes[int(start / FRAME):int(end / FRAME), c] += 1
    centres = np.array([(a + b) / 2 for a, b in spans])
    labels = np.full(n_frames, -1)
    for f in range(n_frames):
        if not mask[f]:
            continue
        labels[f] = (votes[f].argmax() if votes[f].sum() > 0
                     else cluster[np.abs(centres - f * FRAME).argmin()])
    return bridge_gaps(labels)


def to_segments(labels):
    out = []
    for f, c in enumerate(labels):
        if f and c == labels[f - 1]:
            out[-1][1] = (f + 1) * FRAME
        else:
            out.append([f * FRAME, (f + 1) * FRAME, c])
    return [(a, b, c) for a, b, c in out if c >= 0 and b - a >= 0.1]


def self_check():
    """Frame bookkeeping is the only place a silent off-by-one can hide."""
    assert runs(np.array([0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0],
                         dtype=bool)) == [(0.01, 0.22)]
    assert runs(np.array([1, 1, 0], dtype=bool)) == [], "0.02s island must be dropped"

    # tails shorter than half a window get absorbed rather than embedded alone
    assert windows([(0.0, 1.2)]) == [(0.0, 1.2)]
    assert [round(b - a, 2) for a, b in windows([(0.0, 5.0)])][-1] >= WINDOW * 0.5

    same = bridge_gaps(np.array([7, 7, -1, -1, 7, 7]))
    assert (same == 7).all(), "same-speaker gap must close"
    diff = bridge_gaps(np.array([7, 7, -1, -1, 3, 3]))
    assert diff[2] == -1 and diff[3] == -1, "never bridge across a speaker change"
    wide = bridge_gaps(np.array([7] + [-1] * 40 + [7]))
    assert wide[1] == -1, "gap longer than MAX_BRIDGE must stay open"

    assert to_segments(np.array([-1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, -1])) == \
        [(0.01, 0.13, 0)]
    print("self-check ok")


def main():
    if "--self-check" in sys.argv:
        return self_check()
    audio_path = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "bench/diar/meeting.wav"
    out = Path(sys.argv[2]) if len(sys.argv) > 2 else ROOT / "bench/diar/ours.rttm"
    n_speakers = int(sys.argv[3]) if len(sys.argv) > 3 else 0

    audio, sr = read_wav(audio_path)
    assert sr == 16000, f"models are 16 kHz, got {sr}"
    segments = to_segments(diarize(audio, sr, n_speakers))
    with out.open("w") as f:
        for start, end, c in segments:
            f.write(f"SPEAKER meeting 1 {start:.3f} {end - start:.3f} "
                    f"<NA> <NA> spk{c} <NA> <NA>\n")
    print(f"{len({c for _, _, c in segments})} speakers, {len(segments)} segments "
          f"-> {out}", file=sys.stderr)


if __name__ == "__main__":
    main()
