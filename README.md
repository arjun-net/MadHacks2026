# MadHacks 2026 – Location API (Rust)

Same API as the Python version (`~/Code/MadHacks2026`), built with axum + sqlx. Phone → `POST /api/v1/locations` → buffered → Lakebase. Frontend → `GET /api/v1/heatmap`.

## Run
```
cp .env.example .env     # STORE_BACKEND=memory works with no database
cargo run --release
```
Set `STORE_BACKEND=postgres` plus the `PG_*` vars for Lakebase (rows go to `public.location_events(device_id, latitude, longitude, "time")`, owned by the DB teammate; this server never creates it). Port defaults to 8000, set `PORT` to change it.

## API (base: `http://<host>:<port>/api/v1`)
Timestamps are ISO-8601 with timezone (e.g. `2026-11-14T22:34:00Z`); naive timestamps get 422. The field is `lng`, not `long`.

| Method | Path | Notes |
|---|---|---|
| POST | `/locations` | `{"lat","lng","timestamp","device_id"?}` → 202 `{"accepted":1}` |
| POST | `/locations/batch` | `{"points":[...]}` (1–500) → 202 `{"accepted":n}` |
| GET | `/heatmap?start=&end=[&bbox=minLng,minLat,maxLng,maxLat][&limit=]` | points in `[start,end)`; `limit` default 50000, max 200000 |
| GET | `/health` | `{"status":"ok","store_ok":bool}` |

Heatmap response: `{"start","end","count","data":{"<timestamp>":[{"lat","lng"},...]}}`, keys in ascending order.

Writes are buffered and flushed every 5s or 100 points, so a heatmap read right after a POST may not include it yet.

## Building lookup
Every ping is tagged with the campus building it falls in, saved in the `building` column on the same row (`NULL` when it's not in a building) and returned as `building` on heatmap points. A `building` sent by the client is kept only when the grid finds none.

- **Which buildings:** `assets/buildings_all.json` holds all 87 campus buildings and is the default source. `assets/buildings.json` is the earlier 20-building set with refined OpenStreetMap footprints; use it with `BUILDINGS_JSON=assets/buildings.json`. After changing the source, rebuild the grid with `cargo run --release --bin build_building_grid`.
- **How:** the outlines are rasterized once into a square N × N grid of 2 m cells (1480 × 1480 now). Each cell stores a `u16` building id (0 = none, 1–87 = the buildings in file order), decided by point-in-polygon at the cell center in a flat local metric projection. A lookup is a bounds check, two multiplies and one array read: O(1), about 4 ns, about 3 MB in memory. No external API is called.
- **GPS slack:** phone GPS indoors is often off by 10–50 m, so each building also claims cells up to `BUILDING_BUFFER_M` (15 m) outside its walls. A real outline always beats a neighbor's buffer; where only buffers reach, the nearest building wins.
- **It's an approximation.** It answers "is this coordinate on or near a building outline". It does not mean the student is indoors. Fixes reporting `accuracy` (or `horizontal_accuracy`) above `BUILDING_MAX_ACCURACY_M` (default 30) get `NULL`. Fixes that don't report it are still looked up.
- **Overlaps:** when outlines themselves overlap, the smaller building wins (e.g. a market inside a dorm). On equal area, the one listed first in the JSON wins. Overlaps and malformed polygons (fewer than 3 points, non-finite or out-of-range coordinates, zero area) are logged at startup and listed in `assets/building_grid.json`.
- **Artifacts:** `assets/building_grid.json` (metadata, the id→name map, and a checksum of buildings.json) plus `assets/building_grid.bin` (run-length-encoded cells). After editing buildings.json, regenerate them with `cargo run --release --bin build_building_grid` and commit both. If they're stale at startup, the server rebuilds in memory (a few ms) and tries to save them. With `BUILDING_GRID_REBUILD=false`, it exits with an error instead.
- **Env:** `BUILDINGS_JSON`, `BUILDING_GRID_DIR`, `BUILDING_GRID_RESOLUTION_M` (2), `BUILDING_GRID_MARGIN_M` (10), `BUILDING_BUFFER_M` (15), `BUILDING_MAX_ACCURACY_M` (30, or `off`), `BUILDING_GRID_REBUILD` (true).
- **Database:** uses the nullable `building TEXT` column on `location_events` and `location_events_broad` (added by the DB owner).
- **Speed:** `cargo run --release --example bench_building_lookup`.

## Test
`cargo test` (in-memory store only; never touches the database).
