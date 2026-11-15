# pinging_api — live device pinging worker

Persistent Rust worker that replays the simulation as live device pings.
It reads `data/campus_simulation_apicalls.csv` (`lat,long,timestamp,building`)
and, once per tick (one CSV timestamp = 2 sim-minutes, default 2000 ms
wall-clock), POSTs one ping per device to a configurable FastAPI target —
all devices fire within the same tick, staggered by a small random jitter
for realism.

Payload (one POST per device):

```json
[{"lat": 43.071658, "long": -89.399816,
  "timestamp": "2026-11-11T23:58:00Z", "building": "sellery_hall"}]
```

## Layout

```
pinging_api/
├── .env              ← all configuration lives here
├── .env.example      ← copy of the same, for reference
├── README.md
├── data/
│   └── campus_simulation_apicalls.csv
├── sender/           ← the worker (this is the only piece you run in prod)
└── ingest/           ← dev-only axum sink that mimics a FastAPI target
```

## Configure

Everything is configured through `.env` (CLI flags override, if you pass
them):

| var | default | meaning |
|---|---|---|
| `PULSE_TARGET` | `http://127.0.0.1:8000` | FastAPI ingest base URL |
| `PULSE_PATH` | `/ingest` | ingest endpoint path |
| `PULSE_CSV` | `data/campus_simulation_apicalls.csv` | input CSV |
| `PULSE_TICK_MS` | `2000` | wall-clock ms per tick |
| `PULSE_JITTER_MS` | `40` | max random per-device stagger (ms) |
| `PULSE_CONCURRENCY` | `200` | max in-flight POSTs (burst limiter) |
| `PULSE_DEVICES` | *(all)* | post only the first N rows per tick |
| `PULSE_START_TICK` | `0` | begin mid-timeline |
| `PULSE_ONCE` | *(off)* | `true` = exit after one pass instead of looping |

## Build

```bash
cd pinging_api/sender && cargo build --release
```

(First build pulls crates and takes a minute or two.)

## Run

From the `pinging_api/` directory (so `.env` and the CSV resolve):

```bash
sender/target/release/campus-pulse-sender
```

That's it — the worker loads `.env`, replays the CSV forever (it loops the
timeline), and logs one line per hour of sim time:

```
[2026-11-11T23:58:00Z · tick 0] posted 250/250 pings
```

`Ctrl-C` to stop. Pacing is drift-free: each tick fires exactly
`PULSE_TICK_MS` after the previous one; if the machine falls behind it
resets pace instead of bursting.

## Local end-to-end test

The `ingest/` crate is a dev-only sink with the same `/ingest` shape so you
can verify the worker without a real FastAPI service:

```bash
cd pinging_api/ingest && cargo build --release
./target/release/campus-pulse-ingest            # listens on :8000
# in another terminal, from pinging_api/:
sender/target/release/campus-pulse-sender
curl localhost:8000/stats                       # {"batches":N,"pings":M}
```
