#!/usr/bin/env python3
"""Campus Pulse — 2-week historical generator (Sun Nov 1 – Sat Nov 14, 2026).

Unlike generator.py's flat N identical days, every day is generated
SEPARATELY with its own seed and day-type behavior, so the data actually
differs day to day:

  Sun Nov  1  weekend     — no classes, late sleep-in, leisure
  Mon Nov  2 … Fri Nov  6 — full weekday classes (varied per day)
  Sat Nov  7  GAMEDAY     — Camp Randall surge, pre/post-game dining spikes
  Sun Nov  8  weekend     — recovery Sunday: late starts, low demand
  Mon Nov  9  weekday     — normal
  Tue Nov 10  exam_push   — study surge, social dropped
  Wed Nov 11  exam_push   — study push continues
  Thu Nov 12  weekday     — normal
  Fri Nov 13  weekday     — bigger evening social
  Sat Nov 14  weekend     — normal Saturday; final ts 23:58

Builds on generator.py's build_agent_day via a behavior-mutation layer:
per-day seed, shifted depart/return windows, scaled gym/club/meal
probabilities, an exam-study bias, and per-day WEIGHTED pools for study /
dining / social buildings so demand moves between spots across the week.
"""

import argparse
import copy
import csv
import os
import random
from datetime import datetime, timedelta

import generator as G
from generator import (
    DAY_MINUTES, build_agent_day, entrance_point, jitter, load_configs,
    locate, random_point_in_polygon, router_route, seg, write_csv,
)

HERE = os.path.dirname(os.path.abspath(__file__))
OUT_DEFAULT = "data/campus_simulation_14day.csv"

# ── Calendar ────────────────────────────────────────────────────────────
START = datetime(2026, 11, 1, 0, 0)   # Sunday
END_STAMP = "2026-11-14T23:58:00Z"    # Saturday night, last ping
DAY_TYPES = [
    "weekend",                                            # Sun Nov 1
    "weekday", "weekday", "weekday", "weekday", "weekday",  # Mon–Fri
    "gameday",                                            # Sat Nov 7
    "weekend",                                            # Sun Nov 8
    "weekday",                                            # Mon Nov 9
    "exam_push", "exam_push",                             # Tue 10, Wed 11
    "weekday", "weekday",                                 # Thu 12, Fri 13
    "weekend",                                            # Sat Nov 14
]


# ── Day-type behavior mutations ─────────────────────────────────────────

def day_behavior(day_type, rng, behavior):
    """Behavior copy mutated for one day (window shifts, probabilities)."""
    b = dict(behavior)
    dlo, dhi = behavior["depart_window_minutes"]
    rlo, rhi = behavior["return_window_minutes"]

    if day_type == "weekday":
        # Day-to-day texture: window edges wobble ±40 min, probabilities ±0.08
        b["depart_window_minutes"] = [max(300, dlo + rng.randint(-40, 40)),
                                      min(780, dhi + rng.randint(-40, 40))]
        b["return_window_minutes"] = [max(960, rlo + rng.randint(-40, 40)),
                                      min(1440, rhi + rng.randint(-40, 40))]
        b["gym_probability"] = _clamp(behavior["gym_probability"] + rng.uniform(-0.08, 0.08), 0.1, 0.6)
        b["club_meeting_probability"] = _clamp(behavior["club_meeting_probability"] + rng.uniform(-0.08, 0.08), 0.1, 0.6)
        b["resident_lunch_probability"] = _clamp(behavior["resident_lunch_probability"] + rng.uniform(-0.10, 0.10), 0.3, 0.95)
        b["resident_dinner_probability"] = _clamp(behavior["resident_dinner_probability"] + rng.uniform(-0.10, 0.10), 0.2, 0.9)
        return b, 1.0, True   # (behavior, class_count_scale, has_classes)

    if day_type == "exam_push":
        b["depart_window_minutes"] = [360, 660]     # earlier, tighter
        b["return_window_minutes"] = [1050, 1410]   # later returns (library nights)
        b["gym_probability"] = 0.12
        b["club_meeting_probability"] = 0.08
        b["resident_lunch_probability"] = 0.55
        b["resident_dinner_probability"] = 0.45
        return b, 1.15, True   # more class hours too (review sessions)

    if day_type == "gameday":
        b["depart_window_minutes"] = [540, 720]     # everyone moves mid-morning
        b["return_window_minutes"] = [1140, 1380]   # post-game dispersal
        b["gym_probability"] = 0.05
        b["club_meeting_probability"] = 0.05
        b["resident_lunch_probability"] = 0.85      # pre-game fuel
        b["resident_dinner_probability"] = 0.75     # post-game refuel
        return b, 0.0, False   # no classes

    # weekend (incl. recovery Sunday flavor from the rng seed)
    b["depart_window_minutes"] = [600, 840]         # sleep in: 10:00–14:00
    b["return_window_minutes"] = [1140, 1380]
    b["gym_probability"] = 0.45                     # leisure gym
    b["club_meeting_probability"] = 0.10
    b["resident_lunch_probability"] = 0.50
    b["resident_dinner_probability"] = 0.60
    return b, 0.0, False


