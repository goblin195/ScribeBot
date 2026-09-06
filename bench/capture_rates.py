#!/usr/bin/env python3
"""Compile the actual capture helper and test conversion without audio hardware."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parent.parent


def main():
    with tempfile.TemporaryDirectory(prefix="scribebot-rate-check-") as temp:
        binary = Path(temp) / "capture-check"
        subprocess.run([
            "/usr/bin/xcrun", "swiftc", "-module-cache-path", str(Path(temp) / "modules"),
            "-o", str(binary), str(ROOT / "capture/tap.swift"),
        ], check=True, timeout=120)
        subprocess.run([str(binary), "selftest-rate"], check=True, timeout=20)


if __name__ == "__main__":
    main()
