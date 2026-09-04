# Building a release

The distributable is separate from the lightweight app/build.sh development
build. It includes a portable Python runtime, a statically linked Whisper CLI,
its matching GGML/embedded Metal library, and the Hebrew model. Only explicitly
listed runtime files are copied; personal calendar indexes are excluded.

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
- models/ivrit-large-v3-turbo.bin must exist in the checkout.

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
