#!/usr/bin/env python3
"""Fetch the real pedestrian path network around UW-Madison from OpenStreetMap
and precompute the per-cell distance-to-path grid consumed by router.py.

Output: configs/osm_path_cells.json
    {
      "nrows": <int>, "ncols": <int>, "cell": <meters>,
      "bbox": [lat_min, lat_max, lng_min, lng_max],
      "source_ways": <int>,
      "fetched_utc": "<iso8601>",
      "dist_to_path": [<meters or null>, ...]   # nrows*ncols, row-major
    }

`null` marks cells unreachable from the path network entirely surrounded by
buildings; router.py treats them as fully off-path.

Run after changing the router's grid (CELL size, building set) or to refresh
the OSM snapshot:

    python3 tools/fetch_osm_paths.py [--cell 6.0] [--pad 200]

The Overpass mirror can be overridden with --url; the default list tries
several public mirrors since overpass-api.de rate-limits aggressively.
"""

import argparse
import datetime
import json
import math
import os
import subprocess
import sys
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, ROOT)

import router  # noqa: E402

BUILDINGS_PATH = os.path.join(ROOT, "configs", "buildings.json")
OUT_PATH = os.path.join(ROOT, "configs", "osm_path_cells.json")

# Pedestrian-relevant highway values. Roads are included because sidewalks
# alongside them carry the campus's heaviest foot traffic (State Street,
# Observatory Drive, Linden Drive...).
QUERY_TEMPLATE = (
    '[out:json][timeout:{timeout}];'
    'way["highway"~"^(footway|path|pedestrian|steps|living_street|residential'
    '|service|unclassified|tertiary|secondary|primary|cycleway)$"]'
    '({lat_min},{lng_min},{lat_max},{lng_max});out geom;'
)

MIRRORS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://overpass.osm.ch/api/interpreter",
]