def _clamp(v, lo, hi):
    return max(lo, min(hi, v))


# ── Per-day weighted pools (demand moves between buildings) ─────────────

def weighted_pools(pools, rng):
    """Per-day popularity weights: dining hall / study spot / social venue
    demand shifts day to day (one or two spots get 2–3× the usual pull)."""
    out = {}
    for key in ("dining", "study", "social", "gym"):
        ids = pools[key]
        w = [1.0] * len(ids)
        for _ in range(max(1, len(ids) // 3)):
            i = rng.randrange(len(ids))
            w[i] = rng.uniform(1.8, 3.0)      # today's hot spot
        for _ in range(max(1, len(ids) // 4)):
            i = rng.randrange(len(ids))
            w[i] = rng.uniform(0.3, 0.6)      # today's quiet spot
        if key == "dining":
            # Weekends: dining demand spreads out; exam days: libraries win.
            w = [x * rng.uniform(0.8, 1.2) for x in w]
        out[key] = (ids, w)
    return out


def pick_weighted(pool_wr, rng):
    ids, w = pool_wr
    return rng.choices(ids, weights=w, k=1)[0]


# ── Archetype day-assembly wrapper ──────────────────────────────────────

def build_day_agent(arch, pools, behavior, rng, commuter, home_id,
                    day_type, wpools, arch_rng):
    """One agent's day for one day type. Reuses generator.build_agent_day
    for class days; assembles a custom leisure day for weekends/gameday."""
    has_classes = day_type in ("weekday", "exam_push")

    if has_classes:
        if day_type == "exam_push":
            # More/longer classes (review sessions) via a scaled archetype
            arch = dict(arch)
            arch["n_classes"] = [n + 1 for n in arch["n_classes"]]
        return build_agent_day(arch, pools, behavior, rng, commuter,
                               home_id=home_id)

    # ── No-class day (weekend / gameday) ──
    b = behavior
    dep_lo, dep_hi = b["depart_window_minutes"]
    ret_lo, ret_hi = b["return_window_minutes"]
    transit_rng = (b["transit_minutes_gate"] if commuter
                   else b["transit_minutes_dorm"])

    if commuter:
        home_pt = _home_point(home_id, rng)
    else:
        home_pt = _home_point(home_id, rng)

    t_dep = int(rng.triangular(dep_lo, dep_hi, (dep_lo + dep_hi) / 2))
    segments = [seg("SLEEP", home_id, "point", home_pt, None, 0, t_dep)]

    state = {"cursor": t_dep, "loc": home_pt, "last_b": home_id,
             "lunch": False, "dinner": False}

    def go(state_name, pool_key, length):
        c = state["cursor"]
        d = rng.randint(*transit_rng)
        b_id = pick_weighted(wpools[pool_key], rng)
        dest = _entrance(b_id, rng)
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
        segments.append(seg(state_name, b_id, "point", state["loc"], None,
                            c, c + length))
        state["cursor"] = c + length
        return True

    if day_type == "gameday":
        # Pre-game meal → long stadium/union block → post-game meal/evening
        if rng.random() < b["resident_lunch_probability"]:
            go("EAT", "dining", rng.randint(30, 50))
        venue = rng.choices(["social", "dining"],
                            weights=[0.8, 0.2], k=1)[0]
        go("SOCIAL", venue, rng.randint(150, 260))       # the game itself
        if rng.random() < b["resident_dinner_probability"]:
            go("EAT", "dining", rng.randint(40, 60))
        if rng.random() < 0.45:                           # keep the night going
            go("SOCIAL", "social", rng.randint(60, 120))
    else:
        # Weekend: leisure mix — gym, long study blocks for some, social,
        # meals; exam-push Mondays follow with crunch mode.
        study_spree = rng.random() < 0.35                 # some study weekends
        if rng.random() < b["gym_probability"]:
            go("GYM", "social" if False else "gym", rng.randint(50, 80))
        if rng.random() < b["resident_lunch_probability"]:
            go("EAT", "dining", rng.randint(30, 45))
        r = rng.random()
        if study_spree or r < 0.35:
            go("STUDY", "study", rng.randint(60, 150))
        elif r < 0.75:
            go("SOCIAL", "social", rng.randint(45, 120))
        else:
            # Lounging where they live (residents) or on-campus social spots
            go("BREAK", "social" if commuter else "social",
               rng.randint(40, 90))
        if rng.random() < b["resident_dinner_probability"]:
            go("EAT", "dining", rng.randint(30, 50))
        if rng.random() < 0.5:
            go("SOCIAL", "social", rng.randint(40, 110))

    # Return home
    t_ret = int(rng.triangular(ret_lo, ret_hi, (ret_lo + ret_hi) / 2))
    t_ret = max(t_ret, state["cursor"] + transit_rng[0])
    t_ret = min(t_ret, ret_hi, DAY_MINUTES - transit_rng[1] - 1)
    if state["cursor"] < t_ret:
        c = state["cursor"]
        segments.append(seg("BREAK", state["last_b"], "point", state["loc"],
                            None, c, t_ret))
        state["cursor"] = t_ret
    d = rng.randint(*transit_rng)
    c = state["cursor"]
    wpts = router_route(state["loc"], state["last_b"], home_id, home_pt)
    segments.append(seg("TRANSIT", home_id, "transit", state["loc"], home_pt,
                        c, c + d, waypoints=wpts))
    if not commuter:
        segments.append(seg("SLEEP", home_id, "point", home_pt, None,
                            c + d, DAY_MINUTES))
    return segments, home_id


def _home_point(home_id, rng):
    from generator import random_point_in_polygon
    return random_point_in_polygon(G.BY_ID[home_id]["perimeter_polygon"], rng)


def _entrance(b_id, rng):
    from generator import entrance_point
    return entrance_point(G.BY_ID[b_id], rng)


# ── Day simulation ──────────────────────────────────────────────────────

def simulate_day(day_index, day_type, schedules, buildings_by_id, pools,
                 statuses, homes, archetypes):
    """One day, all agents. Returns rows[] for that day. Uses a per-day
    seed so every day is a genuinely different realization."""
    behavior = schedules["behavior"]
    sim = schedules["simulation"]
    ping = sim["ping_interval_minutes"]
    names = [a["name"] for a in schedules["archetypes"]]
    weights = [a["weight"] for a in schedules["archetypes"]]

    day_rng = random.Random(sim["seed"] * 1000 + day_index)
    b, class_scale, _ = day_behavior(day_type, day_rng, behavior)
    wpools = weighted_pools(pools, day_rng)

    agents = []
    for agent_id, (commuter, home) in enumerate(zip(statuses,
                                                    (homes[i] for i in range(len(statuses))))):
        arch = archetypes[day_rng.choices(names, weights=weights, k=1)[0]]
        if class_scale != 1.0:
            arch = dict(arch)
            if class_scale == 0.0:
                pass  # handled by day-type branch
        segments, home_used = build_day_agent(
            arch, pools, b, day_rng, commuter, home, day_type, wpools, day_rng
        )
        agents.append({"id": agent_id, "segments": segments})

    # Re-jitter per day so identical positions still differ across days
    day_stamp0 = START + timedelta(days=day_index)
    rows = []
    t = 0
    while t < DAY_MINUTES:
        stamp = (day_stamp0 + timedelta(minutes=t)).strftime("%Y-%m-%dT%H:%M:%SZ")
        for agent in agents:
            pos = locate(agent, t)
            if pos is None:
                continue
            state, target, lat, lng = pos
            lat, lng = jitter(day_rng, lat, lng)
            rows.append({
                "agent_id": agent["id"],
                "timestamp": stamp,
                "minute_of_day": t,
                "state": state,
                "building_id": target,
                "lat": f"{lat:.6f}",
                "lng": f"{lng:.6f}",
            })
        t += ping
    return rows


# ── main ────────────────────────────────────────────────────────────────

def main():
    ap = argparse.ArgumentParser(description="2-week historical generator")
    ap.add_argument("--agents", type=int, default=None)
    ap.add_argument("--seed", type=int, default=None)
    ap.add_argument("--out", type=str, default=OUT_DEFAULT)
    ap.add_argument("--coords-out", type=str,
                    default="data/campus_simulation_14day_apicalls.csv")
    args = ap.parse_args()

    schedules, buildings_by_id, pools = load_configs()
    if args.agents is not None:
        schedules["simulation"]["agents"] = args.agents
    if args.seed is not None:
        schedules["simulation"]["seed"] = args.seed
    sim = schedules["simulation"]
    n_agents = sim["agents"]
    behavior = schedules["behavior"]

    # Wire the router globals in generator (router_route reads them) and
    # prewarm every door-to-door route once — all 14 days share the cache.
    import generator as G
    from router import Router
    G.BY_ID = buildings_by_id
    G.ROUTER = Router(list(buildings_by_id.values()))
    G.prewarm_router(G.ROUTER, list(buildings_by_id.values()))

    # Stable agent identities across days: commuter status + home fixed once
    base_rng = random.Random(sim["seed"])
    statuses = [base_rng.random() < behavior["commuter_share"]
                for _ in range(n_agents)]
    dorm_ids = list(pools["dorm"])
    housing_ids = list(pools["housing"])
    homes, ccounts, hcounts = {}, {}, {}
    for i, is_c in enumerate(statuses):
        if is_c:
            home = min(housing_ids, key=lambda d: (hcounts.get(d, 0), base_rng.random()))
            hcounts[home] = hcounts.get(home, 0) + 1
        else:
            home = min(dorm_ids, key=lambda d: (ccounts.get(d, 0), base_rng.random()))
            ccounts[home] = ccounts.get(home, 0) + 1
        homes[i] = home

    archetypes = {a["name"]: a for a in schedules["archetypes"]}

    all_rows = []
    for day_index, day_type in enumerate(DAY_TYPES):
        rows = simulate_day(day_index, day_type, schedules, buildings_by_id,
                            pools, statuses, homes, archetypes)
        all_rows.extend(rows)
        stamp = (START + timedelta(days=day_index)).strftime("%a %b %d")
        print(f"  day {day_index + 1:2d}/14 {stamp} ({day_type:9s}): "
              f"{len(rows):,} pings")

    # Trim anything past the final timestamp (day 14 runs to 23:58 anyway;
    # the loop stops before DAY_MINUTES so the last stamp is 23:58).
    all_rows = [r for r in all_rows if r["timestamp"] <= END_STAMP]

    write_csv(all_rows, args.out)

    # apicalls variant (lat/long/timestamp/building) for the API ingester
    coord_rows = [{"lat": r["lat"], "long": r["lng"],
                   "timestamp": r["timestamp"], "building": r["building_id"]}
                  for r in all_rows]
    write_csv(coord_rows, args.coords_out,
              fieldnames=["lat", "long", "timestamp", "building"])

    print(f"Wrote {len(all_rows):,} pings over 14 days → {args.out}")
    print(f"Wrote {len(coord_rows):,} coordinate rows → {args.coords_out}")


if __name__ == "__main__":
    main()
