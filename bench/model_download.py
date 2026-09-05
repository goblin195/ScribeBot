#!/usr/bin/env python3
"""Run app/model-selftest against a local HTTP server.

The DMG no longer carries a model; the app downloads one at first run. That
download is the one place in this project that can leave a file which *looks*
like a 1.5 GB model and is not - a truncated body, or an HTML error page served
with a 200 - and whisper-cli's complaint about either is unreadable. So the
refusals are tested, on a few megabytes, over real HTTP.

Served here: byte ranges (so resume is exercised), a route that ignores Range
(so the restart path is exercised), an HTML error page, and a 404.

    python3 bench/model_download.py
"""
import hashlib
import http.server
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

GOOD = bytes(range(256)) * 16_384          # 4 MiB, and not compressible to nothing
SLOW = os.urandom(8 << 20)                 # 8 MiB, big enough to cancel partway
ERROR_PAGE = b"<!doctype html><title>502</title><h1>Bad gateway</h1>"

FILES = {"/good.bin": GOOD, "/norange/good.bin": GOOD, "/slow.bin": SLOW}
# Seconds per 32 KiB chunk. /slow.bin is paced hard enough that the cancel test
# reliably fires partway through instead of racing a finished transfer.
PACE = {"/good.bin": 0.002, "/norange/good.bin": 0.002, "/slow.bin": 0.006}

FACTS = json.dumps({
    "good.size": str(len(GOOD)), "good.sha256": hashlib.sha256(GOOD).hexdigest(),
    "slow.size": str(len(SLOW)), "slow.sha256": hashlib.sha256(SLOW).hexdigest(),
}).encode()


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):        # the check prints one line, not a request log
        pass

    def _send(self, code, body, ctype, extra=(), pace=0.0):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in extra:
            self.send_header(k, v)
        self.end_headers()
        # Written in paced pieces. Over loopback an unpaced 8 MiB arrives in one
        # or two callbacks, which made the progress assertions vacuous and made
        # the cancel test race the whole transfer to completion.
        try:
            for i in range(0, len(body), 32 << 10):
                self.wfile.write(body[i:i + (32 << 10)])
                self.wfile.flush()
                if pace:
                    time.sleep(pace)
        except (BrokenPipeError, ConnectionResetError):
            pass          # the cancel test hangs up mid-body; that is the test

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if self.path == "/facts.json":
            return self._send(200, FACTS, "application/json")
        if self.path == "/error.html":
            return self._send(200, ERROR_PAGE, "text/html; charset=utf-8")
        body = FILES.get(self.path)
        if body is None:
            return self._send(404, b"not found", "text/plain")

        rng = self.headers.get("Range")
        # The /norange route answers 200 to a Range request, the way a CDN that
        # does not do ranges would. The client must start over, not append.
        if rng and not self.path.startswith("/norange/"):
            m = re.match(r"bytes=(\d+)-(\d*)$", rng.strip())
            if not m:
                return self._send(416, b"bad range", "text/plain")
            start = int(m.group(1))
            end = int(m.group(2)) if m.group(2) else len(body) - 1
            if start >= len(body):
                return self._send(416, b"range out of bounds", "text/plain")
            return self._send(206, body[start:end + 1], "application/octet-stream",
                              [("Content-Range", f"bytes {start}-{end}/{len(body)}")],
                              pace=PACE[self.path])
        return self._send(200, body, "application/octet-stream",
                          [("Accept-Ranges", "bytes")], pace=PACE[self.path])


class Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def handle_error(self, request, client_address):
        # The cancel test hangs up mid-body on purpose. socketserver prints the
        # resulting traceback to stderr, ./check merges stderr into stdout, and
        # it greps the last line for "traceback" - so a passing check would have
        # reported as failed on timing alone.
        if not isinstance(sys.exception(), (BrokenPipeError, ConnectionResetError)):
            super().handle_error(request, client_address)


def main() -> int:
    swiftc = shutil.which("swiftc")
    if not swiftc:
        # Not a bare command name: the app never runs this, ./check does, and a
        # machine without the toolchain cannot build the app either.
        print("swiftc not found; skipped (this check needs the Swift toolchain)")
        return 0

    server = Server(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]

    with tempfile.TemporaryDirectory(prefix="scribebot-model-check-") as temp:
        binary = Path(temp) / "mcheck"
        build = subprocess.run(
            [swiftc, "-module-cache-path", str(Path(temp) / "modules"),
             "-o", str(binary),
             str(ROOT / "app/Sources/ModelSetup.swift"),
             str(ROOT / "app/model-selftest/main.swift")],
            capture_output=True, text=True)
        if build.returncode != 0:
            print(build.stderr.strip()[-3000:] or "swiftc failed")
            return 1
        run = subprocess.run([str(binary), f"http://127.0.0.1:{port}", temp],
                             capture_output=True, text=True, timeout=300)
        server.shutdown()
        sys.stdout.write(run.stdout)
        if run.returncode != 0:
            sys.stdout.write(run.stderr[-2000:])
            return run.returncode or 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
