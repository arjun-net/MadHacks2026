#!/usr/bin/env python3
"""Campus Pulse — walkable-path routing between buildings.

Builds a pedestrian walkability grid over the campus bounding box, marks
building footprints (plus a small wall margin) as blocked, and routes
transit between buildings with A* over 8-connected neighbors.

Path fidelity: A* edge costs are shaped by each cell's distance to the real
sidewalk network (OSM pedestrian ways, see tools/fetch_osm_paths.py). Cells
on/near mapped paths are cheap; open quads far from any path cost up to
(1 + OFF_PATH_WEIGHT)× per meter, so routes follow real sidewalks and only
cut across open ground when it is the only connection. Door-to-door routes
are then smoothed with exact supercover line-of-sight string-pulling, which
collapses the 6 m A* staircase into straight legs (median 11 waypoints per
route) without ever clipping a blocked cell or corner.

Paths between building pairs are cached after first use.
"""

import heapq
import json
import math
import os
from collections import deque

# Hot-loop constants for _astar: unrolled neighbor deltas with precomputed
# step costs ((dr, dc, 0.5*(step)*(1.0) base)); actual cost uses avg of the
# two cells' LUT penalties, so stepm carries the 0.5*step factor.
_DELTAS = ()  # built after CELL/DIAG are defined (see bottom of module)
_FLAT_ONES = None  # lazily built fallback LUT when no corridor file

METERS_PER_DEG_LAT = 111320.0
COS_LAT = math.cos(math.radians(43.07))  # Madison latitude
METERS_PER_DEG_LNG = METERS_PER_DEG_LAT * COS_LAT

CELL = 6.0           # grid cell size, meters
MARGIN = 4.0         # meters of "wall" kept clear around each building
DIAG = math.sqrt(2)  # 8-connected diagonal move cost
DOOR_OFFSET = 6.0    # meters doors sit outside the building edge

_DELTAS = tuple(  # (dr, dc, 0.5*step) for the 8 neighbors
    (dr, dc, 0.5 * (CELL * DIAG if dr and dc else CELL))
    for dr in (-1, 0, 1) for dc in (-1, 0, 1) if dr or dc
)

# Real-path fidelity shaping: OSM corridor file + tuning knobs.
HERE = os.path.dirname(os.path.abspath(__file__))
OSM_CORRIDOR_PATH = os.path.join(HERE, "configs", "osm_path_cells.json")
TRACED_PATHS_FILE = os.path.join(HERE, "configs", "traced_paths.json")
ON_PATH_M = 7.0     # cells within this distance of a real path count as "on path"
PENALTY_M = 12.0    # off-path cost saturates at this distance
OFF_PATH_WEIGHT = 8.0  # max per-meter cost multiplier for pathless cells
MAX_LEG_CELLS = 12  # simplify() leg cap (cells; 12 = 72m) — longer runs stay on-path


def point_in_polygon(lat, lng, polygon, bbox=None):
    """Ray-casting test. polygon = ordered [[lat, lng], ...]."""
    if bbox:
        lat_min, lat_max, lng_min, lng_max = bbox
        if not (lat_min <= lat <= lat_max and lng_min <= lng <= lng_max):
            return False
    inside = False
    n = len(polygon)
    j = n - 1
    for i in range(n):
        lat_i, lng_i = polygon[i]
        lat_j, lng_j = polygon[j]
        if (lng_i > lng) != (lng_j > lng):
            t = (lng - lng_j) / (lng_i - lng_j)
            if lat < lat_j + t * (lat_i - lat_j):
                inside = not inside
        j = i
    return inside


def _dist_m(a, b):
    """Approx meters between two [lat, lng] points."""
    return math.hypot((a[0] - b[0]) * METERS_PER_DEG_LAT,
                      (a[1] - b[1]) * METERS_PER_DEG_LNG)


def _push_out(point, polygon, dist):
    """Push `point` outward from polygon centroid to `dist` meters away."""
    clat = sum(p[0] for p in polygon) / len(polygon)
    clng = sum(p[1] for p in polygon) / len(polygon)
    dlat = point[0] - clat
    dlng = point[1] - clng
    norm = math.hypot(dlat * METERS_PER_DEG_LAT, dlng * METERS_PER_DEG_LNG)
    if norm < 1e-9:
        return point
    s = dist / norm
    return [clat + dlat * s, clng + dlng * s]


