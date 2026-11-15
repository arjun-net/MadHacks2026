#!/usr/bin/env python3
"""Campus Pulse — student movement simulation generator (v2).

Population model:
- Residents (1 - commuter_share) live in a dorm, sleep on campus, may eat
  at dining halls.
- Commuters (commuter_share, default 60%) live off campus in a `housing`
  building (chosen from buildings.json, least-filled first), walk to
  campus in the morning (6:00-12:00), spend the day on campus, and walk
  back home in the evening (17:00-23:00).  They never generate
  dining-hall visits.

Each agent's day is assembled chronologically: classes are placed per the
archetype's class_pattern (morning / afternoon / spread), gaps are filled
with study / social / gym / club chunks (probabilistic), and the day ends
with a return home (residents) or gate departure (commuters).

Usage:
    python generator.py
    python generator.py --agents 800 --seed 7 --out data/my_run.csv
"""

import argparse
import collections
import concurrent.futures as cf
import csv
import json
import math
import os
import random
import time
from datetime import datetime, timedelta, timezone

from router import Router
from router import METERS_PER_DEG_LAT, METERS_PER_DEG_LNG

HERE = os.path.dirname(os.path.abspath(__file__))
BUILDINGS_PATH = os.path.join(HERE, "configs", "buildings.json")
SCHEDULES_PATH = os.path.join(HERE, "configs", "schedules.json")

DAY_MINUTES = 24 * 60


# ── Geometry ────────────────────────────────────────────────────────────

def point_in_polygon(lat, lng, polygon):
    """Ray-casting test. `polygon` is an ordered list of [lat, lng] vertices."""
    inside = False
    n = len(polygon)
    j = n - 1
    for i in range(n):
        lat_i, lng_i = polygon[i]
        lat_j, lng_j = polygon[j]
        if (lng_i > lng) != (lng_j > lng):
            t = (lng - lng_j) / (lng_i - lng_j)
            cross_lat = lat_j + t * (lat_i - lat_j)
            if lat < cross_lat:
                inside = not inside
        j = i
    return inside


def random_point_in_polygon(polygon, rng, max_attempts=200):
    """Uniform random point inside the polygon via rejection sampling."""
    lats = [p[0] for p in polygon]
    lngs = [p[1] for p in polygon]
    lat_min, lat_max = min(lats), max(lats)
    lng_min, lng_max = min(lngs), max(lngs)
    for _ in range(max_attempts):
        lat = rng.uniform(lat_min, lat_max)
        lng = rng.uniform(lng_min, lng_max)
        if point_in_polygon(lat, lng, polygon):
            return lat, lng
    return sum(lats) / len(lats), sum(lngs) / len(lngs)


def entrance_point(building, rng, frac_range=(0.25, 0.45)):
    """Agent's hold point for a building: slightly inside the entrance door,
    NOT a random interior point. Transit paths route to the building's door;
    a random interior destination forced a long straight tail (through the
    footprint or across open ground) from door to dest — the "beaming"
    artifact. Keeping dest within a few meters of the door keeps every
    transit leg on the routed walkway."""
    poly = building["perimeter_polygon"]
    clat = sum(p[0] for p in poly) / len(poly)
    clng = sum(p[1] for p in poly) / len(poly)
    door = ROUTER.door_of(building) if ROUTER else (clat, clng)
    frac = rng.uniform(*frac_range)
    return (door[0] + (clat - door[0]) * frac,
            door[1] + (clng - door[1]) * frac)


def jitter(rng, lat, lng, amt=None):
    """Small GPS-accuracy wobble, applied per ping.

    amt: offset in meters. Configurable via schedules.json ->
    simulation.ping_jitter_meters. Default 2m (~ half a phone's typical
    GPS spread while standing still)."""
    if amt is None:
        amt = PING_JITTER_M
    if amt <= 0:
        return lat, lng
    # Gaussian offset, radius scaled to meters then converted to degrees
    theta = rng.uniform(0, 2 * math.pi)
    r = abs(rng.gauss(0, amt / 2))
    return (lat + r * math.cos(theta) / METERS_PER_DEG_LAT,
            lng + r * math.sin(theta) / METERS_PER_DEG_LNG)


PING_JITTER_M = 2.0  # default; overridden from schedules.json in simulate()


# ── Config ──────────────────────────────────────────────────────────────

