#!/usr/bin/env python3
"""Campus Pulse — student movement simulation generator (v2).

Population model:
- Residents (1 - commuter_share) live in a dorm, sleep on campus, may eat
  at dining halls.
- Commuters (commuter_share, default 60%) appear at a campus-edge gate
  (chosen from `commuter_gates`) in the morning (6:00-12:00), spend the
  day on campus, and leave from the SAME gate in the evening (17:00-23:00).
  They never generate dining-hall visits.

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
import csv
import json
import os
import random
from datetime import datetime, timedelta, timezone

from router import Router

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


def jitter(rng, lat, lng, amt=8e-5):
    return lat + rng.uniform(-amt, amt), lng + rng.uniform(-amt, amt)


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
    for needed in ("class", "study", "dining", "social", "gym", "dorm"):
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


def build_agent_day(arch, pools, behavior, gates, rng, commuter, home_id=None):
    """Return (segments, home_id). Segments are chronological; commuters
    have segments only between arrival at and departure from their gate."""
    dep_lo, dep_hi = behavior["depart_window_minutes"]
    ret_lo, ret_hi = behavior["return_window_minutes"]
    lunch_lo, lunch_hi = behavior["lunch_window"]
    dinner_lo, dinner_hi = behavior["dinner_window"]
    p_lunch = behavior["resident_lunch_probability"]
    p_dinner = behavior["resident_dinner_probability"]
    transit_rng = behavior["transit_minutes_gate"] if commuter else behavior["transit_minutes_dorm"]

    if commuter:
        gate = rng.choice(gates)
        home_id, home_pt = gate["id"], (gate["lat"], gate["lng"])
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
    if not commuter:
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
            dest = random_point_in_polygon(BY_ID[b_id]["perimeter_polygon"], rng)
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

def simulate(schedules, buildings_by_id, pools):
    global BY_ID, ROUTER
    BY_ID = buildings_by_id

    all_buildings = list(buildings_by_id.values())
    ROUTER = Router(all_buildings)

    sim = schedules["simulation"]
    behavior = schedules["behavior"]
    gates = schedules["commuter_gates"]
    n_agents = sim["agents"]
    ping = sim["ping_interval_minutes"]
    commuter_share = behavior["commuter_share"]
    rng = random.Random(sim["seed"])

    # Decide commuter status for every agent up front, then assign homes to
    # exactly the residents. Least-filled dorm wins each pick, so all 21
    # dorms (incl. every Lakeshore hall) get students even at low agent counts.
    statuses = [rng.random() < commuter_share for _ in range(n_agents)]
    dorm_ids = list(pools["dorm"])
    homes = {}
    counts = collections.Counter()
    for i, is_commuter in enumerate(statuses):
        if is_commuter:
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
            arch, pools, behavior, gates, rng, commuter,
            home_id=homes.get(agent_id),
        )
        agents.append({"id": agent_id, "segments": segments})

    sim_day = datetime(2026, 1, 1, tzinfo=timezone.utc)  # fixed sim day, UTC
    rows, coord_rows = [], []
    t = 0
    while t < DAY_MINUTES:
        stamp = (sim_day + timedelta(minutes=t)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for agent in agents:
            pos = locate(agent, t)
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
            })
        t += ping
    return rows, coord_rows


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
    write_csv(coord_rows, out_coords, fieldnames=["lat", "long", "timestamp"])
    print(f"Wrote {len(rows):,} pings for "
          f"{schedules['simulation']['agents']} agents → {out}")
    print(f"Wrote {len(coord_rows):,} coordinate rows → {out_coords}")


if __name__ == "__main__":
    main()
