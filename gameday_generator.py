#!/usr/bin/env python3
"""Campus Pulse — GAME-DAY WEEKEND simulation generator.

Produces a Friday / Saturday(game day) / Sunday dataset (apicalls format)
with a football crowd modeled at Camp Randall:

- Friday:   normal class day, but evening socializing is amplified and
            runs late (students stay out longer; State St / unions draw).
- Saturday: classes virtually none; kickoff 6:30pm. Agents in the
            attendee pool converge on Camp Randall between gates-open
            (4:00pm) and gate-close (9:00pm kickoff+30). Tailgaters drift
            through Memorial Union / Union South beforehand. After the
            (rng-drawn) WIN/LOSS, 60% of attendees / 15% after a loss
            spill into a CELEBRATE (or dejected dispersal) at the unions
            and Kohl Center before winding home; non-attendees stay on a
            quieter study/brunch rhythm.
- Sunday:   late starts, brunch spike, heavy library time, early home
            return — the campus winds down.

Schema: same lat,long,timestamp,device_id apicalls shape as the main sim,
plus a gameday_schedules.json "gameday" block for all parameters.

Usage:
    python gameday_generator.py
    python gameday_generator.py --agents 300 --seed 7
"""

import argparse
import collections
import heapq
import json
import os
import random
from datetime import datetime, timedelta

from generator import (DAY_MINUTES, jitter, locate, prewarm_router,
                       point_in_polygon, polyline_position, random_point_in_polygon,
                       write_csv)
from router import Router

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEDULES_PATH = os.path.join(HERE, "configs", "gameday_schedules.json")


PING_JITTER = 2.0  # imported real value from generator; module-level BY_ID set in simulate_gameday
BY_ID = {}
ROUTER = None


def seg(state, target, kind, p0, p1, start, end, waypoints=None):
    return {
        "state": state, "target": target, "kind": kind,
        "lat0": p0[0], "lng0": p0[1],
        "lat1": p1[0] if p1 else None, "lng1": p1[1] if p1 else None,
        "start": start, "end": end, "waypoints": waypoints,
    }


def go_to(segments, st, b_id, dest):
    """Append a transit segment to building b_id; update st. Returns end."""
    d = st["transit"]()
    if b_id != st["last_b"]:
        if st["cursor"] + d >= DAY_MINUTES:
            return st["cursor"]
        wpts = _route(st["loc"], st["last_b"], b_id, dest)
        segments.append(seg("TRANSIT", b_id, "transit", st["loc"], dest,
                            st["cursor"], st["cursor"] + d, waypoints=wpts))
        st["cursor"] += d
        st["loc"] = dest
        st["last_b"] = b_id
    return st["cursor"]


def hold(segments, st, state_name, b_id, length):
    c = st["cursor"]
    length = max(0, min(length, DAY_MINUTES - c))
    if length > 0:
        segments.append(seg(state_name, b_id, "point", st["loc"], None, c, c + length))
        st["cursor"] += length


def hold_at(segments, st, state_name, b_id, pt, length):
    """Hold at an explicit point (e.g. a stadium stand position)."""
    c = st["cursor"]
    length = max(0, min(length, DAY_MINUTES - c))
    if length > 0:
        segments.append(seg(state_name, b_id, "point", pt, None, c, c + length))
        st["cursor"] += length


def _route(loc, from_b, to_b, dest):
    from generator import router_route
    import gameday_generator as _self
    pts = router_route(loc, from_b, to_b, dest)
    if not pts or len(pts) < 2:
        pts = [list(loc), list(dest)]
    checker = getattr(_self, "CHECKER", None)
    if checker is None:
        return pts
    opoly = _self.BY_ID[from_b]["perimeter_polygon"] if from_b in _self.BY_ID else None
    dpoly = _self.BY_ID[to_b]["perimeter_polygon"] if to_b in _self.BY_ID else None
    return checker.repair(pts, opoly, dpoly)