def load_configs():
    with open(BUILDINGS_PATH, "r", encoding="utf-8") as f:
        buildings = json.load(f)["buildings"]
    with open(SCHEDULES_PATH, "r", encoding="utf-8") as f:
        schedules = json.load(f)

    by_id = {b["id"]: b for b in buildings}
    pools = {}
    for b in buildings:
        pools.setdefault(b["type"], []).append(b["id"])
    for needed in ("class", "study", "dining", "social", "gym", "dorm",
                   "housing"):
        if needed not in pools:
            raise SystemExit(f"No buildings of type '{needed}' in buildings.json")
    return schedules, by_id, pools


# ── Day assembly ────────────────────────────────────────────────────────

def seg(state, target, kind, p0, p1, start, end, waypoints=None):
    return {
        "state": state, "target": target, "kind": kind,
        "lat0": p0[0], "lng0": p0[1],
        "lat1": p1[0] if p1 else None, "lng1": p1[1] if p1 else None,
        "start": start, "end": end,
        "waypoints": waypoints,
    }


# Module-level router, initialized once in simulate().
ROUTER = None


def build_agent_day(arch, pools, behavior, rng, commuter, home_id=None):
    """Return (segments, home_id). Segments are chronological; both
    residents and commuters start asleep at home (residents in a dorm,
    commuters in their off-campus apartment) and return home at night."""
    dep_lo, dep_hi = behavior["depart_window_minutes"]
    ret_lo, ret_hi = behavior["return_window_minutes"]
    lunch_lo, lunch_hi = behavior["lunch_window"]
    dinner_lo, dinner_hi = behavior["dinner_window"]
    p_lunch = behavior["resident_lunch_probability"]
    p_dinner = behavior["resident_dinner_probability"]
    transit_rng = behavior["transit_minutes_gate"] if commuter else behavior["transit_minutes_dorm"]

    if commuter:
        home_id = rng.choice(pools["housing"])
        home_pt = random_point_in_polygon(BY_ID[home_id]["perimeter_polygon"], rng)
    else:
        if home_id is None:
            home_id = rng.choice(pools["dorm"])
        home_pt = random_point_in_polygon(BY_ID[home_id]["perimeter_polygon"], rng)

    # ── Classes per archetype pattern ──
    n = rng.randint(*arch["n_classes"])
    if arch["class_pattern"] == "morning":
        lo, hi = 480, 720          # 8:00–12:00
    elif arch["class_pattern"] == "afternoon":
        lo, hi = 720, 1020         # 12:00–17:00
    else:                          # spread
        lo, hi = 480, 1020
    lo = max(lo, dep_lo + 30)
    starts = sorted(rng.sample(range(lo, hi), min(n, hi - lo)))
    classes, last_end = [], 0
    for s in starts:
        s = max(s, last_end + 15)  # no overlaps
        d = rng.randint(*arch["class_duration_minutes"])
        classes.append((s, s + d, rng.choice(pools["class"])))
        last_end = s + d

    # ── Departure (resident leaves dorm / commuter arrives at gate) ──
    cap = (classes[0][0] - 5) if classes else dep_hi
    t_dep = int(rng.triangular(dep_lo, max(dep_lo + 20, min(dep_hi, cap)), dep_lo + 120))

    segments = []
    segments.append(seg("SLEEP", home_id, "point", home_pt, None, 0, t_dep))

    state = {"cursor": t_dep, "loc": home_pt, "last_b": home_id,
             "lunch": False, "dinner": False, "gym": False, "club": False}
    gym_go = rng.random() < behavior["gym_probability"]
    club_go = rng.random() < behavior["club_meeting_probability"]

    def go(state_name, b_id, length):
        """Transit (if the building changes) then hold at the building."""
        c = state["cursor"]
        d = rng.randint(*transit_rng)
        if b_id != state["last_b"]:
            dest = entrance_point(BY_ID[b_id], rng)
            if c + d >= DAY_MINUTES:
                return False
            wpts = router_route(state["loc"], state["last_b"], b_id, dest)
            segments.append(seg("TRANSIT", b_id, "transit", state["loc"], dest,
                                c, c + d, waypoints=wpts))
            c += d
            state["loc"] = dest
            state["last_b"] = b_id
        length = min(length, DAY_MINUTES - c)
        if length <= 0:
            return False
        segments.append(seg(state_name, b_id, "point", state["loc"], None, c, c + length))
        state["cursor"] = c + length
        return True

    def fill(until):
        """Fill [cursor, until) with study / social / gym / club / meals."""
        for _ in range(15):
            rem = until - state["cursor"]
            if rem < 20:
                break
            t = state["cursor"]
            acted = False
            if not commuter and rem >= 45:
                if (not state["lunch"] and lunch_lo <= t <= lunch_hi - 35
                        and rng.random() < p_lunch):
                    if go("EAT", rng.choice(pools["dining"]), rng.randint(30, 45)):
                        state["lunch"] = True
                    acted = True
                elif (not state["dinner"] and dinner_lo <= t <= dinner_hi - 35
                        and rng.random() < p_dinner):
                    if go("EAT", rng.choice(pools["dining"]), rng.randint(30, 45)):
                        state["dinner"] = True
                    acted = True
            if not acted and gym_go and not state["gym"] and rem >= 75 and t >= 420:
                if go("GYM", rng.choice(pools["gym"]), rng.randint(50, 75)):
                    state["gym"] = True
                acted = True
            if (not acted and club_go and not state["club"]
                    and t >= behavior["club_earliest_minutes"] and rem >= 70):
                if go("CLUB", rng.choice(pools["social"]), rng.randint(60, 120)):
                    state["club"] = True
                acted = True
            if not acted and rem >= 40:
                r = rng.random()
                if r < arch["study_preference"]:
                    go("STUDY", rng.choice(pools["study"]), min(rem - 5, rng.randint(45, 120)))
                elif r < arch["study_preference"] + arch["social_preference"]:
                    go("SOCIAL", rng.choice(pools["social"]), min(rem - 5, rng.randint(30, 90)))
                else:
                    break
                acted = True
            if not acted:
                break

    # ── Walk the day chronologically ──
    for cs, ce, cb in classes:
        fill(cs)
        if state["cursor"] < cs:  # small idle gap: short break where we are
            c = state["cursor"]
            segments.append(seg("BREAK", state["last_b"], "point", state["loc"], None, c, cs))
            state["cursor"] = cs
        if not go("CLASS", cb, ce - cs):
            break

    # ── Return window ──
    t_ret = int(rng.triangular(ret_lo, ret_hi, behavior["return_mode_minute"]))
    t_ret = max(t_ret, state["cursor"] + transit_rng[0])
    t_ret = min(t_ret, ret_hi)
    fill(min(t_ret, ret_hi - transit_rng[1]))

    # Hold position until the return window actually opens, so agents do not
    # bounce off campus right after arriving when fill() runs out of chunks.
    if state["cursor"] < t_ret:
        c = state["cursor"]
        segments.append(seg("BREAK", state["last_b"], "point", state["loc"], None, c, t_ret))
        state["cursor"] = t_ret

    # Leave for home (residents) or back out the same gate (commuters).
    d = rng.randint(*transit_rng)
    c = state["cursor"]
    wpts = router_route(state["loc"], state["last_b"], home_id, home_pt)
    segments.append(seg("TRANSIT", home_id, "transit", state["loc"], home_pt,
                        c, c + d, waypoints=wpts))
    if not commuter:
        segments.append(seg("SLEEP", home_id, "point", home_pt, None, c + d, DAY_MINUTES))

    return segments, home_id


