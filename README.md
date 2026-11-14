# Campus Pulse — UW-Madison Student Density Heatmap

Simulates a day of student movement across UW-Madison campus and visualizes it as a live Mapbox heatmap with a timeline scrubber.

## Structure

```
campus-pulse-sim/
├── configs/
│   ├── buildings.json    # Landmarks: id, type, center, ordered perimeter_polygon (ray-casting targets)
│   └── schedules.json    # Simulation params + student archetypes (weighted routines of state blocks)
├── viewer/
│   ├── index.html        # Local Mapbox viewer UI
│   ├── app.js            # PapaParse CSV ingest, heatmap layer, timeline playback
│   └── styles.css        # Glassmorphism theme
├── data/
│   └── campus_simulation_history.csv   # generator output
├── generator.py          # Simulation runner
└── README.md
```

## How the geoboundaries work

Each building stores an **ordered list of perimeter vertices** (`perimeter_polygon`). Connecting them in order traces the exact building footprint — better than a convex hull for L-shaped or irregular buildings, since the hull can cut off corners or swallow courtyards.

`generator.py` places each agent ping by **rejection sampling with ray-casting** (`point_in_polygon`): draw a random point in the polygon's bounding box, cast a ray, keep it only if it falls inside the ordered vertex loop. Points concentrate realistically within footprints, not just at centroids.

To map a new building: drop GPS pins around its corners **in order** (clockwise or counter-clockwise), then add them to `buildings.json`.

## Run the simulation

```bash
python generator.py                    # defaults from schedules.json (400 agents, seed 42)
python generator.py --agents 800 --seed 7 --out data/my_run.csv
```

Output CSVs (one row per agent per 2-minute ping, 720 steps/day):
- `data/campus_simulation_history.csv` — `agent_id, timestamp (UTC ISO 8601), minute_of_day, state, building_id, lat, lng`
- `data/campus_simulation_coords.csv` — plain `lat, long, timestamp` only (for heatmap tooling)

## Run the viewer

1. Serve the viewer locally (Mapbox GL loads fine from `file://`, but a local server avoids any browser quirks):

```bash
cd viewer && python3 -m http.server 8000
```

2. Open `http://localhost:8000`, click **Load CSV** (or drag-drop `data/campus_simulation_history.csv` onto the page).

Use the timeline slider to scrub through the day frame-by-frame, or press ▶ to play it back (watch crowds shift dorms → lecture halls → dining → library as the day unfolds). Speed control: 0.25×–4×.

## Tuning

- **Agents / ping interval / seed:** `simulation` block in `configs/schedules.json`.
- **Behavior:** edit any archetype's `routine` (state, target building id, duration in minutes). Durations get ±15% per-agent jitter; wake times get per-archetype jitter so crowds don't move in lockstep.
- **Heatmap look:** paint properties in the `density` layer in `viewer/app.js` (radius, color ramp green → yellow → red).