# ── Day assembly ────────────────────────────────────────────────────────

def fill_daylight(st, segments, arch, pools, behavior, rng, boost=0.0):
    """Study/social filler (shared by all three days)."""
    study_pref = min(0.95, arch["study_preference"] + boost)
    social_pref = arch["social_preference"]
    while st["cursor"] < st["until"] - 25:
        rem = st["until"] - st["cursor"]
        r = rng.random()
        if r < study_pref:
            b = rng.choice(pools["study"])
            go_to(segments, st, b, _entrance(b, rng))
            hold(segments, st, "STUDY", st["last_b"],
                 min(rem - 5, rng.randint(45, 120)))
        elif r < study_pref + social_pref:
            b = rng.choice(pools["social"])
            go_to(segments, st, b, _entrance(b, rng))
            hold(segments, st, "SOCIAL", st["last_b"],
                 min(rem - 5, rng.randint(30, 90)))
        else:
            break


def meals(st, segments, pools, rng, windows):
    """Simple EAT insert: windows = [(lo, hi), ...] minutes."""
    for lo, hi in windows:
        if lo <= st["cursor"] <= hi - 30:
            go_to(segments, st, (b := rng.choice(pools["dining"])),
                  _entrance(b, rng))
            hold(segments, st, "EAT", st["last_b"], rng.randint(30, 50))
            return


def _entrance(b_id, rng):
    from generator import entrance_point
    import gameday_generator as _self
    return entrance_point(_self.BY_ID[b_id], rng)


def build_normal_day(arch, pools, behavior, rng, commuter, home_id,
                     home_pt, depart, ret, study_boost=0.0,
                     social_boost=0.0, evening_extra=None, gd=None):
    """Generic class-day: optionally stretched evening (Friday)."""
    st = {"cursor": depart, "loc": home_pt, "last_b": home_id,
          "transit": lambda: rng.randint(*behavior["transit_minutes_gate" if commuter
                                          else "transit_minutes_dorm"]),
          "until": 0}
    segments = [seg("SLEEP", home_id, "point", home_pt, None, 0, depart)]

    # Sparse classes (game-day weekend: much lighter than a weekday)
    n = max(0, rng.randint(*arch["n_classes"]) - rng.choice([0, 0, 1]))
    lo, hi = 480, 1020
    starts = sorted(rng.sample(range(lo, hi), min(n, hi - lo))) if n else []
    last_end = 0
    for s in starts:
        s = max(s, last_end + 15)
        d = rng.randint(*arch["class_duration_minutes"])
        if go_to(segments, st, (b := rng.choice(pools["class"])),
                 _entrance(b, rng)) is None:
            break
        hold(segments, st, "CLASS", st["last_b"], d)
        last_end = s + d

    meals(st, segments, pools, rng, [(690, 840), (1020, 1140)])
    st["until"] = ret
    fill_daylight(st, segments, arch, pools, behavior, rng,
                  boost=study_boost + social_boost * 0.3)

    if evening_extra:  # Friday night: house parties + union socializing
        lo, hi = evening_extra
        if st["cursor"] < lo:
            hold(segments, st, "BREAK", st["last_b"], lo - st["cursor"])
        oc = gd.get("off_campus") if gd else None
        share = (oc["friday_party_share_comm"] if commuter
                 else oc["friday_party_share_dorm"]) if oc else 0.0
        r = rng.random()
        if r < share:
            pb = rng.choice(pools["housing"])
            go_to(segments, st, pb, _entrance(pb, rng))
            hold(segments, st, "PARTY", pb,
                 rng.randint(*oc["friday_party_duration_minutes"]))
        elif r < share + 0.45 + social_boost:
            go_to(segments, st, (b := rng.choice(pools["social"])),
                  _entrance(b, rng))
            hold(segments, st, "SOCIAL", st["last_b"],
                 rng.randint(*[max(30, hi - st["cursor"]), max(60, hi - st["cursor"])]))

    # Head home
    go_to(segments, st, home_id, home_pt)
    if not commuter:
        segments.append(seg("SLEEP", home_id, "point", home_pt, None,
                            st["cursor"], DAY_MINUTES))
    return segments, home_id