# ── Simulation ──────────────────────────────────────────────────────────

def simulate(schedules, buildings_by_id, pools, _force_end=None, _rng=None):
    global BY_ID, ROUTER
    BY_ID = buildings_by_id

    all_buildings = list(buildings_by_id.values())
    ROUTER = Router(all_buildings)
    prewarm_router(ROUTER, all_buildings)

    sim = schedules["simulation"]
    behavior = schedules["behavior"]
    n_agents = sim["agents"]
    ping = sim["ping_interval_minutes"]
    commuter_share = behavior["commuter_share"]
    rng = _rng or random.Random(sim["seed"])

    # Decide commuter status for every agent up front, then assign homes to
    # exactly the residents. Least-filled dorm wins each pick, so all 21
    # dorms (incl. every Lakeshore hall) get students even at low agent counts.
    statuses = [rng.random() < commuter_share for _ in range(n_agents)]
    dorm_ids = list(pools["dorm"])
    housing_ids = list(pools["housing"])
    homes = {}
    counts = collections.Counter()
    hcounts = collections.Counter()
    for i, is_commuter in enumerate(statuses):
        if is_commuter:
            # Least-filled apartment wins each pick, so all housing
            # buildings get commuters even at low agent counts.
            home = min(housing_ids, key=lambda d: (hcounts[d], rng.random()))
            homes[i] = home
            hcounts[home] += 1
            continue
        home = min(dorm_ids, key=lambda d: (counts[d], rng.random()))
        homes[i] = home
        counts[home] += 1

    archetypes = {a["name"]: a for a in schedules["archetypes"]}
    names = [a["name"] for a in schedules["archetypes"]]
    weights = [a["weight"] for a in schedules["archetypes"]]

    agents = []
    for agent_id in range(n_agents):
        commuter = statuses[agent_id]
        arch = archetypes[rng.choices(names, weights=weights, k=1)[0]]
        segments, home = build_agent_day(
            arch, pools, behavior, rng, commuter,
            home_id=homes.get(agent_id),
        )
        agents.append({"id": agent_id, "segments": segments})

    global PING_JITTER_M
    PING_JITTER_M = float(sim.get("ping_jitter_meters", PING_JITTER_M))

    n_days = int(sim.get("days", 1))
    # End at 11:58pm LOCAL today; start n_days × 24h earlier. Timestamps are
    # written in local wall time (Z suffix kept for API compatibility).
    end = _force_end or datetime.now().replace(hour=23, minute=58, second=0,
                                               microsecond=0)
    rng = _rng or random.Random(sim["seed"])
    start = end - timedelta(days=n_days)
    rows, coord_rows = [], []
    t = 0
    total_min = DAY_MINUTES * n_days
    while t <= total_min:
        stamp = (start + timedelta(minutes=t)).strftime("%Y-%m-%dT%H:%M:%SZ")
        day_t = t % DAY_MINUTES
        for agent in agents:
            pos = locate(agent, day_t)
            if pos is None:
                continue  # commuter off campus
            state, target, lat, lng = pos
            lat, lng = jitter(rng, lat, lng)
            rows.append({
                "agent_id": agent["id"],
                "timestamp": stamp,
                "minute_of_day": t,
                "state": state,
                "building_id": target,
                "lat": f"{lat:.6f}",
                "lng": f"{lng:.6f}",
            })
            coord_rows.append({
                "lat": f"{lat:.6f}",
                "long": f"{lng:.6f}",
                "timestamp": stamp,
                "building": target,
            })
        t += ping
    return rows, coord_rows