class Router:
    def __init__(self, buildings, cell=CELL, margin=MARGIN):
        """buildings: list of dicts with 'perimeter_polygon' ([lat, lng])."""
        self.cell = cell
        self.margin = margin
        self.buildings = buildings

        # Campus bounding box (all polygons + 30m pad so gates fit)
        pts = [p for b in buildings for p in b["perimeter_polygon"]]
        lats = [p[0] for p in pts]
        lngs = [p[1] for p in pts]
        self.lat_min = min(lats) - 30 / METERS_PER_DEG_LAT
        self.lat_max = max(lats) + 30 / METERS_PER_DEG_LAT
        self.lng_min = min(lngs) - 30 / METERS_PER_DEG_LNG
        self.lng_max = max(lngs) + 30 / METERS_PER_DEG_LNG

        self.nrows = int((self.lat_max - self.lat_min) * METERS_PER_DEG_LAT / cell)
        self.ncols = int((self.lng_max - self.lng_min) * METERS_PER_DEG_LNG / cell)

        # Blocked mask: 1 = unwalkable (building footprint + margin)
        self.blocked = bytearray(self.nrows * self.ncols)
        margin_lat = margin / METERS_PER_DEG_LAT
        margin_lng = margin / METERS_PER_DEG_LNG
        for b in buildings:
            poly = b["perimeter_polygon"]
            lats = [p[0] for p in poly]
            lngs = [p[1] for p in poly]
            # Cell window that could possibly touch this polygon
            r0 = self._row(max(lats) + margin_lat)
            r1 = self._row(min(lats) - margin_lat)
            c0 = self._col(min(lngs) - margin_lng)
            c1 = self._col(max(lngs) + margin_lng)
            for r in range(max(0, r0), min(self.nrows, r1 + 1)):
                for c in range(max(0, c0), min(self.ncols, c1 + 1)):
                    lat, lng = self.to_latlng(r, c)
                    if point_in_polygon(lat, lng, poly) or self._near_polygon(
                        lat, lng, poly, margin
                    ):
                        self.blocked[r * self.ncols + c] = 1

        # Seal courtyards of hollow (donut-shaped) footprints: flood fill from
        # the grid border and block any open cell unreachable from outside —
        # otherwise a door snapped into an enclosed courtyard strands A*.
        border = deque()
        seen = set()
        for c in range(self.ncols):
            for rr in (0, self.nrows - 1):
                if self._walkable(rr, c):
                    seen.add((rr, c))
                    border.append((rr, c))
        for rr in range(self.nrows):
            for c in (0, self.ncols - 1):
                if self._walkable(rr, c) and (rr, c) not in seen:
                    seen.add((rr, c))
                    border.append((rr, c))
        while border:
            rr, c = border.popleft()
            for dr, dc in ((1, 0), (-1, 0), (0, 1), (0, -1),
                           (1, 1), (1, -1), (-1, 1), (-1, -1)):
                n = (rr + dr, c + dc)
                if n not in seen and self._walkable(*n):
                    seen.add(n)
                    border.append(n)
        for rr in range(self.nrows):
            for c in range(self.ncols):
                if self._walkable(rr, c) and (rr, c) not in seen:
                    self.blocked[rr * self.ncols + c] = 1

        self._path_cache = {}
        self._door_cache = {}
        self._dist_to_path = self._load_path_distances()
        self._build_cost_lut()

    # ── Grid indexing ──
    def _row(self, lat):
        return int((self.lat_max - lat) * METERS_PER_DEG_LAT / self.cell)

    def _col(self, lng):
        return int((lng - self.lng_min) * METERS_PER_DEG_LNG / self.cell)

    def to_latlng(self, r, c):
        return (
            self.lat_max - (r + 0.5) * self.cell / METERS_PER_DEG_LAT,
            self.lng_min + (c + 0.5) * self.cell / METERS_PER_DEG_LNG,
        )

    def _walkable(self, r, c):
        return 0 <= r < self.nrows and 0 <= c < self.ncols and not self.blocked[r * self.ncols + c]

    def _near_polygon(self, lat, lng, poly, margin_m):
        """True if (lat, lng) is within margin_m meters of any polygon edge."""
        mlat = margin_m / METERS_PER_DEG_LAT
        mlng = margin_m / METERS_PER_DEG_LNG
        n = len(poly)
        for i in range(n):
            a = poly[i]
            b = poly[(i + 1) % n]
            # quick reject
            if abs(lat - a[0]) > mlat * 2 and abs(lat - b[0]) > mlat * 2:
                continue
            if abs(lng - a[1]) > mlng * 2 and abs(lng - b[1]) > mlng * 2:
                continue
            if self._point_seg_dist_m((lat, lng), (a, b)) <= margin_m:
                return True
        return False

    @staticmethod
    def _point_seg_dist_m(p, seg):
        """Distance in meters from point p to segment (a, b)."""
        ax, ay = seg[0][1] * METERS_PER_DEG_LNG, seg[0][0] * METERS_PER_DEG_LAT
        bx, by = seg[1][1] * METERS_PER_DEG_LNG, seg[1][0] * METERS_PER_DEG_LAT
        px, py = p[1] * METERS_PER_DEG_LNG, p[0] * METERS_PER_DEG_LAT
        dx, dy = bx - ax, by - ay
        seg_len2 = dx * dx + dy * dy
        if seg_len2 < 1e-12:
            return math.hypot(px - ax, py - ay)
        t = max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / seg_len2))
        return math.hypot(px - (ax + t * dx), py - (ay + t * dy))

    # ── Doors ──
    def door_of(self, building):
        """Nearest-to-centroid perimeter vertex, pushed OUTSIDE the footprint
        plus the wall margin (DOOR_OFFSET minimum) along the centroid ray —
        doors that sit inside the building make routes cut the footprint."""
        bid = building["id"]
        cached = self._door_cache.get(bid)
        if cached:
            return cached
        poly = building["perimeter_polygon"]
        clat = sum(p[0] for p in poly) / len(poly)
        clng = sum(p[1] for p in poly) / len(poly)
        # pick the perimeter vertex closest to the centroid as the door side
        best = min(poly, key=lambda p: _dist_m(p, (clat, clng)))
        door = _push_out(best, poly, DOOR_OFFSET)
        # Walk further out until clear of footprint + margin + 1m slack
        lat, lng = door
        dlat = (lat - clat) / METERS_PER_DEG_LAT
        dlng = (lng - clng) / METERS_PER_DEG_LNG
        norm = math.hypot(dlat, dlng)
        if norm > 1e-12:
            ulat, ulng = dlat / norm, dlng / norm
            for _ in range(200):  # 1m steps, hard cap 200m
                if not (point_in_polygon(lat, lng, poly)
                        or self._near_polygon(lat, lng, poly, self.margin)):
                    break
                lat += ulat / METERS_PER_DEG_LAT
                lng += ulng / METERS_PER_DEG_LNG
            door = [lat, lng]
        self._door_cache[bid] = door
        return door

    def _nearest_open_cell(self, lat, lng):
        """Nearest walkable cell to a coordinate (spiral search)."""
        r0, c0 = self._row(lat), self._col(lng)
        if self._walkable(r0, c0):
            return r0, c0
        for radius in range(1, 40):
            for dr in range(-radius, radius + 1):
                for dc in (-radius, radius):
                    if self._walkable(r0 + dr, c0 + dc):
                        return r0 + dr, c0 + dc
                for dc in range(-radius + 1, radius):
                    for dr in (-radius, radius):
                        if self._walkable(r0 + dr, c0 + dc):
                            return r0 + dr, c0 + dc
        return None

    def _load_path_distances(self):
        """Per-cell distance (meters, 8-connected grid metric) to the nearest
        real OSM pedestrian path, loaded from a precomputed file produced by
        tools/fetch_osm_paths.py. Falls back to None when the file is absent
        or stale (grid size mismatch), in which case A* behaves unshaped.
        Manually traced paths (configs/traced_paths.json, from the Path
        Tracer editor) are overlaid as additional corridor seeds."""
        try:
            with open(OSM_CORRIDOR_PATH, "r", encoding="utf-8") as f:
                data = json.load(f)
            if data.get("nrows") != self.nrows or data.get("ncols") != self.ncols:
                return None
            d = data["dist_to_path"]
            if len(d) != self.nrows * self.ncols:
                return None
            self._apply_traced_paths(d)
            return d
        except (OSError, KeyError, ValueError):
            return None

    def _build_cost_lut(self):
        """Precompute per-cell cost multiplier once; _cell_penalty is a pure
        list lookup afterwards (~420M calls per full sim -> this matters)."""
        d = self._dist_to_path
        n = self.nrows * self.ncols
        if d is None:
            global _FLAT_ONES
            if _FLAT_ONES is None:
                _FLAT_ONES = [1.0] * n
            self._cost_lut = _FLAT_ONES
            return
        lut = [1.0 + OFF_PATH_WEIGHT] * n
        scale = OFF_PATH_WEIGHT / PENALTY_M
        for i in range(n):
            v = d[i]
            if v is not None and v >= 0:
                p = v if v < PENALTY_M else PENALTY_M
                lut[i] = 1.0 + scale * p
        self._cost_lut = lut

    def _apply_traced_paths(self, dist):
        """Overlay manually traced paths: rasterize each traced polyline to
        3m sample points and run a bounded multi-source relaxation (60m cap)
        so cells near a traced path become cheap even where OSM has nothing."""
        try:
            with open(TRACED_PATHS_FILE, "r", encoding="utf-8") as f:
                traced = json.load(f).get("paths", [])
        except (OSError, ValueError):
            return
        seeds = set()
        for p in traced:
            vts = p.get("vertices") or []
            for a, b in zip(vts, vts[1:]):
                n = max(1, int(math.hypot((b[0] - a[0]) * METERS_PER_DEG_LAT,
                                          (b[1] - a[1]) * METERS_PER_DEG_LNG) / 3))
                for k in range(n + 1):
                    t = k / n
                    r = self._row(a[0] + t * (b[0] - a[0]))
                    c = self._col(a[1] + t * (b[1] - a[1]))
                    if 0 <= r < self.nrows and 0 <= c < self.ncols:
                        seeds.add((r, c))
        if not seeds:
            return
        import heapq
        CAP = 60.0
        pq = []
        for (r, c) in seeds:
            i = r * self.ncols + c
            if dist[i] is None or dist[i] > 0.0:
                dist[i] = 0.0
                pq.append((0.0, i))
        heapq.heapify(pq)
        while pq:
            d, i = heapq.heappop(pq)
            if d > (dist[i] if dist[i] is not None else float("inf")):
                continue
            if d >= CAP:
                continue
            r, c = divmod(i, self.ncols)
            for dr, dc, stepm in _DELTAS:
                rr, cc = r + dr, c + dc
                if not (0 <= rr < self.nrows and 0 <= cc < self.ncols):
                    continue
                ni = rr * self.ncols + cc
                if self.blocked[ni]:
                    continue
                nd = d + stepm * 2.0  # stepm is 0.5*step; full step = 2*stepm
                if dist[ni] is None or nd < dist[ni]:
                    dist[ni] = nd
                    heapq.heappush(pq, (nd, ni))

    def _cell_penalty(self, r, c):
        """Per-meter cost multiplier for cell (r, c): 1.0 on a real path,
        rising linearly to (1 + OFF_PATH_WEIGHT) at PENALTY_M off-path.
        Precomputed in _build_cost_lut()."""
        lut = self._cost_lut
        if lut is None:
            return 1.0
        return lut[r * self.ncols + c]

    # ── A* ──
    def _astar(self, start, goal):
        """start/goal are (row, col). Returns list of (r, c) or None.

        Hot loop is flat-index based (int keys instead of tuples) with the
        cost LUT and deltas hoisted — ~3x faster than the naive form."""
        nr, nc = self.nrows, self.ncols
        blocked = self.blocked
        lut = self._cost_lut
        if lut is None:
            lut = _FLAT_ONES
        cell = self.cell
        half_diag = 0.5 * DIAG * cell
        gr0, gc0 = start
        gi0 = gr0 * nc + gc0
        gr1, gc1 = goal
        gi1 = gr1 * nc + gc1
        cell_diag = cell * DIAG
        g_best = {gi0: 0.0}
        came = {}
        h0 = math.hypot(gr0 - gr1, gc0 - gc1) * cell
        pq = [(h0, 0.0, gi0)]
        push, pop = heapq.heappush, heapq.heappop
        hyp = math.hypot
        inf = float("inf")
        while pq:
            f, g, gi = pop(pq)
            if gi == gi1:
                path = [goal]
                while gi in came:
                    gi = came[gi]
                    gc_ = gi % nc
                    path.append((gi // nc, gc_))
                path.reverse()
                return path
            if g > g_best.get(gi, inf):
                continue
            r, c = divmod(gi, nc)
            pr = lut[gi]
            # 8 deltas: (drow, dcol, step, step*0.5 for avg-penalty form)
            for dr, dc, stepm in _DELTAS:
                rr = r + dr
                if rr < 0 or rr >= nr:
                    continue
                cc = c + dc
                if cc < 0 or cc >= nc:
                    continue
                nfi = rr * nc + cc
                if blocked[nfi]:
                    continue
                ng = g + stepm * (pr + lut[nfi])
                if ng < g_best.get(nfi, inf):
                    g_best[nfi] = ng
                    came[nfi] = gi
                    push(pq, (ng + hyp(rr - gr1, cc - gc1) * cell, ng, nfi))
        return None

    # ── Path smoothing ──
    def _line_of_sight(self, a, b):
        """True if the straight segment between cells a and b passes only
        through walkable cells (supercover Bresenham — never cuts a corner
        through a blocked cell, including diagonally)."""
        r0, c0 = a
        r1, c1 = b
        dr = r1 - r0
        dc = c1 - c0
        # Exact supercover (Amanatides & Woo style): advance across every
        # grid-line crossing, ordered by t along the segment. When a row and
        # a column crossing coincide (t & a corner), ALL 4 cells around that
        # corner are touched — if any is blocked, corner-cutting is possible,
        # so the leg is rejected. This is conservative and exact.
        rr, cc = r0, c0
        next_r = r0 + (1 if dr > 0 else -1) if dr else None
        next_c = c0 + (1 if dc > 0 else -1) if dc else None
        while (next_r is not None) or (next_c is not None):
            # boundary line just crossed when stepping INTO next_r: the edge
            # between current cell and next cell (half-integer between them).
            t_r = ((next_r - 0.5 * (1 if dr > 0 else -1)) - r0) / dr \
                if (dr and next_r is not None) else float("inf")
            t_c = ((next_c - 0.5 * (1 if dc > 0 else -1)) - c0) / dc \
                if (dc and next_c is not None) else float("inf")
            if t_r < t_c - 1e-9:
                rr = next_r
                next_r = next_r + (1 if dr > 0 else -1)
                if dr and (rr == r1):
                    next_r = None
            elif t_c < t_r - 1e-9:
                cc = next_c
                next_c = next_c + (1 if dc > 0 else -1)
                if dc and (cc == c1):
                    next_c = None
            else:
                # corner crossing: row and column lines at same t. The segment
                # passes through the corner point shared by 4 cells; all 4
                # must be walkable, otherwise it grazes a blocked cell.
                nr_, nc_ = next_r, next_c
                if not (self._walkable(nr_, nc_) and self._walkable(nr_, cc)
                        and self._walkable(rr, nc_)):
                    return False
                rr, cc = nr_, nc_
                next_r = nr_ + (1 if dr > 0 else -1) if nr_ != r1 else None
                next_c = nc_ + (1 if dc > 0 else -1) if nc_ != c1 else None
            if not self._walkable(rr, cc):
                return False
        return True

    def _simplify(self, cells):
        """String-pulling with a leg-length cap: replace A* staircase with
        straight legs wherever line-of-sight allows, but never collapse a
        run longer than MAX_LEG_CELLS into one leg. The cap keeps the route
        hugging the real path's curvature across long open stretches (uncapped
        LOS pulls 200m+ dead-straight "chords" across quads and lawns).
        Typical route: 100+ cells -> 10-30 waypoints."""
        out = [cells[0]]
        i = 0
        n = len(cells)
        while i < n - 1:
            j = min(i + MAX_LEG_CELLS, n - 1)
            while j > i + 1 and not self._line_of_sight(cells[i], cells[j]):
                j -= 1
            out.append(cells[j])
            i = j
        return out

    # ── Public API ──
    def route(self, p0, p1):
        """Route between two [lat, lng] points. Returns list of waypoints
        ([lat, lng], incl. endpoints), or None if no path found."""
        key = (round(p0[0], 6), round(p0[1], 6), round(p1[0], 6), round(p1[1], 6))
        if key in self._path_cache:
            return self._path_cache[key]
        s = self._nearest_open_cell(*p0)
        g = self._nearest_open_cell(*p1)
        if s is None or g is None:
            return None
        cells = self._astar(s, g)
        if cells is None:
            return None
        cells = self._simplify(cells)
        path = [list(p0)] + [list(self.to_latlng(r, c)) for r, c in cells] + [list(p1)]
        self._path_cache[key] = path
        return path

    def route_buildings(self, b0, b1):
        """Route between two buildings' doors. Cached by id pair."""
        key = (b0["id"], b1["id"])
        if key not in self._path_cache:
            self._path_cache[key] = self.route(self.door_of(b0), self.door_of(b1))
        return self._path_cache[key]
