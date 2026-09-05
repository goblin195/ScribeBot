#!/usr/bin/env python3
"""Which decoder to run, and in which language.

Scribebot started Hebrew-only, with `-l he` written into three call sites and
one model path next to it. It is not Hebrew-only: whisper decodes around a
hundred languages, and the decision that actually matters is which of the two
local models to point at.

    models/ivrit-large-v3-turbo.bin     Hebrew fine-tune. The better decoder
                                        for Hebrew, including Hebrew carrying
                                        English technical terms.
    models/vanilla-large-v3-turbo.bin   Stock large-v3-turbo. The better
                                        decoder for everything else.

Language comes from `--lang`, or SCRIBEBOT_LANG, and defaults to `auto`. On
`auto` the general model runs first, because a meeting in Portuguese should
not be decoded by a Hebrew fine-tune on the assumption that every meeting is
Hebrew. Whisper reports the language it detected, so when the answer comes
back Hebrew the batch path re-runs on the fine-tune - `upgrade()` decides
that. The second pass costs about a second per file and happens only for the
one language that has a specialised model.

Either model alone is enough to run: if one is missing the other is used
rather than failing, because an absent 1.5 GB download should not look like a
broken install.

Neither model ships in the DMG any more - 1.4 GB of a 1.5 GB installer was one
file - so a released app downloads them on first run. They cannot land inside
the bundle: adding a file to Contents/Resources breaks the code signature the
installer just verified, and the next launch is refused. They land next to the
recordings instead, and are looked for in both places.

    ./languages.py --selftest
"""
import os, re, sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def support_dir() -> Path:
    """The library root. SCRIBEBOT_SUPPORT moves it, exactly as the app does."""
    env = os.environ.get("SCRIBEBOT_SUPPORT", "").strip()
    if env:
        return Path(env).expanduser()
    return Path.home() / "Library/Application Support/Scribebot"


def model_path(name: str) -> Path:
    """Where a decoder lives: the checkout if it has one, else the download.

    A source checkout keeps its models in models/ and must keep winning, so
    developers are not made to re-download what they already built with. A
    released app has an empty models/ and finds the first-run download.
    """
    local = ROOT / "models" / name
    return local if local.exists() else support_dir() / "models" / name


HEBREW = model_path("ivrit-large-v3-turbo.bin")
MULTILINGUAL = model_path("vanilla-large-v3-turbo.bin")

# whisper accepts "he"; the rest is what people actually type.
HEBREW_CODES = {"he", "iw", "heb", "hebrew", "עברית"}

DEFAULT_LANG = "auto"


def requested(lang: str | None = None) -> str:
    """The language asked for, normalised. An explicit argument beats the env."""
    raw = lang if lang is not None else os.environ.get("SCRIBEBOT_LANG", "")
    return (raw or DEFAULT_LANG).strip().lower() or DEFAULT_LANG


def resolve(lang: str | None = None) -> tuple[Path, str]:
    """(model to run, value for whisper's `-l`) for a requested language."""
    want = requested(lang)
    if want in HEBREW_CODES:
        return (HEBREW if HEBREW.exists() else MULTILINGUAL), "he"
    # `auto` and every named non-Hebrew language go to the general model.
    general = HEBREW if not MULTILINGUAL.exists() else MULTILINGUAL
    return general, ("auto" if want == DEFAULT_LANG else want)


_DETECTED = re.compile(r"auto-detected language:\s*([A-Za-z-]+)")


def detected_language(whisper_stderr: str) -> str:
    """The language whisper reported, or "" if it did not say.

    whisper-cli prints `auto-detected language: he (p = 0.999997)` ahead of the
    transcript, on stderr, and only when `-l auto` was asked for.
    """
    m = _DETECTED.search(whisper_stderr or "")
    return m.group(1).lower() if m else ""


def upgrade(detected: str, lang: str | None = None) -> Path | None:
    """A better model to re-run with, or None to keep the first result.

    Only Hebrew has a specialised model here, so only Hebrew earns a second
    pass - and only when the caller said `auto` and the fine-tune is not what
    already ran.
    """
    if requested(lang) != DEFAULT_LANG:
        return None
    if (detected or "").strip().lower() not in HEBREW_CODES:
        return None
    first, _ = resolve(DEFAULT_LANG)
    return HEBREW if HEBREW.exists() and first != HEBREW else None


