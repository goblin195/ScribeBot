# Benchmarks

Measured against Tape 0.9.3 on the same audio. Read the caveats — several of
these numbers are weaker than they look, and this file says so on purpose.

## Results

| Metric | Scribebot | Tape 0.9.3 | Notes |
|---|---|---|---|
| Technical terms preserved | **70.2%** | 46.8% | see "the honest finding" below |
| Word error rate | **16.5%** | 21.2% | Hebrew with embedded English terms |
| Diarization error rate | **15.4%** | 41.0% | ⚠️ synthetic audio only |
| Decode time per chunk | **0.51 s** | 1.62 s | same machine, same audio |
| Negative control | **45/45** | — | sentences passed through untouched |

## The honest finding

**The two decoders tie at 46.8% term preservation.** Running Tape's own
transcripts through Scribebot's glossary yields 70.2% terms and 16.2% word error
rate — marginally *better* than Scribebot's own output.

The advantage is therefore a **post-processing stage that Tape does not ship**,
not better Hebrew recognition. Both use comparable models. Anyone can reproduce
the gap by applying `bench/glossary.py` to any Hebrew ASR output.

This matters for planning: further gains will come from the term dictionary and
from the two-file speaker separation, not from the acoustic model.

## What each number is worth

**Term preservation and word error rate** — measured on real recorded speech,
not synthesis. Trustworthy.

**Diarization error rate** — ⚠️ **measured entirely on synthetic
text-to-speech audio.** No real multi-speaker recording has ever been scored.
The 15.4% figure should not be quoted as a product claim until a real meeting
with several people on one microphone has been measured. This is the single
largest gap in the evidence.

It also matters less than it appears: the app separates speakers by capturing
each side to its own file, so diarization is not on its normal path at all. The
number describes a component the product mostly does not use.

**Decode time** — wall-clock per chunk on the same machine. Real, but it is
throughput, not end-to-end latency behind live speech.

## A retracted claim

An earlier version of this project reported term preservation from a
text-to-speech probe: 1 term of 20. Real recorded audio gave 46.8%. The
synthetic probe was not merely imprecise, it was measuring something else. Any
number in this file marked ⚠️ carries that same risk.

A second claim — that Tape's `medium` model was weaker than
`large-v3-turbo` — was simply false and was retracted. Tape's model matches.

## Reproducing

```sh
./check                      # self-checks, including the negative control
python3 bench/score.py       # term preservation + word error rate
python3 bench/der_suite.py   # diarization error rate (synthetic clips)
```

`bench/negative_control.py` is the guard that matters most. It holds 45
sentences — adversarial Hebrew, ordinary English prose, Latin-script traps —
which the glossary must leave byte-for-byte unchanged. It exists because an
earlier fuzzy matcher scored better on the benchmark while corrupting 15.4% of
real calendar strings. **A benchmark gain that fails the negative control is a
regression.**