def build_gameday(arch, pools, behavior, gd, rng, commuter, home_id, home_pt,
                  attends, home_wins):
    """Saturday: tailgate → Camp Randall → celebrate/disperse → home."""
    kickoff = gd["kickoff_minute"]
    gate_open, gate_close = gd["gate_open_minute"], gd["gate_close_minute"]
    stadium = gd["stadium"]
    st = {"cursor": 0, "loc": home_pt, "last_b": home_id,
          "transit": lambda: rng.randint(*behavior["transit_minutes_gate" if commuter
                                          else "transit_minutes_dorm"]),
          "until": 0}
    segments = []

    if attends:
        depart = int(rng.triangular(540, gate_open - 60, 660))
        segments.append(seg("SLEEP", home_id, "point", home_pt, None, 0, depart))
        st["cursor"] = depart
        oc = gd["off_campus"]

        # Pre-game 1: ~60% drift through a tailgate spot for 45-120 min
        if rng.random() < 0.6:
            tspot = rng.choice(gd["tailgate_social"])
            go_to(segments, st, tspot, _entrance(tspot, rng))
            hold(segments, st, "TAILGATE", tspot, rng.randint(45, 120))

        # Pre-game 2: house parties at off-campus housing (commuters host /
        # attend at their own places; dorm residents cross over to Langdon
        # St. et al. at a lower rate). Starts no earlier than
        # preshow_party_start_minute.
        pshare = (oc["saturday_party_share_comm"] if commuter
                  else oc["saturday_party_share_dorm"])
        p_start = oc["preshow_party_start_minute"]
        if rng.random() < pshare:
            if st["cursor"] < p_start:
                hold(segments, st, "BREAK", st["last_b"], p_start - st["cursor"])
            pb = rng.choice(pools["housing"])
            go_to(segments, st, pb, _entrance(pb, rng))
            hold(segments, st, "PARTY", pb,
                 rng.randint(*oc["preshow_party_duration_minutes"]))

        # Converge on the stadium between gate-open and gate-close
        arrive = int(rng.triangular(gate_open, gate_close, kickoff - 45))
        if st["cursor"] < arrive - 10:
            hold(segments, st, "BREAK", st["last_b"], arrive - st["cursor"])
        gate = _entrance(stadium, rng)  # same gate in and out (no teleport)
        go_to(segments, st, stadium, gate)
        hold(segments, st, "WATCH", stadium, kickoff + rng.randint(5, 40) - st["cursor"])
        hold_at(segments, st, "WATCH", stadium,
                gate, rng.randint(180, 220))  # ~3h+ game

        # Result spill: big crowd after a win, thin dejected dispersal after
        # a loss — plus house-party spillover at off-campus housing.
        cel = gd["celebration"]
        cel_share = cel["attend_share_win"] if home_wins else cel["attend_share_loss"]
        if rng.random() < cel_share:
            c_lo, c_hi = cel["windows"][0]
            start = int(rng.triangular(c_lo, c_hi, c_lo + 20))
            if st["cursor"] < start:
                hold(segments, st, "BREAK", st["last_b"], start - st["cursor"])
            cel_b = rng.choice(cel["buildings"])
            go_to(segments, st, cel_b, _entrance(cel_b, rng))
            hold(segments, st, cel["state_name"] if home_wins else "DEJECT",
                 st["last_b"], rng.randint(*cel["duration_minutes"]))
            # Win celebration rolls on at a house party
            if home_wins and rng.random() < oc["post_win_party_share"]:
                pb = rng.choice(pools["housing"])
                go_to(segments, st, pb, _entrance(pb, rng))
                hold(segments, st, "PARTY", pb,
                     rng.randint(*oc["post_party_minutes"]))
        elif rng.random() < (oc["post_loss_party_share"] if not home_wins
                             else oc["post_win_party_share"]):
            pb = rng.choice(pools["housing"])
            go_to(segments, st, pb, _entrance(pb, rng))
            hold(segments, st, "PARTY", pb,
                 rng.randint(*oc["post_party_minutes"]))
    else:
        # Non-attendee Saturday: quiet study/brunch rhythm, maybe a walk by
        # the stadium out of curiosity, home early-ish.
        nd = gd["non_attendee_day"]
        depart = int(rng.triangular(*nd["depart_window_minutes"]))
        segments.append(seg("SLEEP", home_id, "point", home_pt, None, 0, depart))
        st["cursor"] = depart
        if rng.random() < gd["sunday"]["brunch_probability"] * 0.7:
            meals(st, segments, pools, rng, [gd["sunday"]["brunch_window"]])
        st["until"] = int(rng.triangular(*nd["return_window_minutes"]))
        fill_daylight(st, segments, arch, pools, behavior, rng,
                      boost=nd["study_preference_boost"])

    # Wind-down: everyone heads home; attendees drift back late, others early
    if st["cursor"] < DAY_MINUTES - 40:
        go_to(segments, st, home_id, home_pt)
    if not commuter and st["cursor"] < DAY_MINUTES:
        segments.append(seg("SLEEP", home_id, "point", home_pt, None,
                            st["cursor"], DAY_MINUTES))
    return segments, home_id


