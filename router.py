#!/usr/bin/env python3
"""Campus Pulse — walkable-path routing between buildings.

Builds a pedestrian walkability grid over the campus bounding box, marks
building footprints (plus a small wall margin) as blocked, and routes
transit between buildings with A* over 8-connected neighbors.

Paths between building pairs are cached after first use.
"""

import heapq
import math

METERS_PER_DEG_LAT = 111320.0
COS_LAT = math.cos(math.radians(43.07))  # Madison latitude
METERS_PER_DEG_LNG = METERS_PER_DEG_LAT * COS_LAT

CELL = 6.0           # grid cell size, meters
MARGIN = 4.0         # meters of "wall" kept clear around each building
DIAG = math.sqrt(2)  # 8-connected diagonal move cost
DOOR_OFFSET = 6.0    # meters doors sit outside the building edge


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

        self._path_cache = {}
        self._door_cache = {}

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
        """Nearest-to-centroid perimeter vertex, pushed DOOR_OFFSET out."""
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

    # ── A* ──
    def _astar(self, start, goal):
        """start/goal are (row, col). Returns list of (r, c) or None."""
        nr, nc = self.nrows, self.ncols
        blocked = self.blocked
        def h(r, c):
            return math.hypot(r - goal[0], c - goal[1])
        g_best = {start: 0.0}
        came = {}
        pq = [(h(*start), 0.0, start)]
        while pq:
            f, g, cur = heapq.heappop(pq)
            if cur == goal:
                path = [cur]
                while cur in came:
                    cur = came[cur]
                    path.append(cur)
                path.reverse()
                return path
            if g > g_best.get(cur, float("inf")):
                continue
            r, c = cur
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    if dr == 0 and dc == 0:
                        continue
                    rr, cc = r + dr, c + dc
                    if not (0 <= rr < nr and 0 <= cc < nc):
                        continue
                    if blocked[rr * nc + cc]:
                        continue
                    step = self.cell * (DIAG if dr and dc else 1.0)
                    ng = g + step
                    nxt = (rr, cc)
                    if ng < g_best.get(nxt, float("inf")):
                        g_best[nxt] = ng
                        came[nxt] = cur
                        heapq.heappush(pq, (ng + h(rr, cc), ng, nxt))
        return None

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
        # simplify: keep every cell center (6 m apart is fine granularity)
        path = [list(p0)] + [list(self.to_latlng(r, c)) for r, c in cells] + [list(p1)]
        self._path_cache[key] = path
        return path

    def route_buildings(self, b0, b1):
        """Route between two buildings' doors. Cached by id pair."""
        key = (b0["id"], b1["id"])
        if key not in self._path_cache:
            self._path_cache[key] = self.route(self.door_of(b0), self.door_of(b1))
        return self._path_cache[key]
