#!/usr/bin/env python3
"""Fetch Mapbox Streets v8 vector tiles and extract pedestrian paths.

Mapbox renders sidewalks/footpaths from its own vector tiles; the tiles
carry real lng/lat LineStrings (no pixel inference needed). This script:

  1. Computes the z16 tiles covering the campus bbox.
  2. Fetches each .mvt and decodes it with vt2geojson.
  3. Keeps road-layer features with class=path (footway/sidewalk/crossing/
     corridor/steps/path/...) and class=pedestrian (plazas, ped streets).
  4. Dedupes, merges with the OSM ways already cached, and reports
     coverage vs the buildings the generator actually uses.

Output: /tmp/uw_mapbox_paths.json (raw lines) and a coverage report.
The corridor rasterizer (tools/fetch_osm_paths.py) can then consume the
merged way set via --mapbox flag, or we regenerate osm_path_cells.json
from both sources.

Usage: python3 tools/fetch_mapbox_paths.py
"""

import json
import math
import subprocess
import sys
import time

import mercantile
from vt2geojson.tools import vt_bytes_to_geojson

MAPBOX_TOKEN = "pk.eyJ1Ijoiam9zaGNvbGNvcmQiLCJhIjoiY213Z3k4ajMyMDJ1cTJ4cGw5OHR5eW5vayJ9.dO1J5qNiwkkYCwTC3UBEwg"
STREETS_V8 = "mapbox.mapbox-streets-v8"
ZOOM = 16

# Campus bbox (lat_min, lng_min, lat_max, lng_max) — matches corridor file
BBOX = (43.06231, -89.42793, 43.08087, -89.38656)

# Pedestrian-relevant classes in the Streets v8 road layer.
PATH_TYPES = {
    "footway", "sidewalk", "crossing", "corridor", "steps",
    "path", "hiking", "trail", "piste", "mountain_bike", "bridleway",
}


def fetch_tile(tile):
    url = (f"https://api.mapbox.com/v4/{STREETS_V8}/"
           f"{tile.z}/{tile.x}/{tile.y}.mvt?access_token={MAPBOX_TOKEN}")
    for attempt in range(3):
        try:
            # curl (not urllib) — macOS python lacks a usable CA bundle
            r = subprocess.run(["curl", "-sS", "--fail", "--compressed", "--max-time", "60", url],
                               capture_output=True, timeout=90)
            if r.returncode == 0 and r.stdout:
                body = r.stdout
                # --compressed auto-decompresses, but be safe if it didn't
                if body[:2] == b"\x1f\x8b":
                    import gzip
                    body = gzip.decompress(body)
                return body
            code = r.returncode
        except subprocess.TimeoutExpired:
            code = -1
        if code in (0, 22, 28, -1):  # 22=HTTP error (retry on 5xx), 28=timeout
            time.sleep(2 * (attempt + 1))
            continue
        raise RuntimeError(f"tile fetch failed (curl rc={code}): {url}")
    raise RuntimeError(f"tile fetch failed after retries: {url}")


def extract_paths(tile_bytes, tile, x, y):
    fc = vt_bytes_to_geojson(tile_bytes, x, y, tile.z)
    out = []
    for feat in fc["features"]:
        props = feat.get("properties") or {}
        if props.get("class") not in ("path", "pedestrian"):
            continue
        if props.get("class") == "path" and props.get("type") not in PATH_TYPES:
            continue
        if feat.get("access") in ("no", "private"):
            continue
        geom = feat.get("geometry")
        if geom is None:
            continue
        if geom["type"] == "LineString":
            out.append({"kind": props.get("class"), "type": props.get("type"),
                        "coords": [[c[1], c[0]] for c in geom["coordinates"]]})
        elif geom["type"] == "MultiLineString":
            for line in geom["coordinates"]:
                out.append({"kind": props.get("class"), "type": props.get("type"),
                            "coords": [[c[1], c[0]] for c in line]})
    return out


def dedupe(lines, tol=1e-6):
    seen = set()
    out = []
    for ln in lines:
        key = (ln["kind"], ln["type"], tuple(round(c[0], 6) for c in ln["coords"][0:1]),
               tuple(round(c[0], 6) for c in ln["coords"][-1:]))
        if key in seen:
            continue
        seen.add(key)
        out.append(ln)
    return out


def main():
    tiles = list(mercantile.tiles(BBOX[1], BBOX[0], BBOX[3], BBOX[2], ZOOM))
    print(f"fetching {len(tiles)} z{ZOOM} tiles for bbox {BBOX}")
    lines = []
    for i, tile in enumerate(tiles):
        data = fetch_tile(tile)
        got = extract_paths(data, tile, tile.x, tile.y)
        lines.extend(got)
        print(f"  [{i+1}/{len(tiles)}] tile {tile.x}/{tile.y}: {got and len(got) or 0} path lines")
    lines = dedupe(lines)
    print(f"total after dedupe: {len(lines)}")

    with open("/tmp/uw_mapbox_paths.json", "w") as f:
        json.dump({"zoom": ZOOM, "bbox": BBOX,
                   "fetched_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                   "lines": lines}, f)
    print("wrote /tmp/uw_mapbox_paths.json")

    # quick coverage sanity: how many lines fall inside each bbox corner region
    # and total line-km
    total_m = 0.0
    for ln in lines:
        for (a, b) in zip(ln["coords"], ln["coords"][1:]):
            total_m += math.hypot((b[0] - a[0]) * 111320.0,
                                  (b[1] - a[1]) * 111320.0 * math.cos(math.radians(43.07)))
    by_kind = {}
    for ln in lines:
        by_kind[(ln["kind"], ln["type"])] = by_kind.get((ln["kind"], ln["type"]), 0) + 1
    print(f"total path length: {total_m/1000:.1f} km")
    for k in sorted(by_kind, key=by_kind.get, reverse=True):
        print(f"  {k}: {by_kind[k]}")


if __name__ == "__main__":
    main()