def build_sunday(arch, pools, behavior, gd, rng, commuter, home_id, home_pt):
    """Sunday: late start, brunch, heavy study, early home."""
    sd = gd["sunday"]
    depart = int(rng.triangular(*sd["depart_window_minutes"]))
    st = {"cursor": depart, "loc": home_pt, "last_b": home_id,
          "transit": lambda: rng.randint(*behavior["transit_minutes_gate" if commuter
                                          else "transit_minutes_dorm"]),
          "until": 0}
    segments = [seg("SLEEP", home_id, "point", home_pt, None, 0, depart)]

    if rng.random() < sd["brunch_probability"]:
        oc = gd.get("off_campus")
        if oc and rng.random() < oc["sunday_recovery_share"]:
            # Sleep-in recovery at home instead of a dining-hall brunch
            hold(segments, st, "RECOVER", home_id,
                 rng.randint(*oc["sunday_recovery_minutes"]))
        else:
            meals(st, segments, pools, rng, [sd["brunch_window"]])

    st["until"] = int(rng.triangular(*sd["return_window_minutes"]))
    fill_daylight(st, segments, arch, pools, behavior, rng,
                  boost=sd["study_preference_boost"])

    go_to(segments, st, home_id, home_pt)
    if not commuter and st["cursor"] < DAY_MINUTES:
        segments.append(seg("SLEEP", home_id, "point", home_pt, None,
                            st["cursor"], DAY_MINUTES))
    return segments, home_id


# ── Simulation ──────────────────────────────────────────────────────────

