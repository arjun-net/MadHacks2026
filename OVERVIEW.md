# Campus Pulse — Project Overview & History

UW-Madison student-density heatmap simulation. `generator.py` simulates a
day of 400 students' movements; the Mapbox viewer plays it back as an
animated heatmap with per-agent trails.

**Last updated:** 2026-11-14

---

## Project structure

```text
campus-pulse-sim/  (this dir: ~/Desktop/campusmap/MadHacks2026)
├── configs/
│   ├── buildings.json    # 58 buildings: id, name, type, center, perimeter_polygon
│   └── schedules.json    # archetypes, behavior params, commuter gates, sim config
├── viewer/
│   ├── index.html        # glassmorphism dark UI, Mapbox GL JS v3.12 + PapaParse CDN
│   ├── app.js            # heatmap + timeline + agent dots/trails/toggles
│   └── styles.css
├── editor/
│   ├── index.html        # geofence vertex + walkability-grid editor (standalone)
│   ├── app.js            # draggable vertices; grid mirrors router.py constants
│   ├── styles.css
│   └── data.js           # buildings.json embedded (auto-generated; opens via file://)
├── data/
│   ├── campus_simulation_history.csv   # full ping data (200,931 rows)
│   └── campus_simulation_coords.csv    # lat,long,timestamp only
├── generator.py          # simulation runner
├── router.py             # walkable-path routing (A* grid)
└── README.md
```

## How the simulation works

- **Buildings** (`configs/buildings.json`): each has an ordered
  `perimeter_polygon` ([lat, lng] vertices). Random interior points via
  ray-casting + rejection sampling. **Note: polygons are approximate
  bounding boxes — real footprints (e.g. via Overpass API) are a future
  upgrade.** 58 buildings: 7 study, 23 class, 4 dining, 21 dorm (all 19
  real UW residence halls), 2 social, 1 gym.
- **Schedules** (`configs/schedules.json`): 4 weighted archetypes (STEM
  Heavyweight .30, Humanities Drifter .25, Social Connector .25, Night Owl
  Crammer .20) with class_pattern (morning/afternoon/spread), study/social
  mixes. `behavior` block: depart dorm 330–720min, return 1020–1380min,
  commuter_share 0.6, gym/club/lunch/dinner probabilities.
- **Residents vs commuters**: ~60% commuters enter/leave via one of 5
  `commuter_gates` (same gate both ways, no dining). Residents assigned
  least-filled-first across all 21 dorms so every dorm is populated.
- **Routing** (`router.py`): 6m walkability grid over campus bbox; building
  footprints + 4m margin blocked; A* 8-connected; doors = perimeter vertex
  nearest centroid pushed 6m outward. TRANSIT segments carry waypoint
  polylines; ping positions interpolate along the polyline. Gates have no
  door → routed directly. Verified: 0 waypoints inside buildings; paths
  10–25% longer than straight-line.
- **Output**: 2-min pings (720 steps/day), 2026-01-01 UTC timestamps
  (`2026-01-01T00:00:00Z` format). Columns: agent_id, timestamp,
  minute_of_day, state, building_id, lat, lng. States: SLEEP, CLASS,
  STUDY, TRANSIT, EAT, SOCIAL, CLUB, GYM, BREAK.

Run: `python3 generator.py` (flags: `--agents`, `--seed`, `--out`).

## How the viewer works

- Load `viewer/index.html` via a local server, drop in the CSV.
- **Mapbox token is committed** in `viewer/app.js` (line ~6) — user's own
  public token, placed there with explicit consent.
- Layers: `density` (heatmap, green→yellow→red), `agent-dots` (color by
  state), `selected-path-line` (line-gradient trail for clicked agent),
  `all-paths-line` (faint trails for everyone, toggle off by default).
- Timeline: 720 steps @ 2min/step, slider + play/pause + 0.25×–4× speed.
- Toggles: `toggle-heat` (heatmap on/off), `toggle-paths` (trails).
- Click a dot → popup + right detail panel (state history, waypoint count).
- `PING_INTERVAL_MIN = 2`, `STEPS_PER_DAY = 720` in app.js.
- `timestampToStep()` handles Date objects, ISO strings, and HH:MM —
  PapaParse's `dynamicTyping: true` converts ISO timestamps to Dates.

## History / key decisions

1. **v1**: hardcoded archetypes, 7 buildings. Replaced by JSON configs.
2. **JSON write corruption**: two large `buildings.json` writes were
   mangled by the write tool (duplicate keys/garbled fields). **Lesson:
   always validate JSON after large writes** (`python3 -c "import json;
   json.load(open('configs/buildings.json'))"` plus unique-key checks).
3. **v2 behavior rework**: behavior-driven day assembly (depart/return
   windows, probabilistic dining/gym/club), commuters via gates.
4. **Lakeshore dorms empty bug**: per-resident `rng.choice` never picked
   Lakeshore halls under seed 42 → least-filled-first home assignment.
5. **Viewer step-0 blob bug**: all rows bucketed to step 0 because
   `timestampToStep` returned 0 for Date objects → fixed to handle Dates.
6. **Straight-line transit**: originally agents flew through buildings.
   Added `router.py` + waypoint polylines (see Routing above).
7. **Viewer trail erasing curves**: trail downsample kept only
   state-change waypoints (~20/agent), collapsing curved TRANSIT walks
   back into straight chords. Fixed in `viewer/app.js` (~line 237):
   TRANSIT pings are kept in full; non-transit states still dedupe to
   avoid 720-point jitter blobs. Median trail is now ~71 points.

## Gotchas for future agents

- **Validate any JSON you write** — the write tool has corrupted large
  JSON files here before.
- The CSV timestamps are UTC Dates after PapaParse — don't assume strings.
- `commuter_gates` ids are NOT in `buildings.json` — router/generator code
  must handle them as doorless origins (`router_route` normalizes ids vs
  dicts and falls back gracefully).
- Sim numbers (400 agents, 200,931 pings) assume 2-min pings; changing
  `ping_minutes` in schedules.json changes row counts proportionally.
