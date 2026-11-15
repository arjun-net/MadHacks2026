#!/usr/bin/env python3
"""Coverage check: Mapbox-extracted paths vs OSM paths, per used building.

For each building the generator uses, report the minimum distance from its
door to the nearest Mapbox path line and nearest OSM way — this tells us
whether Mapbox fills the gaps our OSM snapshot missed.
"""

import json
import math
import sys

sys.path.insert(0, ".")

MPLAT = 111320.0
MPLNG = 111320.0 * math.cos(math.radians(43.07))


def pt_seg(px, py, ax, ay, bx, by):
    """Distance in METERS. All inputs are (lat, lng) degrees."""
    px *= MPLAT; py *= MPLNG; ax *= MPLAT; ay *= MPLNG; bx *= MPLAT; by *= MPLNG
    dx, dy = bx - ax, by - ay
    L2 = dx * dx + dy * dy
    if L2 == 0:
        return math.hypot(px - ax, py - ay)
    t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / L2))
    return math.hypot(px - (ax + t * dx), py - (ay + t * dy))


def build_index(lines, bucket=0.0008):
    idx = {}
    for li, ln in enumerate(lines):
        cs = ln["coords"]
        for k in range(len(cs) - 1):
            lat = (cs[k][0] + cs[k + 1][0]) / 2
            lng = (cs[k][1] + cs[k + 1][1]) / 2
            key = (int((lat - 43) / bucket), int((lng + 90) / bucket))
            idx.setdefault(key, []).append(li)
    return idx, bucket


def min_dist(pt, lines, idx, bucket):
    pr, pc = int((pt[0] - 43) / bucket), int((pt[1] + 90) / bucket)
    best = float("inf")
    seen = set()
    R = 8  # 8 buckets ≈ 715m search radius
    for dr in range(-R, R + 1):
        for dc in range(-R, R + 1):
            for li in idx.get((pr + dr, pc + dc), ()):
                if li in seen:
                    continue
                seen.add(li)
                cs = lines[li]["coords"]
                for k in range(len(cs) - 1):
                    d = pt_seg(pt[0], pt[1], cs[k][0], cs[k][1], cs[k+1][0], cs[k+1][1])
                    if d < best:
                        best = d
    return best


def main():
    mb = json.load(open("/tmp/uw_mapbox_paths.json"))["lines"]
    osm = []
    for cand in ("/tmp/uw_ways.json", "/tmp/uw_roads.json"):
        try:
            for e in json.load(open(cand)).get("elements", []):
                g = e.get("geometry")
                if g:
                    osm.append({"coords": [[p["lat"], p["lon"]] for p in g]})
        except (OSError, ValueError):
            pass

    mb_idx, buck = build_index(mb)
    osm_idx, _ = build_index(osm)

    from router import Router
    buildings = json.load(open("configs/buildings.json"))["buildings"]
    # generator-used buildings: types mapped in generator. Use presence of 'id'
    R = Router(buildings)
    used = [b for b in buildings if b.get("type") != "housing"]
    print(f"{'building':<22}{'mb_min_m':>9}{'osm_min_m':>10}")
    gaps = 0
    rows = []
    for b in used:
        door = R.door_of(b)
        dmb = min_dist(door, mb, mb_idx, buck)
        dosm = min_dist(door, osm, osm_idx, buck)
        rows.append((b["id"], dmb, dosm))
        if dmb > 12:
            gaps += 1
    for bid, dmb, dosm in sorted(rows, key=lambda r: -r[1]):
        flag = "  <-- still >12m from any Mapbox path" if dmb > 12 else ""
        print(f"{bid:<22}{dmb:>9.1f}{dosm:>10.1f}{flag}")
    print(f"\n{gaps}/{len(used)} used buildings still >12m from any Mapbox path")


if __name__ == "__main__":
    main()