def simulate_gameday(schedules, buildings_by_id, pools, _end_day=None, _rng=None):
    # NOTE: when run as a script this file's globals live in __main__, while
    # helpers do `import gameday_generator` (a second module object). Set the
    # attribute on the imported module so _entrance/_route see the real map.
    from path_compliance import PathChecker, dist_m as _pc_dist_m
    globals()["dist_m"] = _pc_dist_m
    import gameday_generator as _self_mod
    import generator as G
    _self_mod.BY_ID = buildings_by_id
    G.BY_ID = buildings_by_id
    all_buildings = list(buildings_by_id.values())
    ROUTER = Router(all_buildings)
    G.ROUTER = ROUTER
    _self_mod.ROUTER = ROUTER
    _self_mod.CHECKER = PathChecker(ROUTER, buildings_by_id)
    prewarm_router(ROUTER, all_buildings)

    sim = schedules["simulation"]
    behavior = schedules["behavior"]
    gd = schedules["gameday"]
    n_agents = sim["agents"]
    rng = _rng or random.Random(sim["seed"])

    commuter_share = behavior["commuter_share"]
    statuses = [rng.random() < commuter_share for _ in range(n_agents)]
    homes, counts, hcounts = {}, collections.Counter(), collections.Counter()
    for i, is_c in enumerate(statuses):
        pool = list(pools["housing"]) if is_c else list(pools["dorm"])
        cnt = hcounts if is_c else counts
        home = min(pool, key=lambda d: (cnt[d], rng.random()))
        homes[i] = home
        cnt[home] += 1

    archetypes = {a["name"]: a for a in schedules["archetypes"]}
    names = [a["name"] for a in schedules["archetypes"]]
    weights = [a["weight"] for a in schedules["archetypes"]]

    home_wins = rng.random() < gd["celebration"]["win_probability"]
    print(f"game result: {'WIN' if home_wins else 'LOSS'} "
          f"(kickoff {gd['kickoff_minute']//60}:{gd['kickoff_minute']%60:02d})")

    # Three day-plans per agent: Friday, Saturday, Sunday
    days = []
    for agent_id in range(n_agents):
        commuter = statuses[agent_id]
        arch = archetypes[rng.choices(names, weights=weights, k=1)[0]]
        home_id = homes[agent_id]
        home_pt = random_point_in_polygon(_self_mod.BY_ID[home_id]["perimeter_polygon"], rng)

        # ── Friday ──
        fr = gd["friday"]
        d1, _ = build_normal_day(
            arch, pools, behavior, rng, commuter, home_id, home_pt,
            depart=int(rng.triangular(*behavior["depart_window_minutes"])),
            ret=int(rng.triangular(*fr["return_window_minutes"])),
            social_boost=fr["social_preference_boost"],
            evening_extra=fr["evening_social_bonus_minutes"],
            gd=gd,
        )
        # ── Saturday ──
        attends = rng.random() < gd["attendee_share"]
        d2, _ = build_gameday(arch, pools, behavior, gd, rng, commuter,
                              home_id, home_pt, attends, home_wins)
        # ── Sunday ──
        d3, _ = build_sunday(arch, pools, behavior, gd, rng, commuter,
                             home_id, home_pt)
        days.append([d1, d2, d3])

    import generator as G
    G.PING_JITTER_M = float(sim.get("ping_jitter_meters", 2.0))

    ping = sim["ping_interval_minutes"]
    # Route waypoints double as movement pings: emitting one ping at each
    # validated polyline corner keeps rendered ping-to-ping chords on the
    # route (sparse 2-min pings alone would cut corners across buildings).
    # Corner pings get state/target/minute aligned to the interval that
    # contains them, with 1s timestamps to keep rows ordered.
    corner_rows = []  # (t_float, agent_idx, state, target, lat, lng)
    for i, agent in enumerate(days):
        for day_idx in range(3):
            base = day_idx * DAY_MINUTES
            for s in agent[day_idx]:
                if s["kind"] != "transit" or not s.get("waypoints") \
                        or len(s["waypoints"]) < 3:
                    continue
                wpts = s["waypoints"]
                total = sum(dist_m(wpts[k], wpts[k + 1])
                            for k in range(len(wpts) - 1))
                if total < 1e-9:
                    continue
                acc = 0.0
                for k in range(1, len(wpts) - 1):  # interior corners only
                    acc += dist_m(wpts[k - 1], wpts[k])
                    frac = acc / total
                    ct = base + s["start"] + frac * (s["end"] - s["start"])
                    corner_rows.append((i, ct, s["state"], s["target"],
                                        wpts[k][0], wpts[k][1]))
    corner_rows.sort(key=lambda x: (x[1], x[0]))
    corner_q = [(ct, ci) for ci, ct, *_ in corner_rows]
    heapq.heapify(corner_q)
    corner_by_key = {}
    for ci, ct, state, target, lat, lng in corner_rows:
        corner_by_key[(ct, ci)] = (state, target, lat, lng)
    end = _end_day or datetime.now().replace(hour=23, minute=58, second=0,
                                             microsecond=0)
    # Anchor: end_day = Sunday 23:58 → Friday 00:00 start
    start = (end - timedelta(days=2)).replace(hour=0, minute=0)
    rows = []
    history_rows = []
    t = 0
    total = DAY_MINUTES * 3
    while t < total:  # t==total would be Monday 00:00 (day_idx 3)
        stamp = (start + timedelta(minutes=t)).strftime("%Y-%m-%dT%H:%M:%SZ")
        day_idx = t // DAY_MINUTES
        day_t = t % DAY_MINUTES
        for i, agent in enumerate(days):
            pos = _locate_segments(agent[day_idx], day_t)
            if pos is None:
                continue
            state, target, lat, lng = pos
            lat, lng = jitter(rng, lat, lng)
            stamp_i = stamp[:-1] + ".000Z"
            rows.append({
                "lat": f"{lat:.6f}", "long": f"{lng:.6f}",
                "timestamp": stamp_i, "device_id": i,
            })
            history_rows.append({
                "agent_id": i,
                "timestamp": stamp_i,
                "minute_of_day": t,
                "state": state,
                "building_id": target,
                "lat": f"{lat:.6f}",
                "lng": f"{lng:.6f}",
            })
        # emit any waypoint-corner pings scheduled in this minute
        while corner_q and corner_q[0][0] < t + 1:
            ct, ci = heapq.heappop(corner_q)
            state, target, lat, lng = corner_by_key[(ct, ci)]
            corner_stamp = (start + timedelta(minutes=ct)).strftime(
                "%Y-%m-%dT%H:%M:%SZ")
            rows.append({
                "lat": f"{lat:.6f}", "long": f"{lng:.6f}",
                "timestamp": corner_stamp, "device_id": ci,
            })
            history_rows.append({
                "agent_id": ci,
                "timestamp": corner_stamp,
                "minute_of_day": int(ct),
                "state": state,
                "building_id": target,
                "lat": f"{lat:.6f}",
                "lng": f"{lng:.6f}",
            })
        t += ping
    return rows, history_rows


