#!/usr/bin/env python3
"""Which engine writes the summary.

    ollama   a model running on this Mac. Nothing leaves the machine.
    claude   the Claude Code CLI already installed and signed in.
    codex    the Codex CLI already installed and signed in.

Claude and Codex are driven as the *installed tools*, not as HTTP APIs: no key
is asked for, stored or read here, and the tool's own session does the
authenticating. That is the point - the user signed in once, in the terminal,
and should not have to paste a key into a meeting recorder.

It does change where the meeting goes. Ollama keeps the transcript on this Mac;
Claude and Codex send it to their vendor. `sends_data` marks which is which,
and the app puts that in front of the person making the choice.

    ./providers.py --selftest
    ./providers.py --list          what is installed on this machine
"""
import json, subprocess, sys, tempfile, urllib.error, urllib.request
from pathlib import Path

import toolpaths

OLLAMA_URL = "http://localhost:11434/api/generate"
OLLAMA_TAGS = "http://localhost:11434/api/tags"
DEFAULT_PROVIDER = "ollama"
# Ollama is the only provider that needs a model named for it. Claude and Codex
# each have their own configured default, and passing an Ollama model name to
# them is an error - "gemma4:latest" went to `claude --model` once and it
# rejected the whole run.
DEFAULT_OLLAMA_MODEL = "gemma4:latest"
TIMEOUT = 600

# id -> (label, does it send the transcript off this Mac?)
PROVIDERS = {
    "ollama": ("Ollama", False),
    "claude": ("Claude Code", True),
    "codex": ("Codex", True),
}


def default_model(provider: str) -> str:
    """The model to use when the user has not named one."""
    return DEFAULT_OLLAMA_MODEL if provider == "ollama" else ""


def binary(provider: str) -> str | None:
    """The CLI backing a provider, or None when it is not installed."""
    if provider == "claude":
        return toolpaths.find("claude", "SCRIBEBOT_CLAUDE")
    if provider == "codex":
        return toolpaths.find("codex", "SCRIBEBOT_CODEX")
    return None


def ollama_models() -> list[str]:
    """Models Ollama has pulled, newest first. Empty when it is not running."""
    try:
        with urllib.request.urlopen(OLLAMA_TAGS, timeout=3) as r:
            data = json.loads(r.read())
    except (urllib.error.URLError, TimeoutError, json.JSONDecodeError, OSError):
        return []
    models = data.get("models", [])
    models.sort(key=lambda m: m.get("modified_at", ""), reverse=True)
    return [m["name"] for m in models if m.get("name")]


def status() -> dict:
    """What this machine can actually run, for the settings picker."""
    out = []
    for pid, (label, sends) in PROVIDERS.items():
        entry = {"id": pid, "label": label, "sendsDataOffDevice": sends}
        if pid == "ollama":
            entry["models"] = ollama_models()
            entry["available"] = bool(entry["models"])
            entry["path"] = ""
            entry["detail"] = ("" if entry["models"]
                               else "Ollama is not answering on localhost:11434.")
        else:
            path = binary(pid)
            entry["available"] = path is not None
            entry["path"] = path or ""
            entry["models"] = []
            entry["detail"] = "" if path else f"The {pid} command was not found."
        out.append(entry)
    return {"providers": out, "default": DEFAULT_PROVIDER,
            "defaultOllamaModel": DEFAULT_OLLAMA_MODEL}


# --- running one prompt ------------------------------------------------------

