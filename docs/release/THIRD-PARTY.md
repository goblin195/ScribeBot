# Bundled components

- Scribebot 0.1: MIT (Scribebot-MIT).
- whisper.cpp b4938, commit 371b5a7561823ab2bb32142d2751e35e7534727b,
  with its matching GGML and embedded Metal shaders: MIT (Whisper-MIT).
  https://github.com/ggml-org/whisper.cpp
- CPython 3.12.14, python-build-standalone 20260901, arm64 macOS:
  Python and dependency notices are in Python/ and in Runtime/python.
  https://github.com/astral-sh/python-build-standalone
- ivrit-ai/whisper-large-v3-turbo: Apache-2.0 (Apache-2.0).
  https://huggingface.co/ivrit-ai/whisper-large-v3-turbo
  The included model is a GGML conversion of the Hebrew fine-tune; it is not
  the original Transformers file format. Original model by ivrit.ai, based on
  OpenAI Whisper large-v3-turbo.

Audio and inference stay on the Mac. Optional summaries use a separately
installed local Ollama service. No personal vocabulary or calendar export is
included in the installer.