def prewarm_router(router_obj, all_buildings, workers=None):
    """Precompute every door-to-door route in parallel (ProcessPoolExecutor,
    chunked) so simulate() only does cache lookups. The Mac's 4P+6E cores
cut the ~4-5 min single-core A* precompute to roughly a minute."""
    workers = workers or min(6, (os.cpu_count() or 4))
    if workers <= 1 or len(all_buildings) < 8:
        return
    pairs = [(a["id"], b["id"])
             for a in all_buildings for b in all_buildings if a["id"] < b["id"]]
    n_per = max(1, math.ceil(len(pairs) / workers))
    chunks = [pairs[i:i + n_per] for i in range(0, len(pairs), n_per)]
    t0 = time.time()
    with cf.ProcessPoolExecutor(max_workers=workers) as ex:
        futs = [ex.submit(_prewarm_chunk, ch) for ch in chunks]
        n = 0
        for f in cf.as_completed(futs):
            for (ka, kb), path in f.result().items():
                router_obj._path_cache[(ka, kb)] = path
                n += 1
    print(f"prewarmed {n} routes across {workers} workers "
          f"in {time.time() - t0:.1f}s")


def _prewarm_chunk(pairs):
    """Worker: build own Router, route chunk, return {(idA,idB): path|None}."""
    import json as _json
    here = os.path.dirname(os.path.abspath(__file__))
    with open(os.path.join(here, "configs", "buildings.json")) as f:
        bl = _json.load(f)["buildings"]
    r = Router(bl)
    out = {}
    for ka, kb in pairs:
        a = next(b for b in bl if b["id"] == ka)
        b = next(b for b in bl if b["id"] == kb)
        out[(ka, kb)] = r.route_buildings(a, b)
    return out


def router_route(loc, from_b, to_b, dest):
    """Waypoints for a transit segment: walkable route from loc through
    the origin building's door to the destination point. Falls back to a
    simple [start, dest] polyline if routing fails or either endpoint is
    not a building (e.g. a commuter gate)."""
    if ROUTER is None:
        return None
    def as_id(b):
        if b is None:
            return None
        return b if isinstance(b, str) else b.get("id")
    fid, tid = as_id(from_b), as_id(to_b)
    from_b = BY_ID.get(fid) if fid in BY_ID else None
    to_b = BY_ID.get(tid) if tid in BY_ID else None
    door0 = ROUTER.door_of(from_b) if from_b else None
    door1 = ROUTER.door_of(to_b) if to_b else None
    pts = [list(loc)]
    try:
        if door0 and door1:
            leg = ROUTER.route(door0, door1)
            if leg:
                pts.extend(leg[1:-1])  # door-to-door walk
            pts.append(list(dest))
        else:
            # Gate involved: route from loc (or its door) to dest directly
            start = door0 if door0 else loc
            leg = ROUTER.route(start, dest)
            if leg:
                pts.extend(leg[1:])
            else:
                pts.append(list(dest))
    except Exception:
        pts.append(list(dest))
    return pts


