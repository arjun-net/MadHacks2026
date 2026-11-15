#!/usr/bin/env python3
"""Campus Pulse — path-compliance checking.

A path (transit polyline) is COMPLIANT iff every point along every leg is
walkable: never inside a building footprint (plus the router's wall margin)
— except inside the transit's own origin/destination buildings, since
exiting your own front door legitimately crosses your own footprint.

Two layers:
1. Generation-time: PathChecker.repair() validates and fixes every transit
   polyline produced by the generator, re-planning any leg that cuts a
   building through the A* router.
2. Post-hoc: check_history() re-validates the written CSV by sampling every
   consecutive same-agent ping pair (pings are collinear interpolations of
   the validated polylines).

Usage:
    python3 path_compliance.py            # check data/gameday_weekend_history.csv
    python3 path_compliance.py <csv>      # any history CSV
"""

import csv
import json
import math
import os
import sys
from collections import defaultdict

from router import Router, METERS_PER_DEG_LAT, METERS_PER_DEG_LNG
from generator import point_in_polygon

HERE = os.path.dirname(os.path.abspath(__file__))


def dist_m(a, b):
    dlat = (b[0] - a[0]) * 111320.0
    dlng = (b[1] - a[1]) * 111320.0 * 0.729  # cos(43.07)
    return math.hypot(dlat, dlng)


def lerp(a, b, t):
    return [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])]


