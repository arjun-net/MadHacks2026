#!/usr/bin/env python3
"""Geofence editor companion server.

Serves the editor folder (so POST /save works, which file:// cannot do)
and writes edits back to configs/buildings.json + regenerates editor/data.js.

Run:  python3 editor/serve.py          (from anywhere)
Then: http://localhost:8765/
"""

import json
import os
from http.server import HTTPServer, SimpleHTTPRequestHandler

ROOT = os.path.dirname(os.path.abspath(__file__))      # editor/
PROJECT = os.path.dirname(ROOT)                        # project root
CONFIG_PATH = os.path.join(PROJECT, "configs", "buildings.json")
TRACED_PATH = os.path.join(PROJECT, "configs", "traced_paths.json")
OSM_WAYS_DIR = os.path.join(PROJECT, "configs")
DATA_JS = os.path.join(ROOT, "data.js")
PORT = 8765


def write_config(buildings):
    """Validate + write configs/buildings.json and regenerate data.js."""
    if not isinstance(buildings, list):
        raise ValueError("payload must be a list of buildings")
    for b in buildings:
        for key in ("id", "name", "type", "center", "perimeter_polygon"):
            if key not in b:
                raise ValueError(f"building missing key: {key}")
        poly = b["perimeter_polygon"]
        if (
            not isinstance(poly, list)
            or len(poly) < 3
            or any(not isinstance(p, (list, tuple)) or len(p) != 2 for p in poly)
        ):
            raise ValueError(f"{b['id']}: bad perimeter_polygon")

        # fresh center from polygon centroid (same rule as the editor UI)
        b["center"] = [
            sum(p[0] for p in poly) / len(poly),
            sum(p[1] for p in poly) / len(poly),
        ]

    try:
        existing = json.load(open(CONFIG_PATH))
    except OSError:
        existing = {}
    doc = {
        "campus": existing.get("campus", "UW-Madison"),
        "buildings": buildings,
    }
    payload = json.dumps(doc, indent=2) + "\n"
    json.loads(payload)  # validate the roundtrip before touching disk

    with open(CONFIG_PATH, "w") as f:
        f.write(payload)
    _write_data_js(doc)


def _write_data_js(doc):
    with open(DATA_JS, "w") as f:
        f.write(
            "/* Auto-generated from configs/buildings.json — embedded so the\n"
            "   editor opens directly from file:// without a local server. */\n"
            "window.BUILDINGS_DATA = "
            + json.dumps(doc, indent=1)
            + ";\n"
        )


def write_traced(doc):
    """Validate + write configs/traced_paths.json."""
    paths = doc.get("paths")
    if not isinstance(paths, list):
        raise ValueError("'paths' must be a list")
    clean = []
    for p in paths:
        vts = p.get("vertices")
        if not isinstance(vts, list) or len(vts) < 2:
            continue  # drop degenerate paths silently
        for v in vts:
            if (not isinstance(v, list) or len(v) != 2
                    or not all(isinstance(x, (int, float)) for x in v)):
                raise ValueError(f"bad vertex {v!r}")
        clean.append({"name": str(p.get("name") or ""), "vertices": vts})
    with open(TRACED_PATH, "w", encoding="utf-8") as f:
        json.dump({"campus": "UW-Madison", "paths": clean}, f, indent=1)
    return len(clean)


def _osm_geojson():
    """Serve the cached OSM ways as GeoJSON lines for reference display.
    Merges every /tmp/uw_*.json snapshot we have (best effort)."""
    import glob
    import tempfile
    feats = []
    for cand in ("/tmp/uw_ways.json", "/tmp/uw_roads.json", "/tmp/uw_ways_full.json"):
        try:
            with open(cand, "r", encoding="utf-8") as f:
                for e in json.load(f).get("elements", []):
                    g = e.get("geometry")
                    if not g:
                        continue
                    feats.append({
                        "type": "Feature", "properties": {"src": os.path.basename(cand)},
                        "geometry": {"type": "LineString",
                                     "coordinates": [[pt["lon"], pt["lat"]] for pt in g]},
                    })
        except (OSError, ValueError):
            continue
    return {"type": "FeatureCollection", "features": feats}


def _buildings_geojson():
    with open(CONFIG_PATH, "r", encoding="utf-8") as f:
        doc = json.load(f)
    feats = []
    for b in doc.get("buildings", []):
        poly = b.get("perimeter_polygon") or []
        if len(poly) < 3:
            continue
        feats.append({
            "type": "Feature", "properties": {"id": b["id"], "type": b.get("type")},
            "geometry": {"type": "Polygon",
                         "coordinates": [[[v[1], v[0]] for v in poly]]},
        })
    return {"type": "FeatureCollection", "features": feats}


class Handler(SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=ROOT, **kwargs)

    def end_headers(self):
        # allow saving from a file:// page (Origin: null) as well as this origin
        self.send_header("Access-Control-Allow-Origin", "*")
        self.send_header("Access-Control-Allow-Headers", "Content-Type")
        self.send_header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path.rstrip("/") == "/osm_paths.geojson":
            body = json.dumps(_osm_geojson()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        if self.path.rstrip("/") == "/buildings.geojson":
            body = json.dumps(_buildings_geojson()).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)
            return
        super().do_GET()

    def do_POST(self):
        path = self.path.rstrip("/")
        if path == "/save_traced":
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            try:
                payload = json.loads(body)
                n = write_traced(payload)
            except Exception as exc:  # noqa: BLE001
                print(f"[save_traced] FAILED: {exc}")
                self.send_response(400)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(json.dumps({"ok": False, "error": str(exc)}).encode())
                return
            print(f"[save_traced] wrote {n} paths -> {TRACED_PATH}")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": True, "saved": n}).encode())
            return
        if path != "/save":
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length)
        try:
            payload = json.loads(body)
            write_config(payload["buildings"])
        except Exception as exc:  # noqa: BLE001 — report any failure to the UI
            msg = str(exc)
            print(f"[save] FAILED: {msg}")
            self.send_response(400)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": False, "error": msg}).encode())
            return
        n = len(payload["buildings"])
        print(f"[save] wrote {n} buildings -> {CONFIG_PATH}")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps({"ok": True, "saved": n}).encode())

    def log_message(self, fmt, *args):  # silence per-request noise
        pass


def main():
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Geofence editor server: http://localhost:{PORT}/")
    print(f"  writes: {CONFIG_PATH}")
    print(f"  regenerates: {DATA_JS}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