def _locate_segments(segments, minute):
    for s in segments:
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


def main():
    # macOS spawn safety: prewarm workers re-import this module, so guard
    # everything below the imports (same effect as __main__ guard).
    if __name__ != "__main__" and os.environ.get("GAMEDAY_CHILD"):
        return
    parser = argparse.ArgumentParser(description="Game-day weekend simulation")
    parser.add_argument("--agents", type=int, default=None)
    parser.add_argument("--seed", type=int, default=None)
    args = parser.parse_args()

    with open(SCHEDULES_PATH) as f:
        schedules = json.load(f)
    _, buildings_by_id, pools = _load()
    if args.agents:
        schedules["simulation"]["agents"] = args.agents
    if args.seed is not None:
        schedules["simulation"]["seed"] = args.seed

    rows, history_rows = simulate_gameday(schedules, buildings_by_id, pools)
    out = schedules["simulation"]["output_coords"]
    hist_out = schedules["simulation"]["output"]
    write_csv(rows, out, fieldnames=["lat", "long", "timestamp", "device_id"])
    write_csv(history_rows, hist_out)
    print(f"Wrote {len(rows):,} gameday-weekend rows → {out}")
    print(f"Wrote {len(history_rows):,} history rows → {hist_out}")


def _load():
    import json
    with open(os.path.join(HERE, "configs", "buildings.json")) as f:
        buildings = json.load(f)["buildings"]
    by_id = {b["id"]: b for b in buildings}
    pools = {}
    for b in buildings:
        pools.setdefault(b["type"], []).append(b["id"])
    return buildings, by_id, pools


if __name__ == "__main__":
    main()
