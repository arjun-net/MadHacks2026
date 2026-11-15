#!/usr/bin/env python3
"""Campus Pulse viewer server.

Serves the viewer folder AND proxies /api/v1/* to the Campus Location
API (the spec server on a cloudflared tunnel). The proxy exists because
the tunnel sends no CORS headers, so the browser blocks direct fetches
from the viewer page — same-origin proxying sidesteps that.

The upstream base defaults to CAMPUS_API_BASE in viewer/.env (this
dashboard's own config — the pinging service keeps its PULSE_TARGET
in pinging_api/.env); override with --api or the CAMPUS_API_BASE
environment variable.

Run:   python3 viewer/serve.py [--api https://<tunnel>.trycloudflare.com/api/v1] [--port 8000]
Then:  http://localhost:8000/  (the live-feed button proxies via /api/v1/…)
"""

import argparse
import json
import os
import re
import urllib.error
import urllib.request
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

# macOS Homebrew/python.org Pythons often have no default CA bundle, so
# urllib fails TLS to the tunnel with CERTIFICATE_VERIFY_FAILED. Use
# certifi's bundle when available.
try:
    import certifi
    _SSL_CTX = urllib.request.HTTPSHandler(
        context=__import__("ssl").create_default_context(cafile=certifi.where()))
except ImportError:
    _SSL_CTX = None

_OPENER = urllib.request.build_opener(*([_SSL_CTX] if _SSL_CTX else []))

ROOT = os.path.dirname(os.path.abspath(__file__))  # viewer/

# Default: CAMPUS_API_BASE from viewer/.env (the web dashboard's own
# config, separate from the pinging service's pinging_api/.env), else
# the localhost spec server. No "last used" state file: a typo saved
# once would shadow later .env fixes on every future start.
ENV_PATH = os.path.join(ROOT, ".env")


def _load_dotenv_target():
    try:
        with open(ENV_PATH, encoding="utf-8") as f:
            m = re.search(r"^CAMPUS_API_BASE=(\S+)", f.read(), re.M)
            return m.group(1) if m else None
    except OSError:
        return None


API_BASE = None  # set in main()


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    # ── /api/v1 proxy ────────────────────────────────────────────
    def _proxy(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else None
        url = API_BASE + self.path[len("/api/v1"):]
        req = urllib.request.Request(url, data=body, method=self.command)
        for h in ("Content-Type", "Accept"):
            if self.headers.get(h):
                req.add_header(h, self.headers[h])
        try:
            with _OPENER.open(req, timeout=30) as r:
                payload = r.read()
                self.send_response(r.status)
                ctype = r.headers.get("Content-Type", "application/json")
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)
        except urllib.error.HTTPError as e:
            payload = e.read()
            self.send_response(e.code)
            self.send_header("Content-Type", e.headers.get("Content-Type", "application/json"))
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            payload = json.dumps({"detail": f"proxy error: {e}"}).encode()
            self.send_response(502)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

    def do_GET(self):
        if self.path.startswith("/api/v1"):
            return self._proxy()
        super().do_GET()

    def do_POST(self):
        if self.path.startswith("/api/v1"):
            return self._proxy()
        self.send_response(405)
        self.end_headers()

    def log_message(self, fmt, *args):
        # quieter: only log non-static requests
        if self.path.startswith("/api/v1"):
            super().log_message(fmt, *args)


def main():
    global API_BASE
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[1])
    # 8000 is the ingest API's default port — default the viewer to 8080
    # so both can run side by side.
    ap.add_argument("--port", type=int, default=8080)
    ap.add_argument(
        "--api",
        default=os.environ.get("CAMPUS_API_BASE") or _load_dotenv_target()
        or "http://localhost:8000/api/v1",
        help="Campus Location API base (…/api/v1)",
    )
    args = ap.parse_args()

    API_BASE = args.api.rstrip("/")
    print(f"viewer:  http://localhost:{args.port}/")
    print(f"api proxy: /api/v1/* → {API_BASE}")

    # Loopback only: this server also exposes a fixed-host proxy — don't
    # offer that to the whole LAN.
    server = ThreadingHTTPServer(("127.0.0.1", args.port), partial(Handler))
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