def require(lang: str | None = None) -> tuple[Path, str]:
    """resolve(), but refuses to continue when the model is not on disk.

    resolve() must stay total - the selftest runs on a fresh clone with neither
    model - so the existence check lives here, and every path that actually
    decodes goes through it. Before this, `stream.py` ran whisper against a
    missing model, ignored the exit status and read "no JSON" as "nobody
    spoke": on a fresh install, where no model exists until the first-run
    download finishes, the live view stayed blank for a whole meeting with
    nothing said anywhere. That is the silent-failure shape CLAUDE.md is about.
    """
    model, flag = resolve(lang)
    if not model.exists():
        raise SystemExit(
            f"transcription model missing: {model}\n"
            "Open Scribebot and finish setup to download it, or place a "
            "whisper.cpp .bin at that path.")
    return model, flag


def add_argument(parser) -> None:
    """Give a CLI the same `--lang` flag, described the same way."""
    parser.add_argument(
        "--lang", default=None, metavar="CODE",
        help="meeting language: a whisper code such as en, es, fr, ar, ru, "
             "or 'auto' to detect (default: auto, or $SCRIBEBOT_LANG)")


def selftest() -> None:
    """Runs without either model present, so it works on a fresh clone."""
    assert requested(None) == "auto"
    assert requested("EN") == "en"
    assert requested("  He ") == "he"
    assert requested("") == "auto"

    # Hebrew always asks whisper for Hebrew, whichever model is on disk.
    assert resolve("he")[1] == "he"
    assert resolve("HEBREW")[1] == "he"
    # A named language is passed through untouched.
    assert resolve("es")[1] == "es"
    assert resolve("pt-br")[1] == "pt-br"
    # No language named means detection, not an assumption of Hebrew.
    assert resolve(None)[1] == "auto"
    assert resolve("auto")[1] == "auto"

    # An explicit language is never second-guessed, even when it is Hebrew.
    assert upgrade("he", lang="en") is None
    assert upgrade("he", lang="he") is None
    # Nor is a detected language with no specialised model.
    assert upgrade("fr") is None
    assert upgrade("") is None

    assert detected_language("auto-detected language: he (p = 0.999997)") == "he"
    assert detected_language("auto-detected language: en (p = 0.98)") == "en"
    assert detected_language("no such line here") == ""

    # The env var is the fallback, and an explicit argument beats it.
    old = os.environ.get("SCRIBEBOT_LANG")
    os.environ["SCRIBEBOT_LANG"] = "de"
    try:
        assert requested(None) == "de"
        assert resolve(None)[1] == "de"
        assert requested("fr") == "fr"
    finally:
        if old is None: os.environ.pop("SCRIBEBOT_LANG", None)
        else: os.environ["SCRIBEBOT_LANG"] = old

    # Whichever models exist, resolve names a .bin rather than returning None -
    # including on a clone that has downloaded neither.
    for lang in ("he", "en", "auto"):
        model, _ = resolve(lang)
        assert isinstance(model, Path) and model.name.endswith(".bin")

    # A released app has no models/ in its bundle; the first-run download goes
    # under the support directory, and SCRIBEBOT_SUPPORT has to move it or the
    # screenshot and smoke runs would write into the real library.
    old_support = os.environ.get("SCRIBEBOT_SUPPORT")
    os.environ["SCRIBEBOT_SUPPORT"] = "/tmp/scribebot-selftest-support"
    try:
        assert support_dir() == Path("/tmp/scribebot-selftest-support")
        absent = model_path("no-such-model.bin")
        assert absent == Path("/tmp/scribebot-selftest-support/models/no-such-model.bin")
        # A checkout that has the file keeps using it rather than re-downloading.
        present = ROOT / "models" / "ivrit-large-v3-turbo.bin"
        if present.exists():
            assert model_path("ivrit-large-v3-turbo.bin") == present
    finally:
        if old_support is None: os.environ.pop("SCRIBEBOT_SUPPORT", None)
        else: os.environ["SCRIBEBOT_SUPPORT"] = old_support

    print("languages self-check passed")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    else:
        model, flag = resolve(sys.argv[1] if len(sys.argv) > 1 else None)
        print(f"language={flag}  model={model.name}  present={model.exists()}")