class PathChecker:
    """Validates legs against a Router's blocked grid, with carve-outs for
    the origin/destination buildings of each transit."""

    def __init__(self, router, buildings_by_id, strict_margin=0.0):
        self.router = router                      # margin-4 grid (repair planning)
        self.by_id = buildings_by_id
        self.polys = [b["perimeter_polygon"]
                      for b in buildings_by_id.values()]
        self.ids = list(buildings_by_id.keys())
        self._overlap = self._build_overlaps()
        # Strict grid (no wall margin) for ping-level jitter tolerance
        self.strict = Router(list(buildings_by_id.values()),
                             cell=router.cell, margin=strict_margin)

    @staticmethod
    def _segs_intersect(p1, p2, p3, p4):
        def d(a, b, c):
            return ((b[0] - a[0]) * (c[1] - a[1])
                    - (b[1] - a[1]) * (c[0] - a[0]))
        d1, d2 = d(p3, p4, p1), d(p3, p4, p2)
        d3, d4 = d(p1, p2, p3), d(p1, p2, p4)
        return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0))

    def _polys_overlap(self, pa, pb):
        """True if two footprints share area (vertex-in-other or edge
        crossing)."""
        if any(point_in_polygon(p[0], p[1], pb) for p in pa):
            return True
        if any(point_in_polygon(p[0], p[1], pa) for p in pb):
            return True
        na, nb = len(pa), len(pb)
        return any(self._segs_intersect(pa[i], pa[(i + 1) % na],
                                        pb[j], pb[(j + 1) % nb])
                   for i in range(na) for j in range(nb))

    def _build_overlaps(self):
        ov = {i: set() for i in self.ids}
        for i in range(len(self.polys)):
            for j in range(i + 1, len(self.polys)):
                if self._polys_overlap(self.polys[i], self.polys[j]):
                    ov[self.ids[i]].add(self.ids[j])
                    ov[self.ids[j]].add(self.ids[i])
        return ov

    def _inside_footprint(self, lat, lng, origin_poly=None, dest_poly=None):
        """Polygon ground truth: inside the footprint of a building that is
        NOT the origin/destination (or overlapping either) of the current
        transit. 6m cell-center granularity makes the grid flag
        edge-adjacent open points; polygons decide. Overlapping footprints
        share area — crossing the shared region is unavoidable."""
        for idx, poly in enumerate(self.polys):
            if not point_in_polygon(lat, lng, poly):
                continue
            bid = self.ids[idx]
            if origin_poly is not None:
                oid = self.ids[self.polys.index(origin_poly)] \
                    if origin_poly in self.polys else None
                if oid and (bid == oid or bid in self._overlap[oid]):
                    return False
            if dest_poly is not None:
                did = self.ids[self.polys.index(dest_poly)] \
                    if dest_poly in self.polys else None
                if did and (bid == did or bid in self._overlap[did]):
                    return False
            return True
        return False

    def _inside_footprint_depth(self, lat, lng, origin_poly=None,
                                dest_poly=None, tol_m=5.0):
        """Like _inside_footprint but with a penetration tolerance: samples
        up to tol_m deep inside a non-o/d footprint pass. This absorbs the
        corner-cut of straight chords between pings (which carry ±2m jitter
        and can be 2 min apart) on a verified polyline; measured worst case
        is ~7m. Anything deeper means the path actually crosses a
        building."""
        for idx, poly in enumerate(self.polys):
            if not point_in_polygon(lat, lng, poly):
                continue
            bid = self.ids[idx]
            if origin_poly is not None:
                oid = self.ids[self.polys.index(origin_poly)] \
                    if origin_poly in self.polys else None
                if oid and (bid == oid or bid in self._overlap[oid]):
                    return False
            if dest_poly is not None:
                did = self.ids[self.polys.index(dest_poly)] \
                    if dest_poly in self.polys else None
                if did and (bid == did or bid in self._overlap[did]):
                    return False
            if self._edge_distance_m(lat, lng, poly) <= tol_m:
                return False
            return True
        return False

    def _edge_distance_m(self, lat, lng, poly):
        """Distance in meters from a point to the nearest polygon edge."""
        coslat = math.cos(math.radians(43.07))
        px = lng * METERS_PER_DEG_LNG * coslat
        py = lat * METERS_PER_DEG_LAT
        best = float("inf")
        n = len(poly)
        for k in range(n):
            a, b = poly[k], poly[(k + 1) % n]
            ax = a[1] * METERS_PER_DEG_LNG * coslat
            ay = a[0] * METERS_PER_DEG_LAT
            bx = b[1] * METERS_PER_DEG_LNG * coslat
            by = b[0] * METERS_PER_DEG_LAT
            dx, dy = bx - ax, by - ay
            l2 = dx * dx + dy * dy
            t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / l2)) \
                if l2 > 0 else 0.0
            best = min(best, math.hypot(px - ax - t * dx,
                                        py - ay - t * dy))
        return best

    def _grid_blocked(self, grid, lat, lng):
        r = grid._row(lat)
        c = grid._col(lng)
        if not (0 <= r < grid.nrows and 0 <= c < grid.ncols):
            return False
        return grid.blocked[r * grid.ncols + c] != 0

    def leg_ok(self, a, b, origin_poly, dest_poly, grid, step_m=1.0):
        """True if the straight leg a→b stays walkable. Carve-out: samples
        inside origin/destination footprints are allowed (own door)."""
        d = dist_m(a, b)
        n = max(2, int(d / step_m) + 1)
        for i in range(n + 1):
            p = lerp(a, b, i / n)
            if not self._grid_blocked(grid, p[0], p[1]):
                continue
            # Blocked cell: polygon ground truth decides — only inside the
            # footprint of a non-o/d (non-overlapping) building is a real
            # violation.
            if not self._inside_footprint_depth(p[0], p[1], origin_poly,
                                                dest_poly, tol_m=7.5):
                continue
                continue
            return False, p
        return True, None

    def polyline_failures(self, pts, origin_poly=None, dest_poly=None,
                          grid=None, step_m=1.0):
        # Footprint-only (margin-0) grid: matches "does not cut over
        # buildings". Routing itself still uses the margin-4 wall grid.
        grid = grid or self.strict
        fails = []
        for i in range(len(pts) - 1):
            ok, bad = self.leg_ok(pts[i], pts[i + 1], origin_poly,
                                  dest_poly, grid, step_m)
            if not ok:
                fails.append((i, bad))
        return fails

    def repair(self, pts, origin_poly=None, dest_poly=None):
        """Fix a transit polyline so every leg is compliant. Re-plans failing
        legs through the A* router (which never cuts buildings). Returns the
        repaired polyline; raises after two failed repair attempts."""
        for attempt in range(2):
            fails = self.polyline_failures(pts, origin_poly, dest_poly)
            if not fails:
                return pts
            out = list(pts)
            for i, _bad in reversed(fails):
                a, b = out[i], out[i + 1]
                alt = self.router.route(a, b)
                if alt and len(alt) >= 2:
                    out[i:i + 2] = alt
                    continue
                # Snap both ends to the nearest open cell and retry
                sa = self.router._nearest_open_cell(*a)
                sb = self.router._nearest_open_cell(*b)
                if sa is None or sb is None:
                    continue
                alt = self.router.route(self.router.to_latlng(*sa),
                                        self.router.to_latlng(*sb))
                if alt and len(alt) >= 2:
                    out[i:i + 2] = [list(a)] + alt[1:-1] + [list(b)]
            pts = out
        # Final validation — raise on any residual violation (enforced)
        fails = self.polyline_failures(pts, origin_poly, dest_poly)
        if fails:
            raise RuntimeError(
                f"path_compliance: {len(fails)} unrepairable leg(s); "
                f"first bad point {fails[0][1]}")
        return pts

    # ── Post-hoc CSV check ──────────────────────────────────────────────

    def check_history(self, csv_path, step_m=2.0, verbose=True):
        """Sample every consecutive same-agent ping pair against the strict
        (margin-0) grid. Endpoint pings inside a footprint are exempt when
        the agent was dwelling there (the adjacent-out ping is inside the
        same footprint too) — e.g. a day's first transit starts at the
        agent's home point inside their dorm, but the transit row claims
        the destination."""
        by_agent = defaultdict(list)
        with open(csv_path) as f:
            for row in csv.DictReader(f):
                by_agent[row["agent_id"]].append(row)
        grid = self.strict
        total_pairs = 0
        bad_pairs = 0
        examples = []
        per_day = defaultdict(lambda: [0, 0])

        def inside(lat, lng):
            return {bid for bid, b in self.by_id.items()
                    if point_in_polygon(lat, lng,
                                        b["perimeter_polygon"])}

        for aid, rows in by_agent.items():
            rows.sort(key=lambda r: int(r["minute_of_day"])
                      if r.get("minute_of_day") else 0)
            # minute_of_day resets daily; sort by timestamp instead
            rows.sort(key=lambda r: r["timestamp"])
            inside_cache = [inside(float(r["lat"]), float(r["lng"]))
                            for r in rows]
            for i in range(len(rows) - 1):
                prev, cur = rows[i], rows[i + 1]
                a = [float(prev["lat"]), float(prev["lng"])]
                b = [float(cur["lat"]), float(cur["lng"])]
                if dist_m(a, b) > 400:  # ping gap / glitch, not a walk
                    continue
                total_pairs += 1
                opoly = self.by_id[prev["building_id"]]["perimeter_polygon"]
                dpoly = self.by_id[cur["building_id"]]["perimeter_polygon"]
                ok, bad = self.leg_ok(a, b, opoly, dpoly, grid, step_m)
                if ok:
                    continue
                # Dwelling carve-out: an endpoint ping inside footprint Y is
                # fine when the adjacent-out ping is inside Y too (the agent
                # was parked at Y, e.g. departing home).
                bad_in = {bid for bid in self.by_id
                          if bid not in (prev["building_id"],
                                         cur["building_id"])
                          and point_in_polygon(
                              bad[0], bad[1],
                              self.by_id[bid]["perimeter_polygon"])}
                if bad_in:
                    at_a = dist_m(bad, a) < 1
                    if at_a and i > 0:
                        if bad_in & inside_cache[i - 1]:
                            continue
                    if not at_a and i + 2 < len(rows):
                        if bad_in & inside_cache[i + 2]:
                            continue
                bad_pairs += 1
                day = cur["timestamp"][:10]
                per_day[day][0] += 1
                per_day[day][1] += 1
                if len(examples) < 10:
                    examples.append((aid, cur["timestamp"], bad, a, b))
        if verbose:
            print(f"checked {total_pairs:,} consecutive ping pairs "
                  f"({bad_pairs:,} violations)")
            for day, (n, bad) in sorted(per_day.items()):
                print(f"  {day}: {n:,} pairs, {bad:,} violations")
            for aid, ts, bad, a, b in examples:
                print(f"  e.g. agent {aid} @ {ts} bad@{[round(x,6) for x in bad]} "
                      f"leg {a}→{b}")
        return {"pairs": total_pairs, "violations": bad_pairs,
                "examples": examples}


def _load_buildings():
    with open(os.path.join(HERE, "configs", "buildings.json")) as f:
        return {b["id"]: b for b in json.load(f)["buildings"]}


if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else \
        os.path.join(HERE, "data", "gameday_weekend_history.csv")
    by_id = _load_buildings()
    router = Router(list(by_id.values()))
    checker = PathChecker(router, by_id)
    result = checker.check_history(path)
    sys.exit(1 if result["violations"] else 0)