def polyline_position(wpts, f):
    """Position at fraction f (0..1) along a waypoint polyline, by length."""
    import math
    total = 0.0
    lens = []
    for a, b in zip(wpts, wpts[1:]):
        d = math.hypot((b[0] - a[0]), (b[1] - a[1]))
        lens.append(d)
        total += d
    if total < 1e-12:
        return wpts[0]
    target = f * total
    acc = 0.0
    for (a, b), d in zip(zip(wpts, wpts[1:]), lens):
        if acc + d >= target:
            t = (target - acc) / d if d > 0 else 0
            return [a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])]
        acc += d
    return wpts[-1]


def locate(agent, minute):
    for s in agent["segments"]:
        if s["start"] <= minute < s["end"]:
            if s["kind"] == "transit":
                f = (minute - s["start"]) / max(1, s["end"] - s["start"])
                if s.get("waypoints") and len(s["waypoints"]) >= 2:
                    lat, lng = polyline_position(s["waypoints"], f)
                    return s["state"], s["target"], lat, lng
                lat = s["lat0"] + f * (s["lat1"] - s["lat0"])
                lng = s["lng0"] + f * (s["lng1"] - s["lng0"])
                return s["state"], s["target"], lat, lng
            return s["state"], s["target"], s["lat0"], s["lng0"]
    return None


# ── Output ──────────────────────────────────────────────────────────────

def write_csv(rows, out_path, fieldnames=(
        "agent_id", "timestamp", "minute_of_day", "state",
        "building_id", "lat", "lng")):
    os.makedirs(os.path.dirname(out_path) or ".", exist_ok=True)
    with open(out_path, "w", newline="", encoding="utf-8") as f:
        writer = csv.DictWriter(f, fieldnames=fieldnames)
        writer.writeheader()
        writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description="Campus Pulse simulation generator")
    parser.add_argument("--agents", type=int, default=None, help="override agent count")
    parser.add_argument("--seed", type=int, default=None, help="override RNG seed")
    parser.add_argument("--out", type=str, default=None, help="override output CSV path")
    args = parser.parse_args()

    schedules, buildings_by_id, pools = load_configs()
    if args.agents is not None:
        schedules["simulation"]["agents"] = args.agents
    if args.seed is not None:
        schedules["simulation"]["seed"] = args.seed

    out = args.out or schedules["simulation"]["output"]
    out_coords = schedules["simulation"].get(
        "output_coords", "data/campus_simulation_coords.csv"
    )
    rows, coord_rows = simulate(schedules, buildings_by_id, pools)
    write_csv(rows, out)
    write_csv(coord_rows, out_coords, fieldnames=["lat", "long", "timestamp", "building"])
    print(f"Wrote {len(rows):,} pings for "
          f"{schedules['simulation']['agents']} agents → {out}")
    print(f"Wrote {len(coord_rows):,} coordinate rows → {out_coords}")

    # ── Bonus: a 1-day "future" apicalls slice, today 00:00 → 23:58. ──
    # Same deterministic day repeated at today's date; independent seed so
    # jitter/commute noise differs from the historical window.
    one_day = {k: v for k, v in schedules.items()}
    one_day["simulation"] = dict(schedules["simulation"], days=1)
    rng2 = random.Random(int(schedules["simulation"]["seed"]) + 1)
    rows2, coords2 = simulate(one_day, buildings_by_id, pools,
                              _force_end=datetime.now().replace(
                                  hour=23, minute=58, second=0, microsecond=0),
                              _rng=rng2)
    fut_path = os.path.join(os.path.dirname(out_coords) or ".",
                            "1_day_future_apicalls.csv")
    write_csv(coords2, fut_path,
              fieldnames=["lat", "long", "timestamp", "building"])
    print(f"Wrote {len(coords2):,} future-day rows → {fut_path}")


if __name__ == "__main__":
    main()
