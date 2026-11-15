# campus-pulse-sender

Persistent Rust job that replays the simulation CSV as live device pings.
Every simulation tick (2 sim-minutes, default 2000 ms wall-clock) it POSTs
one ping per device — all devices fire within the same tick, staggered by a
random 0–`--jitter-ms` delay for realism (they may share IPs; nothing
identifies them beyond the payload).

Payload (one POST per device, JSON array):

```json
[{"agent_id": 12, "timestamp": "2026-01-01T08:02:00Z", "minute_of_day": 482,
  "state": "TRANSIT", "building_id": "chazen_museum", "lat": 43.0742, "lng": -89.3976}]
```

## Build

```bash
cd sender && cargo build --release
```

## Run

```bash
./target/release/campus-pulse-sender \
  --csv ../data/campus_simulation_history.csv \
  --target http://my-fastapi-host:8000 \
  --path /ingest \
  --tick-ms 2000 \
  --jitter-ms 40 \
  --concurrency 400
```

Runs forever (loops the 24 h day). `Ctrl-C` to stop; `--once` exits after
one day.

| flag | default | meaning |
|---|---|---|
| `--csv` | `../data/campus_simulation_history.csv` | input history |
| `--target` | `http://127.0.0.1:8000` | FastAPI ingest base URL |
| `--path` | `/ingest` | ingest endpoint path |
| `--tick-ms` | `2000` | wall-clock ms per 2-sim-minute tick |
| `--jitter-ms` | `40` | max random stagger per device POST |
| `--concurrency` | `400` | max in-flight POSTs (burst limiter) |
| `--devices` | all (400) | simulate first N agent ids |
| `--start-minute` | `0` | begin mid-day |
| `--once` | off | exit after one day instead of looping |

Pacing is drift-free: each tick fires exactly `tick_ms` after the previous
one; if the machine falls behind, it resets pace instead of bursting.

## Local testing

A dev-only Rust sink that mimics a FastAPI ingest target lives in
`../ingest/`:

```bash
cd ../ingest && cargo build --release && ./target/release/campus-pulse-ingest
# counters: curl localhost:8000/stats
```

Point the sender at it (`--target http://127.0.0.1:8000`) and watch
`/stats` climb: 400 devices at the default pace = 400 POSTs / 2 s.
