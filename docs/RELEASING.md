# Building a release

The distributable is separate from the lightweight app/build.sh development
build. It includes a portable Python runtime, a statically linked Whisper CLI,
and its matching GGML/embedded Metal library. Only explicitly listed runtime
files are copied; personal calendar indexes are excluded.

**No speech model ships in the DMG.** 0.1 bundled
`models/ivrit-large-v3-turbo.bin` and 1.4 GB of a 1.5 GB installer was that one
file. The app downloads a model during first-run setup instead, into
`~/Library/Application Support/Scribebot/models/`. It deliberately does not go
into the bundle: adding a file under `Contents/Resources` after signing breaks
the seal, and macOS refuses the next launch. `build_release.py` asserts the
bundle has no `Runtime/models` directory, and `smoke_release.py` asserts the
same on the built app.

The two models the setup flow offers, verified 2026-09-05 (`curl -sIL`, HTTP
200, and the SHA-256s below match the two files this project decodes with):

| File the app expects | Source | Bytes | SHA-256 |
|---|---|---|---|
| `ivrit-large-v3-turbo.bin` | `https://huggingface.co/ivrit-ai/whisper-large-v3-turbo-ggml/resolve/main/ggml-model.bin` | 1624555275 | `c8090411113357097bfafc2b8e228ec1639fa7f5fe4ecb5d054ac0ccef8641b1` |
| `vanilla-large-v3-turbo.bin` | `https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin` | 1624555275 | `1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69` |

These are duplicated in `app/Sources/ModelSetup.swift`, which is the copy the
app actually uses. Hugging Face publishes the SHA-256 as the LFS object id, so
before changing either row re-check it against
`https://huggingface.co/api/models/<repo>/paths-info/main`. A URL that 404s on
a stranger's first launch is the whole risk of taking the model out of the
installer.

Requirements: Apple Silicon, Xcode command-line tools, Python 3.10+, CMake,
and gh. Prepare these inputs under .build:

- release-inputs/python/: extract python-build-standalone's
  `cpython-3.12.14+20260901-aarch64-apple-darwin-install_only_stripped.tar.gz`.
  Keep the archive alongside the extracted directory. Expected SHA-256:
  `81a359f1cfadd4da11766534c5913791cea55f26e1bb902cacd2a531bb1e4b2b`.
- release-inputs/python-build-licenses.tar.gz: upstream
  astral-sh/python-build-standalone source tarball containing LICENSE files.
- whisper-source/: ggml-org/whisper.cpp at b4938,
  commit `371b5a7561823ab2bb32142d2751e35e7534727b`.
- whisper-build/: configure that source with CMake Release,
  `CMAKE_OSX_ARCHITECTURES=arm64`, `CMAKE_OSX_DEPLOYMENT_TARGET=14.2`,
  `BUILD_SHARED_LIBS=OFF`, `GGML_NATIVE=OFF`, `GGML_METAL=ON`,
  `GGML_METAL_EMBED_LIBRARY=ON`, `WHISPER_BUILD_TESTS=OFF`,
  `WHISPER_BUILD_SERVER=OFF`; build the whisper-cli target.
- No model is needed to build. `smoke_release.py` needs one to test decoding
  and takes its directory as an optional third argument, defaulting to the
  checkout's `models/`; it symlinks rather than copies and points the app at a
  temporary `SCRIBEBOT_SUPPORT`.

Run `python3 scripts/build_release.py`. The script refuses to overwrite an
existing staging directory or DMG. Outputs are .build/dmg-root/Scribebot.app,
.build/Scribebot-0.1-macOS-arm64.dmg, and .build/SHA256SUMS.

Verify the bundled interpreter and decoder with a minimal Finder-style PATH,
and verify the DMG with hdiutil. GPU decoding requires actual Metal access;
restricted execution environments may crash before model loading. Test on an
independent Mac before claiming compatibility beyond the build machine.

The current release is ad-hoc signed. For a notarized release, sign all nested
code and the app with a Developer ID certificate and hardened runtime, submit
with notarytool, and staple the ticket before publishing. No certificate or
notarization credentials are stored in this repository.