def _ollama(prompt: str, model: str) -> str:
    payload = json.dumps({"model": model, "prompt": prompt, "stream": False}).encode()
    req = urllib.request.Request(OLLAMA_URL, data=payload,
                                 headers={"Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
            data = json.loads(r.read())
    except urllib.error.URLError as e:
        raise RuntimeError(f"cannot reach Ollama at {OLLAMA_URL} ({e.reason}).\n"
                           f"is it running? try: ollama serve") from None
    if "error" in data:
        raise RuntimeError(f"ollama error: {data['error']}\n"
                           f"is the model pulled? try: ollama pull {model}")
    return data["response"].strip()


def _run_cli(argv: list[str], prompt: str, label: str) -> subprocess.CompletedProcess:
    try:
        return subprocess.run(argv, input=prompt, capture_output=True,
                              text=True, timeout=TIMEOUT)
    except FileNotFoundError:
        raise RuntimeError(f"{label} is not installed, or moved.") from None
    except subprocess.TimeoutExpired:
        raise RuntimeError(f"{label} did not answer within "
                           f"{TIMEOUT // 60} minutes.") from None


def _claude(prompt: str, model: str) -> str:
    exe = binary("claude")
    if not exe:
        raise RuntimeError("the claude command was not found.\n"
                           "install Claude Code, or set SCRIBEBOT_CLAUDE to its path.")
    argv = [exe, "-p"]
    if model:
        argv += ["--model", model]
    r = _run_cli(argv, prompt, "claude")
    # Never let a failed run look like an empty summary: that is the shape of
    # every silent-failure bug this project has had.
    if r.returncode != 0:
        raise RuntimeError(f"claude exited with {r.returncode}.\n"
                           f"{(r.stderr or r.stdout).strip()[:400]}")
    return r.stdout.strip()


def _codex(prompt: str, model: str) -> str:
    exe = binary("codex")
    if not exe:
        raise RuntimeError("the codex command was not found.\n"
                           "install the Codex CLI, or set SCRIBEBOT_CODEX to its path.")
    # `codex exec` prints a session header, warnings and hook chatter ahead of
    # the answer. -o writes just the final message, which is the only part that
    # is a summary. --skip-git-repo-check because a recordings folder is not a
    # repository and codex refuses to run outside one without it.
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "last.txt"
        argv = [exe, "exec", "--skip-git-repo-check", "-o", str(out)]
        if model:
            argv += ["-m", model]
        argv.append("-")
        r = _run_cli(argv, prompt, "codex")
        text = out.read_text(encoding="utf-8").strip() if out.exists() else ""
    if r.returncode != 0 or not text:
        detail = (r.stderr or r.stdout or "").strip()
        # Codex reports model and auth problems as ERROR lines on stdout, and
        # they are the only part worth showing.
        errors = [l for l in detail.splitlines() if l.startswith("ERROR")]
        raise RuntimeError(f"codex produced no summary (exit {r.returncode}).\n"
                           + ("\n".join(errors[:2]) if errors else detail[:400]))
    return text


def run(prompt: str, provider: str = DEFAULT_PROVIDER, model: str = "") -> str:
    """One prompt, one answer. Raises RuntimeError with something actionable."""
    if provider not in PROVIDERS:
        raise RuntimeError(f"unknown provider: {provider}\n"
                           f"available: {', '.join(PROVIDERS)}")
    if provider == "ollama":
        if not model:
            raise RuntimeError("ollama needs a model name")
        return _ollama(prompt, model)
    return (_claude if provider == "claude" else _codex)(prompt, model)


def selftest() -> None:
    """Offline: no provider is contacted."""
    assert set(PROVIDERS) == {"ollama", "claude", "codex"}
    # Only Ollama keeps the transcript on this Mac. The app relies on this flag
    # to warn people, so it is asserted rather than assumed.
    assert PROVIDERS["ollama"][1] is False
    assert PROVIDERS["claude"][1] is True and PROVIDERS["codex"][1] is True

    for bad in ("", "gpt4", "Ollama"):
        try:
            run("x", bad)
        except RuntimeError as e:
            assert "unknown provider" in str(e), e
        else:
            raise AssertionError(f"{bad!r} should not be accepted as a provider")

    try:
        run("x", "ollama", "")
    except RuntimeError as e:
        assert "needs a model" in str(e), e
    else:
        raise AssertionError("ollama with no model should fail")

    assert default_model("ollama") == DEFAULT_OLLAMA_MODEL
    # Naming an Ollama model to Claude or Codex is what broke the first run.
    assert default_model("claude") == "" and default_model("codex") == ""

    s = status()
    assert s["default"] == DEFAULT_PROVIDER
    ids = [p["id"] for p in s["providers"]]
    assert ids == list(PROVIDERS), ids
    for p in s["providers"]:
        assert {"id", "label", "available", "models", "detail", "path"} <= set(p)
        # An unavailable provider must explain itself, or the picker greys out
        # a row with no reason beside it.
        assert p["available"] or p["detail"], p

    print("providers self-check passed")


if __name__ == "__main__":
    if "--selftest" in sys.argv:
        selftest()
    elif "--list" in sys.argv:
        print(json.dumps(status(), indent=2))
    else:
        print(__doc__)
