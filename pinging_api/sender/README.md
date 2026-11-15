# campus-pulse-sender

> See **`pinging_api/README.md`** for the full startup guide, `.env` reference,
> and the local test workflow. This file keeps the crate-level flag reference.

# campus-pulse-sender

Persistent Rust job that replays the apicalls CSV as live device pings.
Every tick (one CSV timestamp, 2 minutes of sim time = default 2000 ms
wall-clock) it POSTs one ping per device — one CSV row per device — all
within the same tick, staggered by a random 0–`--jitter-ms` delay for
realism.

Payload (one POST per device, JSON array):

```json
[{"lat": 43.071658, "long": -89.399816,
  "timestamp": "2026-11-11T23:58:00Z", "building": "sellery_hall"}]
```

## Build

```bash
cd sender && cargo build --release
```

## Run

```bash
./target/release/campus-pulse-sender \
  --csv ../data/campus_simulation_apicalls.csv \
  --target http://my-fastapi-host:8000 \
  --path /ingest \
  --tick-ms 2000 \
  --jitter-ms 40 \
  --concurrency 200
```

Runs forever (loops the CSV timeline). `Ctrl-C` to stop; `--once` exits
after one full pass.

| flag | default | meaning |
|---|---|---|
| `--csv` | `../data/campus_simulation_apicalls.csv` | input (lat,long,timestamp,building) |
| `--target` | `http://127.0.0.1:8000` | FastAPI ingest base URL |
| `--path` | `/ingest` | ingest endpoint path |
| `--tick-ms` | `2000` | wall-clock ms per CSV timestamp tick |
| `--jitter-ms` | `40` | max random stagger per device POST |
| `--concurrency` | `200` | max in-flight POSTs (burst limiter) |
| `--devices` | all | post only the first N rows per tick |
| `--start-tick` | `0` | begin mid-timeline |
| `--once` | off | exit after one pass instead of looping |

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
`/stats` climb: a full tick = one POST per row in that timestamp's data.