def fetch_ways(bbox, timeout=240):
    query = QUERY_TEMPLATE.format(
        timeout=timeout, lat_min=bbox[0], lng_min=bbox[1],
        lat_max=bbox[2], lng_max=bbox[3],
    )
    url = None
    last_err = None
    for base in MIRRORS:
        try:
            full = base + "?data=" + urllib.parse.quote(query)
            r = subprocess.run(
                ["curl", "-s", "-m", str(timeout + 20), "-o", "/tmp/osm_ways.json", full],
                timeout=timeout + 30,
            )
            if r.returncode != 0:
                raise RuntimeError(f"curl exit {r.returncode}")
            with open("/tmp/osm_ways.json", "r", encoding="utf-8") as f:
                data = json.load(f)
            if "elements" not in data:
                raise RuntimeError("response missing 'elements' (rate limited?)")
            print(f"fetched {len(data['elements'])} ways from {base}")
            return data["elements"]
        except Exception as e:  # noqa: BLE001
            print(f"  mirror failed: {base} ({e})")
            last_err = e
    # Fall back to the last successful cached fetch, if any.
    try:
        with open("/tmp/osm_ways.json", "r", encoding="utf-8") as f:
            data = json.load(f)
        if data.get("elements"):
            print(f"network failed; using cached /tmp/osm_ways.json "
                  f"({len(data['elements'])} ways)")
            return data["elements"]
        print("cached /tmp/osm_ways.json is empty; skipping fallback")
    except (OSError, ValueError):
        pass
    raise SystemExit(f"all Overpass mirrors failed; last error: {last_err}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--pad", type=float, default=200.0,
                    help="meters beyond the campus bbox to include (default 200)")
    ap.add_argument("--url", type=str, default=None, help="Overpass endpoint override")
    ap.add_argument("--offline", action="store_true",
                    help="skip the network; use cached /tmp/uw_ways.json + /tmp/uw_roads.json")
    ap.add_argument("--mapbox", action="store_true",
                    help="merge pedestrian paths extracted from Mapbox vector tiles "
                         "(/tmp/uw_mapbox_paths.json) into the corridor seeds")
    args = ap.parse_args()
    if args.url:
        MIRRORS.insert(0, args.url)

    with open(BUILDINGS_PATH, "r", encoding="utf-8") as f:
        buildings = json.load(f)["buildings"]

    # Router grid over exactly the buildings router.py will see.
    R = router.Router(buildings)

    # Query bbox = campus bbox + pad, in degrees.
    lat_pad = args.pad / router.METERS_PER_DEG_LAT
    lng_pad = args.pad / router.METERS_PER_DEG_LNG
    bbox = (R.lat_min - lat_pad, R.lng_min - lng_pad,
            R.lat_max + lat_pad, R.lng_max + lng_pad)
    if args.offline:
        ways = []
        for cand in ("/tmp/uw_ways.json", "/tmp/uw_roads.json"):
            try:
                with open(cand, "r", encoding="utf-8") as f:
                    d = json.load(f)
                ways.extend(d.get("elements", []))
                print(f"offline: loaded {len(d.get('elements', []))} ways from {cand}")
            except (OSError, ValueError):
                print(f"offline: {cand} missing/skipped")
        if not ways:
            raise SystemExit("--offline: no cached way files found")
    else:
        ways = fetch_ways(bbox)

    MPLAT, MPLNG = router.METERS_PER_DEG_LAT, router.METERS_PER_DEG_LNG

    def to_cell(lat, lon):
        r, c = R._row(lat), R._col(lon)
        return (r, c) if (0 <= r < R.nrows and 0 <= c < R.ncols) else None

    # Rasterize the network to 3 m sample points -> corridor seed cells.
    line_srcs = [( [p["lat"] for p in (e.get("geometry") or [])],
                  [p["lon"] for p in (e.get("geometry") or [])]) for e in ways]
    if args.mapbox:
        try:
            mb = json.load(open("/tmp/uw_mapbox_paths.json"))["lines"]
            for ln in mb:
                cs = ln["coords"]  # [[lat, lng], ...]
                line_srcs.append(([p[0] for p in cs], [p[1] for p in cs]))
            print(f"merged {len(mb)} Mapbox path lines")
        except OSError:
            print("WARNING: --mapbox given but /tmp/uw_mapbox_paths.json missing")
    seeds = set()
    for lat_list, lon_list in line_srcs:
        for lat0, lon0, lat1, lon1 in zip(lat_list, lon_list, lat_list[1:], lon_list[1:]):
            n = max(1, int(math.hypot((lat1 - lat0) * MPLAT,
                                      (lon1 - lon0) * MPLNG) / 3))
            for k in range(n + 1):
                t = k / n
                cc = to_cell(lat0 + t * (lat1 - lat0), lon0 + t * (lon1 - lon0))
                if cc:
                    seeds.add(cc)
    print(f"corridor seed cells: {len(seeds)} of {R.nrows * R.ncols}")

    # ── Connect isolated buildings (off-campus housing in unmapped blocks) ──
    # Some doors are far from any mapped path; their commuter routes would run
    # unshaped across city blocks. Bridge each isolated door to its nearest
    # corridor cell with a straight line of synthetic seeds (≤ 250 m).
    MPLAT, MPLNG = router.METERS_PER_DEG_LAT, router.METERS_PER_DEG_LNG
    bridged = 0
    for bld in buildings:
        door = R.door_of(bld)
        dr, dc = R._row(door[0]), R._col(door[1])
        # nearest corridor seed within 250 m (Bresenham-ish straight scan)
        best = None
        for (sr, sc) in seeds:
            d = math.hypot((sr - dr) * R.cell, (sc - dc) * R.cell)
            if d <= 250.0 and (best is None or d < best[0]):
                best = (d, sr, sc)
        if best is None:
            continue
        _, sr, sc = best
        n = max(1, int(best[0] / R.cell))
        for k in range(n + 1):
            t = k / n
            rr = round(dr + t * (sr - dr))
            cc = round(dc + t * (sc - dc))
            if 0 <= rr < R.nrows and 0 <= cc < R.ncols and not R.blocked[rr * R.ncols + cc]:
                seeds.add((rr, cc))
                bridged += 1
    if bridged:
        print(f"bridged isolated doors: added {bridged} synthetic seed cells")

    # Multi-source Dijkstra over walkable cells (8-connected, metric edge costs).
    INF = float("inf")
    dist = [None] * (R.nrows * R.ncols)
    import heapq
    pq = []
    for (r, c) in seeds:
        dist[r * R.ncols + c] = 0.0
        pq.append((0.0, r, c))
    heapq.heapify(pq)
    while pq:
        d, r, c = heapq.heappop(pq)
        cur = dist[r * R.ncols + c]
        if cur is None or d > cur:
            continue
        for dr in (-1, 0, 1):
            for dc in (-1, 0, 1):
                if dr == 0 and dc == 0:
                    continue
                rr, cc = r + dr, c + dc
                if not (0 <= rr < R.nrows and 0 <= cc < R.ncols):
                    continue
                if R.blocked[rr * R.ncols + cc]:
                    continue
                nd = d + R.cell * (router.DIAG if dr and dc else 1.0)
                idx = rr * R.ncols + cc
                if dist[idx] is None or nd < dist[idx]:
                    dist[idx] = nd
                    heapq.heappush(pq, (nd, rr, cc))
    reachable = sum(1 for v in dist if v is not None)
    print(f"reachable cells: {reachable}/{R.nrows * R.ncols} "
          f"({reachable / (R.nrows * R.ncols) * 100:.0f}%)")

    out = {
        "nrows": R.nrows,
        "ncols": R.ncols,
        "cell": R.cell,
        "bbox": list(bbox),
        "source_ways": len(ways),
        "fetched_utc": datetime.datetime.now(datetime.timezone.utc)
                             .strftime("%Y-%m-%dT%H:%M:%SZ"),
        "dist_to_path": dist,
    }
    with open(OUT_PATH, "w", encoding="utf-8") as f:
        json.dump(out, f)
    print(f"wrote {OUT_PATH} ({os.path.getsize(OUT_PATH) / 1e6:.1f} MB)")

    # Validate: reload through Router and report shaping coverage.
    R2 = router.Router(buildings)
    d2 = R2._dist_to_path
    if d2 is None:
        print("WARNING: Router failed to load the corridor file!")
    else:
        on = sum(1 for v in d2 if v is not None and v <= router.ON_PATH_M)
        print(f"shaping active: {on / (R2.nrows * R2.ncols) * 100:.0f}% of grid "
              f"within {router.ON_PATH_M}m of a real path")


if __name__ == "__main__":
    main()
